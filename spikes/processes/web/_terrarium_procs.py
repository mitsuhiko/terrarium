"""Processes for Pyodide workers (spike `processes`).

Every process is its own Pyodide worker. This module makes the standard
library's process APIs work on top of that, without threads and without
fork:

- ``os``: getpid/getppid, pipe (shared pipes), waitpid, kill, cpu_count;
  fork raises. ``time.sleep`` wakes on Stop.
- ``select``/``selectors``: poll and select that really wait (Emscripten's
  poll() ignores its timeout).
- ``multiprocessing``: spawn is the only start method. A process is
  started from the pickled preparation data and process object, as spawn
  does it. ``_multiprocessing.SemLock`` is backed by shared Int32s, so all
  of the locks work. Queue has no feeder thread: put() writes right away and
  keeps what doesn't fit, flushing it whenever this process waits. Value,
  Array and Barrier live in SharedArrayBuffers. Pool and
  ProcessPoolExecutor do their bookkeeping whenever the parent waits on
  them (no handler threads).
- ``subprocess``: Python only (``sys.executable``, ``python``,
  ``python3``) with -c, -m or a script; pipes, communicate(), timeouts,
  return codes. Anything else raises FileNotFoundError.
"""

import atexit
import collections
import errno
import io
import itertools
import json
import os
import queue as _queue
import select as _select
import selectors
import signal
import struct
import sys
import threading
import time
import traceback
import types
import weakref

import _procs
from pyodide.ffi import to_js

PID = int(_procs.pid)
PPID = int(_procs.ppid)
EXECUTABLE = "/usr/bin/python3"
_installed = False

POLLIN, POLLPRI, POLLOUT, POLLERR, POLLHUP, POLLNVAL = 1, 2, 4, 8, 16, 32
WAIT_SLICE_MS = 20  # how often a wait flushes queued writes when there are any


def _ints(js):
    return [int(x) for x in js]


def _ms(timeout):
    """Seconds (None = forever) to the JS side's milliseconds (-1 = forever)."""
    if timeout is None:
        return -1
    return max(0.0, float(timeout) * 1000)


# ---------------------------------------------------------------------------
# Writes that didn't fit (multiprocessing.Queue without a feeder thread)

_pending = collections.OrderedDict()  # Queue -> deque of pickled messages


def _flush_pending(block=False):
    """Send what queues couldn't send yet. With block, wait until all is sent."""
    for q, items in list(_pending.items()):
        while items:
            if not q._flush_one(items[0], block):
                break
            items.popleft()
        if not items:
            _pending.pop(q, None)


def _waiting(call, timeout_ms):
    """Run a blocking JS wait. ``call(ms)`` waits up to ms and returns a
    result, or a false value when nothing happened. While queued writes are
    pending, wait in slices and flush between them, as a feeder thread
    would."""
    if not _pending:
        return call(timeout_ms)
    deadline = None if timeout_ms < 0 else time.monotonic() + timeout_ms / 1000
    while True:
        _flush_pending()
        if _pending:
            step = WAIT_SLICE_MS
            if deadline is not None:
                step = min(step, max(0.0, (deadline - time.monotonic()) * 1000))
        else:
            step = -1 if deadline is None else max(0.0, (deadline - time.monotonic()) * 1000)
        result = call(step)
        if result or (deadline is not None and time.monotonic() >= deadline):
            return result


# ---------------------------------------------------------------------------
# os, time

def getpid():
    return PID


def getppid():
    return PPID


def cpu_count():
    return int(_procs.cpu_count())


def pipe():
    r, w = _ints(_procs.pipe())
    return r, w


def fork():
    raise OSError(errno.ENOSYS, "fork() is not available here: every process is a new "
                  "interpreter (multiprocessing uses spawn)")


def waitpid(pid, options):
    if _pending and not options & os.WNOHANG:
        # Flush queued writes while we wait, as a feeder thread would.
        while _pending:
            r = _procs.waitpid(pid, os.WNOHANG)
            if r is None or int(r[0]) != 0:
                break
            _flush_pending()
            if pid > 0:
                _procs.wait_exit(pid, WAIT_SLICE_MS)
            else:
                _procs.sleep(WAIT_SLICE_MS / 1000)
        else:
            r = _procs.waitpid(pid, options)
    else:
        r = _procs.waitpid(pid, options)
    if r is None:
        raise ChildProcessError(errno.ECHILD, os.strerror(errno.ECHILD))
    a, b = _ints(r)
    return a, b


def kill(pid, sig):
    sig = int(sig)
    if pid == PID:
        if sig == signal.SIGINT:
            raise KeyboardInterrupt
        if sig == 0:
            return
        os._exit(128 + sig)
    if not _procs.kill(pid, sig):
        raise ProcessLookupError(errno.ESRCH, os.strerror(errno.ESRCH))


def sleep(secs):
    if secs < 0:
        raise ValueError("sleep length must be non-negative")
    if not _pending:
        _procs.sleep(float(secs))
        return
    _waiting(lambda ms: _procs.sleep(ms / 1000), float(secs) * 1000)


# ---------------------------------------------------------------------------
# select, selectors

def _fileno(obj):
    fd = obj if isinstance(obj, int) else obj.fileno()
    if not isinstance(fd, int):
        raise TypeError("fileno() returned a non-integer")
    if fd < 0:
        raise ValueError(f"file descriptor cannot be a negative integer ({fd})")
    return fd


def _wait_fds(fds, events, timeout_ms):
    flat = _waiting(lambda ms: _ints(_procs.wait_fds(to_js(fds), to_js(events), ms)), timeout_ms)
    flat = flat or []
    return list(zip(flat[::2], flat[1::2]))


class poll:
    """select.poll that waits for real."""

    def __init__(self):
        self._fds = {}

    def register(self, fd, eventmask=POLLIN | POLLPRI | POLLOUT):
        self._fds[_fileno(fd)] = eventmask

    def modify(self, fd, eventmask):
        fd = _fileno(fd)
        if fd not in self._fds:
            raise FileNotFoundError(errno.ENOENT, os.strerror(errno.ENOENT))
        self._fds[fd] = eventmask

    def unregister(self, fd):
        del self._fds[_fileno(fd)]

    def poll(self, timeout=None):
        if timeout is None or timeout < 0:
            ms = -1
        else:
            ms = float(timeout)
        fds = list(self._fds)
        return _wait_fds(fds, [self._fds[fd] for fd in fds], ms)


def select(rlist, wlist, xlist, timeout=None):
    if timeout is not None and timeout < 0:
        raise ValueError("timeout must be non-negative")
    events = {}
    for obj in rlist:
        events[_fileno(obj)] = events.get(_fileno(obj), 0) | POLLIN
    for obj in wlist:
        events[_fileno(obj)] = events.get(_fileno(obj), 0) | POLLOUT
    for obj in xlist:
        _fileno(obj)
    fds = list(events)
    ready = dict(_wait_fds(fds, [events[fd] for fd in fds], _ms(timeout)))
    r = [o for o in rlist if ready.get(_fileno(o), 0) & (POLLIN | POLLHUP | POLLERR | POLLNVAL)]
    w = [o for o in wlist if ready.get(_fileno(o), 0) & (POLLOUT | POLLERR | POLLNVAL)]
    return r, w, []


# ---------------------------------------------------------------------------
# _multiprocessing

RECURSIVE_MUTEX, SEMAPHORE = 0, 1


class SemLock:
    """_multiprocessing.SemLock: the value is shared (an Int32 the manager
    owns); the count and owner are this process's, as in CPython."""

    SEM_VALUE_MAX = 2**31 - 1

    def __init__(self, kind, value, maxvalue, name, unlink):
        if kind not in (RECURSIVE_MUTEX, SEMAPHORE):
            raise ValueError("unrecognized kind")
        self.handle = int(_procs.sem_new(value))
        self.kind = kind
        self.maxvalue = maxvalue
        self.name = None  # unlinked at once: nothing for the resource tracker
        self._n = 0

    @classmethod
    def _rebuild(cls, handle, kind, maxvalue, name):
        self = cls.__new__(cls)
        self.handle, self.kind, self.maxvalue, self.name = handle, kind, maxvalue, None
        self._n = 0
        return self

    def _is_mine(self):
        return self._n > 0

    def acquire(self, block=True, timeout=None):
        if self.kind == RECURSIVE_MUTEX and self._n > 0:
            self._n += 1
            return True
        if not block:
            ok = _procs.sem_acquire(self.handle, False, 0)
        else:
            ok = _waiting(lambda ms: _procs.sem_acquire(self.handle, True, ms), _ms(timeout))
        if ok:
            self._n += 1
            return True
        return False

    def release(self):
        if self.kind == RECURSIVE_MUTEX:
            if self._n <= 0:
                raise AssertionError("attempt to release recursive lock not owned by thread")
            if self._n > 1:
                self._n -= 1
                return
            _procs.sem_release(self.handle, 1)
        elif _procs.sem_release(self.handle, self.maxvalue) != 0:
            raise ValueError("semaphore or lock released too many times")
        self._n -= 1

    def __enter__(self):
        return self.acquire()

    def __exit__(self, *args):
        self.release()

    def _count(self):
        return self._n

    def _get_value(self):
        return int(_procs.sem_value(self.handle))

    def _is_zero(self):
        return self._get_value() == 0

    def _after_fork(self):
        self._n = 0


def _make_multiprocessing_module():
    mod = types.ModuleType("_multiprocessing")
    mod.SemLock = SemLock
    mod.sem_unlink = lambda name: None
    mod.flags = {"HAVE_SEM_OPEN": 1, "HAVE_SEM_TIMEDWAIT": 1}
    return mod


# ---------------------------------------------------------------------------
# Shared memory: Value, Array, RawValue, RawArray, Barrier's buffer

def _typecode(t):
    if isinstance(t, str):
        return t
    code = getattr(t, "_type_", None)
    if isinstance(code, str) and len(code) == 1:
        return code
    raise TypeError(f"{t!r}: only simple ctypes types and type codes can be shared between processes here")


class _SharedBuffer:
    def __init__(self, size, buf=None):
        self.size = size
        self.id = buf if buf is not None else int(_procs.buf_new(size))

    def get(self, offset, n):
        return _procs.buf_get(self.id, offset, n).to_bytes()

    def set(self, offset, data):
        _procs.buf_set(self.id, offset, to_js(bytes(data)))

    def __reduce__(self):
        return (_SharedBuffer, (self.size, self.id))


class _SharedArray:
    """Fixed-size typed items in a shared buffer."""

    def __init__(self, typecode, length, buf=None):
        self._typecode = typecode
        self._itemsize = struct.calcsize(typecode)
        self._length = length
        self._buf = buf or _SharedBuffer(self._itemsize * max(1, length))

    def __len__(self):
        return self._length

    def _index(self, i):
        if i < 0:
            i += self._length
        if not 0 <= i < self._length:
            raise IndexError("invalid index")
        return i

    def __getitem__(self, i):
        if isinstance(i, slice):
            start, stop, step = i.indices(self._length)
            if step == 1:
                n = max(0, stop - start)
                data = self._buf.get(start * self._itemsize, n * self._itemsize)
                return list(struct.unpack(f"{n}{self._typecode}", data))
            return [self[j] for j in range(start, stop, step)]
        i = self._index(i)
        return struct.unpack(self._typecode, self._buf.get(i * self._itemsize, self._itemsize))[0]

    def __setitem__(self, i, value):
        if isinstance(i, slice):
            start, stop, step = i.indices(self._length)
            values = list(value)
            idx = range(start, stop, step)
            if len(values) != len(idx):
                raise ValueError("Can only assign sequence of same size")
            if step == 1:
                self._buf.set(start * self._itemsize, struct.pack(f"{len(values)}{self._typecode}", *values))
            else:
                for j, v in zip(idx, values):
                    self[j] = v
            return
        i = self._index(i)
        self._buf.set(i * self._itemsize, struct.pack(self._typecode, value))

    def __iter__(self):
        return iter(self[:])

    def cast(self, typecode):  # memoryview-like, for Barrier
        return _SharedArray(typecode, self._buf.size // struct.calcsize(typecode), self._buf)

    def __reduce__(self):
        return (_SharedArray, (self._typecode, self._length, self._buf))


class _RawValue:
    def __init__(self, typecode, value=0, arr=None):
        self._arr = arr or _SharedArray(typecode, 1)
        if arr is None:
            self._arr[0] = value

    @property
    def value(self):
        return self._arr[0]

    @value.setter
    def value(self, v):
        self._arr[0] = v

    def __repr__(self):
        return f"<shared {self._arr._typecode}({self.value!r})>"

    def __reduce__(self):
        return (_RawValue, (self._arr._typecode, None, self._arr))


class _Synchronized:
    def __init__(self, obj, lock):
        self._obj = obj
        self._lock = lock
        self.acquire = lock.acquire
        self.release = lock.release

    def __enter__(self):
        return self._lock.__enter__()

    def __exit__(self, *args):
        return self._lock.__exit__(*args)

    def get_obj(self):
        return self._obj

    def get_lock(self):
        return self._lock

    def __reduce__(self):
        from multiprocessing import context
        context.assert_spawning(self)
        return (type(self), (self._obj, self._lock))


class SynchronizedValue(_Synchronized):
    @property
    def value(self):
        with self._lock:
            return self._obj.value

    @value.setter
    def value(self, v):
        with self._lock:
            self._obj.value = v

    def __repr__(self):
        return f"<Synchronized wrapper for {self._obj!r}>"


class SynchronizedArray(_Synchronized):
    def __len__(self):
        return len(self._obj)

    def __getitem__(self, i):
        with self._lock:
            return self._obj[i]

    def __setitem__(self, i, v):
        with self._lock:
            self._obj[i] = v

    def __iter__(self):
        return iter(self[:])


def RawValue(typecode_or_type, *args):
    return _RawValue(_typecode(typecode_or_type), *args)


def RawArray(typecode_or_type, size_or_initializer):
    tc = _typecode(typecode_or_type)
    if isinstance(size_or_initializer, int):
        return _SharedArray(tc, size_or_initializer)
    values = list(size_or_initializer)
    arr = _SharedArray(tc, len(values))
    arr[:] = values
    return arr


def _lock_for(lock, ctx):
    from multiprocessing import context
    ctx = ctx or context.get_context()
    if lock in (True, None):
        return ctx.RLock()
    if not hasattr(lock, "acquire"):
        raise AttributeError(f"{lock!r} has no method 'acquire'")
    return lock


def Value(typecode_or_type, *args, lock=True, ctx=None):
    obj = RawValue(typecode_or_type, *args)
    if lock is False:
        return obj
    return SynchronizedValue(obj, _lock_for(lock, ctx))


def Array(typecode_or_type, size_or_initializer, *, lock=True, ctx=None):
    obj = RawArray(typecode_or_type, size_or_initializer)
    if lock is False:
        return obj
    return SynchronizedArray(obj, _lock_for(lock, ctx))


class BufferWrapper:
    """multiprocessing.heap.BufferWrapper in a SharedArrayBuffer (Barrier uses it)."""

    def __init__(self, size):
        self._arr = _SharedArray("B", size)

    def create_memoryview(self):
        return self._arr


# ---------------------------------------------------------------------------
# Starting processes

def _spawn(pid, task, payload=None):
    _procs.spawn(pid, json.dumps(task), to_js(payload) if payload is not None else None)


def _new_child():
    """A pid for a new child, and its life pipe: [our sentinel fd, pipe id]."""
    pid = int(_procs.alloc_pid())
    sentinel, life = _ints(_procs.life_pipe(pid))
    return pid, sentinel, life


_MY_LIFE = None  # this process's life pipe id (EOF once we exit)


def _my_life():
    """The pipe our children watch to see us exit (made by our parent, or
    here for the root)."""
    global _MY_LIFE
    if _MY_LIFE is None:
        fd, _MY_LIFE = _ints(_procs.life_pipe(PID))
        os.close(fd)
    return _MY_LIFE


class _DupFd:
    """A pipe end on its way to a child: counted for it by the parent,
    opened by the child when unpickled."""

    def __init__(self, desc):
        self.desc = desc

    def detach(self):
        return int(_procs.adopt(self.desc))


def _make_popen():
    from multiprocessing import popen_fork, spawn, util
    from multiprocessing.context import reduction, set_spawning_popen

    class Popen(popen_fork.Popen):
        """Spawn into a new worker: poll/wait/terminate/kill are popen_fork's,
        on top of our waitpid and kill."""

        method = "spawn"
        DupFd = _DupFd

        def duplicate_for_child(self, fd):
            return str(_procs.transfer(fd, self.pid))

        def _launch(self, process_obj):
            prep_data = spawn.get_preparation_data(process_obj._name)
            self.pid, self.sentinel, life = _new_child()
            self.finalizer = util.Finalize(self, util.close_fds, (self.sentinel,))
            try:
                fp = io.BytesIO()
                set_spawning_popen(self)
                try:
                    reduction.dump(prep_data, fp)
                    reduction.dump(process_obj, fp)
                finally:
                    set_spawning_popen(None)
                parent = str(_procs.life_reader(_my_life(), self.pid))
            except BaseException:
                _procs.abandon(self.pid)
                raise
            _spawn(self.pid, {"kind": "mp", "life": life, "parent": parent}, fp.getvalue())

    return Popen


def _run_mp(task, payload):
    from multiprocessing import process, spawn
    from multiprocessing.context import reduction

    parent_sentinel = int(_procs.adopt(task["parent"]))
    fp = io.BytesIO(payload)
    process.current_process()._inheriting = True
    try:
        preparation_data = reduction.pickle.load(fp)
        spawn.prepare(preparation_data)
        self = reduction.pickle.load(fp)
    finally:
        del process.current_process()._inheriting
    return self._bootstrap(parent_sentinel)


# ---------------------------------------------------------------------------
# multiprocessing.Queue without a feeder thread

def _patch_queues():
    from multiprocessing import queues
    from multiprocessing.reduction import ForkingPickler

    def _flush_one(self, data, block):
        """Send one pickled message; False if it doesn't fit right now."""
        n = len(data)
        header = struct.pack("!i", n) if n <= 0x7FFFFFFF else struct.pack("!i", -1) + struct.pack("!Q", n)
        if block:
            with self._wlock:
                self._writer.send_bytes(data)
            return True
        if not self._wlock.acquire(False):
            return False
        try:
            fd = self._writer.fileno()
            if len(header) + n > int(_procs.pipe_capacity(fd)):
                self._writer.send_bytes(data)  # bigger than the pipe: has to block
                return True
            ok = _procs.try_write_all(fd, to_js(header + bytes(data)))
            if ok is None:
                if self._ignore_epipe:
                    return True
                raise BrokenPipeError(errno.EPIPE, os.strerror(errno.EPIPE))
            return bool(ok)
        finally:
            self._wlock.release()

    def _send_or_queue(self, data):
        items = _pending.get(self)
        if items is None and self._flush_one(data, False):
            return
        _pending.setdefault(self, collections.deque()).append(data)
        if not hasattr(self, "_flush_at_exit"):
            # As the feeder thread is joined at exit: send everything first.
            self._flush_at_exit = True
            atexit.register(_flush_queue_at_exit, weakref.ref(self))

    def put(self, obj, block=True, timeout=None):
        if self._closed:
            raise ValueError(f"Queue {self!r} is closed")
        if not self._sem.acquire(block, timeout):
            raise _queue.Full
        self._send_or_queue(ForkingPickler.dumps(obj))
        _flush_pending()

    def joinable_put(self, obj, block=True, timeout=None):
        if self._closed:
            raise ValueError(f"Queue {self!r} is closed")
        if not self._sem.acquire(block, timeout):
            raise _queue.Full
        data = ForkingPickler.dumps(obj)
        with self._cond:
            self._send_or_queue(data)
            self._unfinished_tasks.release()
        _flush_pending()

    original_get = queues.Queue.get

    def get(self, block=True, timeout=None):
        _flush_pending()
        if block and _pending:
            # Wait for data in slices, flushing our own queued writes meanwhile.
            deadline = None if timeout is None else time.monotonic() + timeout
            while not self._poll(WAIT_SLICE_MS / 1000):
                _flush_pending()
                if deadline is not None and time.monotonic() >= deadline:
                    raise _queue.Empty
                if not _pending:
                    break
            if deadline is not None:
                timeout = max(0.0, deadline - time.monotonic())
        return original_get(self, block, timeout)

    def join_thread(self):
        assert self._closed, f"Queue {self!r} not closed"
        if not getattr(self, "_joincancelled", False):
            items = _pending.pop(self, None)
            while items:
                self._flush_one(items.popleft(), True)

    def cancel_join_thread(self):
        self._joincancelled = True
        _pending.pop(self, None)

    queues.Queue._flush_one = _flush_one
    queues.Queue._send_or_queue = _send_or_queue
    queues.Queue.put = put
    queues.Queue.get = get
    queues.Queue.join_thread = join_thread
    queues.Queue.cancel_join_thread = cancel_join_thread
    queues.JoinableQueue.put = joinable_put


def _flush_queue_at_exit(ref):
    q = ref()
    if q is None or getattr(q, "_joincancelled", False):
        return
    items = _pending.pop(q, None)
    while items:
        try:
            q._flush_one(items.popleft(), True)
        except (BrokenPipeError, OSError):
            return


# ---------------------------------------------------------------------------
# Pool and ProcessPoolExecutor without handler threads

RUN, CLOSE, TERMINATE = 0, 1, 2
_pools = weakref.WeakSet()


def _pump(timeout_ms):
    """One round of bookkeeping for every pool: start workers, send tasks,
    collect results (running callbacks). Waits up to timeout_ms for
    something to happen if nothing did. Returns True on progress."""
    pools = list(_pools)
    progressed = False
    for pool in pools:
        progressed |= pool._maintain()
        progressed |= pool._feed()
        progressed |= pool._drain()
    if progressed or timeout_ms == 0:
        return progressed
    fds = []
    for pool in pools:
        fds.append(pool._outqueue._reader.fileno())
        fds.extend(w.sentinel for w in pool._pool)
    if not fds:
        sleep(0 if timeout_ms < 0 else timeout_ms / 1000)
        return False
    if _wait_fds(fds, [POLLIN] * len(fds), timeout_ms):
        for pool in pools:
            progressed |= pool._maintain()
            progressed |= pool._drain()
            progressed |= pool._feed()
    return progressed


def _dump_pools():
    for pool in list(_pools):
        print(f"[pool diag {PID}] jobs={len(pool._jobs)} cache={list(pool._cache)} inflight={pool._inflight} "
              f"workers={[(w.pid, w.exitcode) for w in pool._pool]} "
              f"in={_procs.pipe_info(pool._inqueue._writer.fileno())} out={_procs.pipe_info(pool._outqueue._reader.fileno())}",
              file=sys.stderr, flush=True)


def _wait_until(pred, timeout=None):
    """Pump until pred() is true; False if the timeout passed first."""
    deadline = None if timeout is None else time.monotonic() + timeout
    started = time.monotonic()
    dumped = False
    while not pred():
        if not dumped and time.monotonic() - started > 20:
            dumped = True
            _dump_pools()
        if deadline is None:
            _pump(5000)
        else:
            left = deadline - time.monotonic()
            if left <= 0:
                return pred()
            _pump(left * 1000)
    return True


def _make_pool():
    from multiprocessing import TimeoutError as MpTimeoutError
    from multiprocessing import pool as mpool
    from multiprocessing import util
    from multiprocessing import get_context as _get_context

    job_counter = itertools.count()
    get_tasks = mpool.Pool._get_tasks  # the stdlib's, before Pool is replaced

    class ApplyResult:
        def __init__(self, pool, callback, error_callback):
            self._pool = pool
            self._job = next(job_counter)
            self._cache = pool._cache
            self._ready = False
            self._callback = callback
            self._error_callback = error_callback
            self._cache[self._job] = self

        def ready(self):
            return self._ready

        def successful(self):
            if not self.ready():
                raise ValueError(f"{self!r} not ready")
            return self._success

        def wait(self, timeout=None):
            _wait_until(self.ready, timeout)

        def get(self, timeout=None):
            self.wait(timeout)
            if not self._ready:
                raise MpTimeoutError
            if self._success:
                return self._value
            raise self._value

        def _set(self, i, obj):
            self._success, self._value = obj
            if self._callback and self._success:
                self._callback(self._value)
            if self._error_callback and not self._success:
                self._error_callback(self._value)
            self._ready = True
            del self._cache[self._job]
            self._pool = None

    class MapResult(ApplyResult):
        def __init__(self, pool, chunksize, length, callback, error_callback):
            ApplyResult.__init__(self, pool, callback, error_callback)
            self._success = True
            self._value = [None] * length
            self._chunksize = chunksize
            if chunksize <= 0:
                self._number_left = 0
                self._ready = True
                del self._cache[self._job]
            else:
                self._number_left = length // chunksize + bool(length % chunksize)

        def _set(self, i, success_result):
            self._number_left -= 1
            success, result = success_result
            if success and self._success:
                self._value[i * self._chunksize:(i + 1) * self._chunksize] = result
                if self._number_left == 0:
                    if self._callback:
                        self._callback(self._value)
                    del self._cache[self._job]
                    self._ready = True
            else:
                if not success and self._success:
                    self._success = False
                    self._value = result
                if self._number_left == 0:
                    if self._error_callback:
                        self._error_callback(self._value)
                    del self._cache[self._job]
                    self._ready = True

    class IMapIterator:
        def __init__(self, pool, ordered):
            self._pool = pool
            self._job = next(job_counter)
            self._cache = pool._cache
            self._ordered = ordered
            self._items = {} if ordered else collections.deque()
            self._index = 0
            self._length = None
            self._cache[self._job] = self

        def __iter__(self):
            return self

        def next(self, timeout=None):
            deadline = None if timeout is None else time.monotonic() + timeout
            while True:
                if self._ordered and self._index in self._items:
                    success, value = self._items.pop(self._index)
                    break
                if not self._ordered and self._items:
                    success, value = self._items.popleft()
                    break
                if self._length is not None and self._index >= self._length:
                    self._cache.pop(self._job, None)
                    raise StopIteration
                if deadline is None:
                    _pump(-1)
                else:
                    left = deadline - time.monotonic()
                    if left <= 0:
                        raise MpTimeoutError
                    _pump(left * 1000)
            self._index += 1
            if success:
                return value
            raise value

        __next__ = next

        def _set(self, i, obj):
            if self._ordered:
                self._items[i] = obj
            else:
                self._items.append(obj)

        def _set_length(self, length):
            self._length = length
            if self._index >= length and not self._items:
                self._cache.pop(self._job, None)

    class Pool:
        """multiprocessing.Pool without handler threads: the parent sends
        tasks, collects results and replaces workers whenever it waits on
        the pool (get(), wait(), imap's next(), join())."""

        def __init__(self, processes=None, initializer=None, initargs=(),
                     maxtasksperchild=None, context=None):
            self._ctx = context or _get_context()
            self._inqueue = self._ctx.SimpleQueue()
            self._outqueue = self._ctx.SimpleQueue()
            self._cache = {}
            self._state = RUN
            self._jobs = collections.deque()  # [result, task iterator, next index]
            self._inflight = 0
            self._pool = []
            if processes is None:
                processes = os.process_cpu_count() or 1
            if processes < 1:
                raise ValueError("Number of processes must be at least 1")
            if maxtasksperchild is not None and (not isinstance(maxtasksperchild, int) or maxtasksperchild <= 0):
                raise ValueError("maxtasksperchild must be a positive int or None")
            if initializer is not None and not callable(initializer):
                raise TypeError("initializer must be a callable")
            self._processes = processes
            self._initializer = initializer
            self._initargs = initargs
            self._maxtasksperchild = maxtasksperchild
            self._repopulate()
            _pools.add(self)

        def _repopulate(self):
            started = False
            for _ in range(self._processes - len(self._pool)):
                w = self._ctx.Process(target=mpool.worker, args=(
                    self._inqueue, self._outqueue, self._initializer,
                    self._initargs, self._maxtasksperchild, True))
                w.name = w.name.replace("Process", "PoolWorker")
                w.daemon = True
                w.start()
                self._pool.append(w)
                started = True
            return started

        def _maintain(self):
            changed = False
            for w in list(self._pool):
                if w.exitcode is not None:
                    w.join()
                    self._pool.remove(w)
                    changed = True
            if self._state == RUN and changed:
                self._repopulate()
            return changed

        def _feed(self):
            sent = False
            limit = 2 * max(1, len(self._pool))
            while self._jobs and self._inflight < limit and self._state != TERMINATE:
                entry = self._jobs[0]
                result, tasks = entry[0], entry[1]
                try:
                    func, args, kwds = next(tasks)
                except StopIteration:
                    self._jobs.popleft()
                    if isinstance(result, IMapIterator):
                        result._set_length(entry[2])
                    continue
                except Exception as e:  # the iterable failed
                    self._jobs.popleft()
                    result._set(entry[2], (False, e))
                    if isinstance(result, IMapIterator):
                        result._set_length(entry[2] + 1)
                    continue
                self._inqueue.put((result._job, entry[2], func, args, kwds))
                entry[2] += 1
                self._inflight += 1
                sent = True
            return sent

        def _drain(self):
            got = False
            while self._outqueue._reader.poll(0):
                job, i, obj = self._outqueue.get()
                self._inflight -= 1
                result = self._cache.get(job)
                if result is not None:
                    result._set(i, obj)
                got = True
            return got

        def _check_running(self):
            if self._state != RUN:
                raise ValueError("Pool not running")

        def _submit(self, result, tasks):
            self._jobs.append([result, iter(tasks), 0])
            self._feed()
            return result

        def apply(self, func, args=(), kwds={}):
            return self.apply_async(func, args, kwds).get()

        def apply_async(self, func, args=(), kwds={}, callback=None, error_callback=None):
            self._check_running()
            return self._submit(ApplyResult(self, callback, error_callback), [(func, args, kwds)])

        def _map_async(self, func, iterable, mapper, chunksize=None, callback=None, error_callback=None):
            self._check_running()
            if not hasattr(iterable, "__len__"):
                iterable = list(iterable)
            if chunksize is None:
                chunksize, extra = divmod(len(iterable), len(self._pool) * 4)
                if extra:
                    chunksize += 1
            if len(iterable) == 0:
                chunksize = 0
            result = MapResult(self, chunksize, len(iterable), callback, error_callback)
            if chunksize:
                batches = get_tasks(func, iterable, chunksize)
                self._submit(result, ((mapper, (x,), {}) for x in batches))
            return result

        def map(self, func, iterable, chunksize=None):
            return self._map_async(func, iterable, mpool.mapstar, chunksize).get()

        def starmap(self, func, iterable, chunksize=None):
            return self._map_async(func, iterable, mpool.starmapstar, chunksize).get()

        def map_async(self, func, iterable, chunksize=None, callback=None, error_callback=None):
            return self._map_async(func, iterable, mpool.mapstar, chunksize, callback, error_callback)

        def starmap_async(self, func, iterable, chunksize=None, callback=None, error_callback=None):
            return self._map_async(func, iterable, mpool.starmapstar, chunksize, callback, error_callback)

        def _imap(self, func, iterable, chunksize, ordered):
            self._check_running()
            if chunksize < 1:
                raise ValueError(f"Chunksize must be 1+, not {chunksize:n}")
            result = IMapIterator(self, ordered)
            if chunksize == 1:
                self._submit(result, ((func, (x,), {}) for x in iterable))
                return result
            batches = get_tasks(func, iterable, chunksize)
            self._submit(result, ((mpool.mapstar, (x,), {}) for x in batches))
            return (item for chunk in result for item in chunk)

        def imap(self, func, iterable, chunksize=1):
            return self._imap(func, iterable, chunksize, True)

        def imap_unordered(self, func, iterable, chunksize=1):
            return self._imap(func, iterable, chunksize, False)

        def close(self):
            if self._state == RUN:
                self._state = CLOSE

        def terminate(self):
            self._state = TERMINATE
            for w in self._pool:
                if w.exitcode is None:
                    w.terminate()
            for w in self._pool:
                w.join()
            self._pool = []
            _pools.discard(self)

        def join(self):
            if self._state == RUN:
                raise ValueError("Pool is still running")
            if self._state == CLOSE:
                _wait_until(lambda: not self._jobs and not self._cache and self._inflight == 0)
                for _ in self._pool:
                    self._inqueue.put(None)
                _pools.discard(self)
            for w in self._pool:
                w.join()
            self._pool = []

        def __enter__(self):
            self._check_running()
            return self

        def __exit__(self, *exc):
            self.terminate()

        def __repr__(self):
            state = {RUN: "RUN", CLOSE: "CLOSE", TERMINATE: "TERMINATE"}[self._state]
            return f"<{type(self).__module__}.{type(self).__qualname__} state={state} pool_size={len(self._pool)}>"

    return Pool, ApplyResult


_ProcessPoolExecutor = None  # made with the Pool when multiprocessing is first imported


def _patch_futures():
    """concurrent.futures.wait/as_completed pump our pools for our futures
    (nothing else would complete them: there are no threads)."""
    global _PoolFuture
    import concurrent.futures as cf
    from concurrent.futures import _base

    class _PoolFuture(_base.Future):
        def result(self, timeout=None):
            _wait_until(self.done, timeout)
            return super().result(timeout=0)

        def exception(self, timeout=None):
            _wait_until(self.done, timeout)
            return super().exception(timeout=0)

    original_wait = _base.wait
    original_as_completed = _base.as_completed

    def ours(fs):
        return any(isinstance(f, _PoolFuture) for f in fs)

    def wait(fs, timeout=None, return_when=_base.ALL_COMPLETED):
        fs = set(fs)
        if not ours(fs):
            return original_wait(fs, timeout, return_when)

        def finished():
            done = [f for f in fs if f.done()]
            if return_when == _base.FIRST_COMPLETED:
                return bool(done)
            if return_when == _base.FIRST_EXCEPTION and any(
                    not f.cancelled() and f._exception is not None for f in done):
                return True
            return len(done) == len(fs)

        _wait_until(finished, timeout)
        done = {f for f in fs if f.done()}
        return _base.DoneAndNotDoneFutures(done, fs - done)

    def as_completed(fs, timeout=None):
        fs = set(fs)
        if not ours(fs):
            yield from original_as_completed(fs, timeout)
            return
        deadline = None if timeout is None else time.monotonic() + timeout
        pending = set(fs)
        while pending:
            done = [f for f in pending if f.done()]
            for f in done:
                pending.discard(f)
                yield f
            if not pending:
                return
            left = None if deadline is None else deadline - time.monotonic()
            if not _wait_until(lambda: any(f.done() for f in pending), left):
                raise TimeoutError(f"{len(pending)} (of {len(fs)}) futures unfinished")

    _base.wait = cf.wait = wait
    _base.as_completed = cf.as_completed = as_completed


def _make_executor(Pool):
    from concurrent.futures import _base

    class ProcessPoolExecutor(_base.Executor):
        """concurrent.futures.ProcessPoolExecutor on the thread-free Pool."""

        def __init__(self, max_workers=None, mp_context=None, initializer=None,
                     initargs=(), *, max_tasks_per_child=None):
            if max_workers is not None and max_workers <= 0:
                raise ValueError("max_workers must be greater than 0")
            self._max_workers = max_workers or os.process_cpu_count() or 1
            self._pool = Pool(self._max_workers, initializer, initargs, max_tasks_per_child, context=mp_context)
            self._shutdown = False

        def submit(self, fn, /, *args, **kwargs):
            if self._shutdown:
                raise RuntimeError("cannot schedule new futures after shutdown")
            f = _PoolFuture()
            f.set_running_or_notify_cancel()
            self._pool.apply_async(fn, args, kwargs, f.set_result, f.set_exception)
            return f

        def shutdown(self, wait=True, *, cancel_futures=False):
            if self._shutdown:
                return
            self._shutdown = True
            if cancel_futures:
                self._pool.terminate()
                return
            self._pool.close()
            if wait:
                self._pool.join()

    ProcessPoolExecutor.__module__ = "concurrent.futures.process"
    return ProcessPoolExecutor


def _patch_futures_process(module):
    import concurrent.futures as cf
    import multiprocessing  # noqa: F401  (makes _ProcessPoolExecutor)
    module.ProcessPoolExecutor = _ProcessPoolExecutor
    cf.ProcessPoolExecutor = _ProcessPoolExecutor


# ---------------------------------------------------------------------------
# Post-import hooks: patch modules when they are first imported, so a
# process that never uses multiprocessing doesn't pay for importing it.

_post_import = {}


class _Loader:
    def __init__(self, loader, name):
        self._loader = loader
        self._name = name

    def create_module(self, spec):
        return self._loader.create_module(spec)

    def exec_module(self, module):
        self._loader.exec_module(module)
        for fn in _post_import.pop(self._name, []):
            fn(module)

    def __getattr__(self, attr):
        return getattr(self._loader, attr)


class _PostImportFinder:
    def find_spec(self, name, path=None, target=None):
        if name not in _post_import:
            return None
        for finder in sys.meta_path:
            if finder is self or not hasattr(finder, "find_spec"):
                continue
            spec = finder.find_spec(name, path, target)
            if spec is not None:
                if spec.loader is not None:
                    spec.loader = _Loader(spec.loader, name)
                return spec
        return None


def _after_import(name, fn):
    """Call fn(module) now if `name` is imported, else right after it is."""
    if name in sys.modules:
        fn(sys.modules[name])
    else:
        _post_import.setdefault(name, []).append(fn)


# ---------------------------------------------------------------------------
# subprocess: Python only

def _is_python(path):
    if not path:
        return False
    name = os.path.basename(os.fsdecode(path))
    return path in (EXECUTABLE, sys.executable) or name in ("python", "python3") or (
        name.startswith("python3.") and name[8:].isdigit())


_FLAGS = {"-u", "-B", "-E", "-s", "-S", "-I", "-O", "-OO", "-q", "-P", "-b", "-bb", "-d", "-v", "-i"}


def _parse_python_args(args):
    """(mode, value, sys.argv) from a python command line, without argv[0]."""
    i = 0
    while i < len(args):
        a = args[i]
        if a == "-c" or a == "-m":
            if i + 1 >= len(args):
                raise ValueError(f"Argument expected for the {a} option")
            if a == "-c":
                return "c", args[i + 1], ["-c"] + args[i + 2:]
            return "m", args[i + 1], [args[i + 1]] + args[i + 2:]
        if a.startswith("-c") and len(a) > 2:
            return "c", a[2:], ["-c"] + args[i + 1:]
        if a.startswith("-m") and len(a) > 2:
            return "m", a[2:], [a[2:]] + args[i + 1:]
        if a in _FLAGS:
            i += 1
            continue
        if a in ("-X", "-W"):
            i += 2
            continue
        if a == "-":
            return "stdin", None, [""] + args[i + 1:]
        if a.startswith("-"):
            raise ValueError(f"unsupported python option {a!r}")
        return "path", a, args[i:]
    return "stdin", None, [""]


def _fork_exec(args, executable_list, close_fds, fds_to_keep, cwd, env_list,
               p2cread, p2cwrite, c2pread, c2pwrite, errread, errwrite,
               errpipe_read, errpipe_write, *rest):
    """subprocess's _fork_exec: start a Python program in a new worker."""
    args = [os.fsdecode(a) for a in args]
    exe = os.fsdecode(executable_list[0]) if executable_list else args[0]
    if not (_is_python(exe) or _is_python(args[0])):
        raise FileNotFoundError(errno.ENOENT, "only Python can be started as a subprocess here "
                                "(iOS has no other programs); use sys.executable", args[0])
    mode, value, argv = _parse_python_args(args[1:])
    pid, sentinel, life = _new_child()
    try:
        stdio = {}
        for target, fd in ((0, p2cread), (1, c2pwrite), (2, errwrite)):
            stdio[str(target)] = str(_procs.transfer(fd, pid)) if fd != -1 else None
        parent = str(_procs.life_reader(_my_life(), pid))
        os.close(sentinel)
        env = None if env_list is None else [os.fsdecode(e) for e in env_list]
        cwd = os.getcwd() if cwd is None else os.path.abspath(os.fsdecode(cwd))
    except BaseException:
        _procs.abandon(pid)
        raise
    _spawn(pid, {"kind": "python", "mode": mode, "value": value, "argv": argv,
                 "cwd": cwd, "env": env, "stdio": stdio, "life": life, "parent": parent})
    return pid


def _run_python(task):
    for target, desc in task["stdio"].items():
        if desc:
            _procs.adopt_as(desc, int(target))
    if task["stdio"].get("0"):
        sys.stdin = open(0, "r", encoding="utf-8", closefd=False)
    if task["stdio"].get("1"):
        sys.stdout = open(1, "w", encoding="utf-8", closefd=False)
    if task["stdio"].get("2"):
        sys.stderr = open(2, "w", encoding="utf-8", errors="backslashreplace", closefd=False)
    if task["env"] is not None:
        os.environ.clear()
        for item in task["env"]:
            k, _, v = item.partition("=")
            os.environ[k] = v
    if task["cwd"]:
        os.chdir(task["cwd"])
    sys.argv = task["argv"]
    import runpy
    mode, value = task["mode"], task["value"]
    if mode == "c":
        sys.path.insert(0, "")
        exec(compile(value, "<string>", "exec"), {"__name__": "__main__", "__builtins__": __builtins__})
    elif mode == "m":
        sys.path.insert(0, os.getcwd())
        runpy.run_module(value, run_name="__main__", alter_sys=True)
    elif mode == "path":
        sys.path.insert(0, os.path.dirname(os.path.abspath(value)))
        runpy.run_path(value, run_name="__main__")
    else:
        source = sys.stdin.read()
        exec(compile(source, "<stdin>", "exec"), {"__name__": "__main__", "__builtins__": __builtins__})
    return 0


def _patch_subprocess(subprocess):
    subprocess._can_fork_exec = True
    subprocess._fork_exec = _fork_exec
    subprocess._USE_POSIX_SPAWN = False
    ds = subprocess._del_safe
    ds.waitpid = waitpid
    ds.waitstatus_to_exitcode = os.waitstatus_to_exitcode
    ds.WIFSTOPPED = os.WIFSTOPPED
    ds.WSTOPSIG = os.WSTOPSIG
    ds.WNOHANG = os.WNOHANG


# ---------------------------------------------------------------------------
# multiprocessing

def _patch_multiprocessing(module=None):
    import multiprocessing
    from multiprocessing import context, heap, popen_spawn_posix, sharedctypes, synchronize, util
    from multiprocessing import connection

    popen_spawn_posix.Popen = _make_popen()
    for name in ("fork", "forkserver"):
        context._concrete_contexts.pop(name, None)
    context._default_context._default_context = context._concrete_contexts["spawn"]
    context._default_context._actual_context = None

    original_get_context = context.BaseContext.get_context

    def get_context(self, method=None):
        if method in ("fork", "forkserver"):
            raise ValueError(f"cannot find context for {method!r}: every process is a new interpreter "
                             "here, so 'spawn' is the only start method")
        return original_get_context(self, method)

    context.BaseContext.get_context = get_context
    context.DefaultContext.get_all_start_methods = lambda self: ["spawn"]

    def set_start_method(self, method, force=False):
        if method not in (None, "spawn"):
            raise ValueError(f"cannot use start method {method!r}: 'spawn' is the only one here")
        return original_set_start_method(self, method, force)

    original_set_start_method = context.DefaultContext.set_start_method
    context.DefaultContext.set_start_method = set_start_method

    def Pipe(duplex=True):
        if duplex:
            a, b = _ints(_procs.socketpair())
            return connection.Connection(a), connection.Connection(b)
        r, w = pipe()
        return connection.Connection(r, writable=False), connection.Connection(w, readable=False)

    connection.Pipe = Pipe

    sharedctypes.Value = Value
    sharedctypes.Array = Array
    sharedctypes.RawValue = RawValue
    sharedctypes.RawArray = RawArray
    heap.BufferWrapper = BufferWrapper

    def no_manager(self):
        raise NotImplementedError("multiprocessing managers need a server process with threads, "
                                  "which aren't available here; use Queue, Pipe, Value or Array")

    context.BaseContext.Manager = no_manager
    multiprocessing.Manager = types.MethodType(no_manager, context._default_context)

    _patch_queues()
    global _ProcessPoolExecutor
    Pool, _ = _make_pool()
    from multiprocessing import pool as mpool
    mpool.Pool = Pool
    _ProcessPoolExecutor = _make_executor(Pool)
    cfp = sys.modules.get("concurrent.futures.process")
    if cfp is not None and hasattr(cfp, "ProcessPoolExecutor"):
        _patch_futures_process(cfp)


# ---------------------------------------------------------------------------

def install():
    """Patch the standard library for this worker's process."""
    global _installed
    if _installed:
        return
    _installed = True
    os.getpid = getpid
    os.getppid = getppid
    os.cpu_count = cpu_count
    os.process_cpu_count = cpu_count
    os.pipe = pipe
    os.fork = fork
    os.waitpid = waitpid
    os.kill = kill
    time.sleep = sleep
    _select.poll = poll
    _select.select = select
    selectors.PollSelector._selector_cls = poll
    sys.executable = EXECUTABLE
    sys.modules["_multiprocessing"] = _make_multiprocessing_module()
    sys.meta_path.insert(0, _PostImportFinder())
    _after_import("subprocess", _patch_subprocess)
    _after_import("concurrent.futures", lambda m: _patch_futures())
    _after_import("multiprocessing", _patch_multiprocessing)
    _after_import("concurrent.futures.process", _patch_futures_process)


def _exit_code(e):
    if e.code is None:
        return 0
    if isinstance(e.code, int):
        return e.code
    sys.stderr.write(str(e.code) + "\n")
    return 1


def run_task(task_json, payload):
    """Run this worker's task; returns the exit code (negative: killed by
    that signal)."""
    global _MY_LIFE
    task = json.loads(task_json)
    payload = payload.to_bytes() if payload is not None else None
    kind = task["kind"]
    if task.get("life") is not None:
        _MY_LIFE = task["life"]
    try:
        if kind == "main":
            os.chdir(task["cwd"])
            from multiprocessing import process
            process.ORIGINAL_DIR = os.getcwd()
            sys.argv = task["argv"]
            sys.path.insert(0, os.path.dirname(task["path"]))
            import runpy
            runpy.run_path(task["path"], run_name="__main__")
            code = 0
        elif kind == "mp":
            code = _run_mp(task, payload)
        elif kind == "python":
            code = _run_python(task)
        else:
            raise ValueError(f"unknown task {kind!r}")
    except SystemExit as e:
        code = _exit_code(e)
    except KeyboardInterrupt:
        traceback.print_exc()
        code = -signal.SIGINT
    except BaseException:
        traceback.print_exc()
        code = 1
    try:
        atexit._run_exitfuncs()
        _flush_pending(block=True)
    except BaseException:
        traceback.print_exc()
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.flush()
        except Exception:
            pass
    for fd in (0, 1, 2):
        try:
            if kind == "python" and task["stdio"].get(str(fd)):
                os.close(fd)
        except OSError:
            pass
    return code
