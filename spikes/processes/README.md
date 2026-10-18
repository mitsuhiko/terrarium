# processes

2026-10-16 - Pyodide 314.0.7 and 315.0.0a2: in WKWebView on the iOS 27
simulator (iPhone 18 Pro Max), and in Node 25 (`worker_threads`). Not tried
on a real device.

**Outcome:** built into the app as D47. Two changes since (also here):
a Stop wins over an event that arrived at the same time in a wait, and the
children of a run get only Pyodide's own packages by name. In the app,
PyPI ones are installed with micropip.

**Question:** Can `multiprocessing` (spawn semantics) and `subprocess`
(Python programs only) run on the stock Pyodide builds, with each process
its own worker? That means pipes and locks shared between workers,
`Queue`/`Pool`/`ProcessPoolExecutor` without threads, and Stop reaching the
whole tree, all done with runtime patches rather than a rebuild. What does
it cost: start latency, memory and speedup?

This is the first step towards local servers and running several programs
at once. Both need more than one interpreter per run, and a way to wait on
file descriptors with a timeout.

**Answer:** Yes. All 10 test programs pass on both Pythons, in Node and in
WKWebView on the simulator: 102 checks, plus a Stop test judged by how its
processes ended. Nothing in Pyodide had to be rebuilt:
- Emscripten's file system takes a custom pipe file system at runtime.
- `select`/`selectors` are replaced in Python.
- `_multiprocessing`, `Queue`, `Pool` and `ProcessPoolExecutor` are
  replaced or patched in Python.
- `subprocess` keeps its own logic; only `_fork_exec`, `waitpid` and
  `kill` are replaced.

The costs:
- **Starting a process:** about 55-130 ms from a warm worker, but 1.5-3.5 s
  on the simulator when one has to boot first.
- **Memory:** about 95 MB per idle process (simulator RSS).
- **Speedup:** CPU-bound work reaches about 3-4x on the simulator's
  8 cores.

What isn't there:
- **Shared memory:** `shared_memory` and numpy on shared buffers can't be
  done. Each worker has its own wasm memory.
- **Managers:** they need a server process with threads.
- **Threads in general:** `ThreadPool` and anything else that starts a
  thread still fail.

## How it works

```
page (or Node main thread): Manager (web/procs-manager.js)
  owns the workers, a warm pool, the process tree, the shared objects
  │ postMessage: spawn, kill, share, output, started, exit
  ▼
worker per process (web/worker.js): its own Pyodide
  _procs (web/procs-worker.js): pipes as fds, waits, semaphores, pids
  _terrarium_procs.py: patches os, time, select, selectors, multiprocessing,
                    subprocess, concurrent.futures
```

- **One control block** is a SharedArrayBuffer that every worker gets
  (`procs-shared.js`). It holds:
  - the pid counter;
  - the process table (state and wait status per pid);
  - the semaphores' values;
  - an epoch, which every pipe change and process exit bumps.
- **Pipes** are SharedArrayBuffer rings (1 MB; 16 bytes for "life" pipes).
  Each one is behind a file descriptor of `MPFS`, a small Emscripten file
  system mounted at runtime (`Module.SOCKFS`/`FS` are exposed in both
  builds):
  - `os.read`, `os.write`, `os.dup`, `os.close` and `fstat` work on them,
    from Python and from C.
  - A blocking read or write waits with `Atomics.wait` in 50 ms slices.
  - Each pipe counts the open read and write ends per pid. That gives EOF
    and `EPIPE` across processes, and the manager drops a dead process's
    ends, as the kernel would.
- **Waiting with a timeout** happens in JS (`wait_fds`), because
  Emscripten's `poll()` ignores its timeout in both builds:
  - `select.poll`, `select.select` and `selectors.PollSelector` are
    replaced. `multiprocessing.connection.wait`, `subprocess`'s
    `communicate()` and the `Pool` use them.
  - They check every fd's `stream_ops.poll`, then wait on the epoch.
- **Starting a process** is spawn, done the way `popen_spawn_posix` does it:
  - The parent pickles the preparation data and the process object.
    `DupFd` counts pipe ends for the child, which adopts them when it
    unpickles.
  - The manager starts a worker, and the worker runs `spawn.prepare` and
    `_bootstrap`.
  - `popen_fork.Popen`'s own `poll`/`wait`/`terminate`/`kill` work on top
    of the replaced `os.waitpid` and `os.kill`.
  - `Process.sentinel` and `parent_process()` use "life pipes": a pipe
    whose write end counts as held by the process, so it reads EOF once
    the process has exited.
- **Locks:** `_multiprocessing.SemLock` is a fake module. The value lives
  in the control block (CAS plus `Atomics.wait`); the count and owner stay
  in the process, as in CPython. So `Lock`, `RLock`, `Semaphore`,
  `BoundedSemaphore`, `Event`, `Condition` and `Barrier` are the stdlib's
  own classes.
- **Shared values:** `Value`, `Array`, `RawValue` and `RawArray` are
  objects on a SharedArrayBuffer, typed through `struct`. Every access is
  a call into JS. `heap.BufferWrapper` is replaced so that `Barrier`
  works.
- **Queue without a feeder thread:**
  - `put()` writes the pickled message at once if it fits.
  - Otherwise it keeps the message, and every wait in this process (get,
    join, sleep, lock, select) flushes what is kept, in 20 ms slices.
  - Whatever is left is flushed at exit, as CPython joins the feeder.
  - So putting 4 MB before any reader exists works, as in CPython.
- **Pool and ProcessPoolExecutor without handler threads:**
  - They use the stdlib's `pool.worker` in the children.
  - The parent sends tasks (at most 2 per worker in flight), collects
    results, runs callbacks and replaces exited workers whenever it waits
    on the pool: `get`, `wait`, `imap`'s `next`, `join`, `result`.
  - `concurrent.futures.wait`/`as_completed` drive this for our futures.
- **subprocess:**
  - `subprocess._fork_exec` starts a worker when the program is Python:
    `sys.executable` (`/usr/bin/python3`), `python`, `python3` or
    `python3.N`, with `-c`, `-m`, a script, or `-`. Stdio pipes are
    adopted as fds 0-2.
  - Everything else raises `FileNotFoundError`, saying that only Python
    can be started.
- **Lazy patches:** a post-import hook patches `multiprocessing` and
  `concurrent.futures.process` when they are first imported. A process that
  never uses them pays about 20 ms for `install()` (Node) instead of 155 ms.
- **Warm pool:**
  - The manager keeps booted workers ready (2 by default).
  - They preload the multiprocessing modules, like forkserver's preload.
    That cuts an empty process's start+join from about 160 ms to 60 ms in
    Node.
  - Each process is a fresh worker and is never reused; it is terminated
    when it exits.
- **Stop** is SIGINT to every process in the tree (the interrupt buffer,
  so KeyboardInterrupt), then SIGKILL after 1.5 s, as in the app (D11).
  - A blocked pipe read returns EINTR, which CPython turns into
    KeyboardInterrupt.
  - Waits called from Python use `pyodide.checkInterrupt()`.
  - A process that hasn't started running Python yet is simply ended
    (SIGINT's default action).
  - When the root exits, whatever is left of its tree is killed.

## Running it

```sh
node fetch-packages.mjs                   # numpy wheels into build/ (run.sh does it too)
node node/run.mjs                         # all tests in Node
node node/run.mjs t_pool,t_subprocess     # some
PYODIDE=315.0.0-alpha.2 WARM=4 PRELOAD=0 node node/run.mjs
./run.sh                                  # the iOS simulator (booted), prints JSON
PYODIDE=315.0.0-alpha.2 ./run.sh t_memory,t_perf
```

`run.sh` also samples the RSS of the simulator's WebContent processes
(`sample-memory.mjs`). It only counts the ones that appeared after launch,
and adds each test's peak to the JSON (`t_memory`: per phase).

The tests (`web/tests/`) are ordinary programs. Each ends with a `RESULT`
line:

| Test | What it checks |
|---|---|
| `t_basic` | spawn only (fork refused), exit codes, `sys.exit`, exceptions, `terminate`/`kill` (-15/-9), `join(timeout)`, pids, names, `parent_process()`, grandchildren, `connection.wait` on sentinels, daemons ended at exit |
| `t_ipc` | duplex `Pipe` echo, 1 and 5 MB messages, `Queue` (2000 items, `Empty`, `Full`, `qsize`), 4 MB put before the reader exists, `SimpleQueue`, `JoinableQueue.join()`, a child's queued results arriving after it exits |
| `t_sync` | `Value` counter from 4 processes, `Array`, `c_double`, `Lock` with a timeout, `Event`, `Semaphore(2)` caps concurrency, `Condition`, `Barrier(3)`, `RLock`, `BoundedSemaphore`, `Manager()` explains |
| `t_pool` | `map`/`imap`/`imap_unordered`/`starmap`/`apply_async`, callbacks, chunks, errors with the remote traceback, `maxtasksperchild`, `initializer`, `close`+`join`, `ProcessPoolExecutor` (`map`, `as_completed`, `wait`, exceptions, done callbacks) |
| `t_subprocess` | `run`/`check_output`/`Popen`, `-c`/`-m json.tool`/scripts, stdin, stderr, `STDOUT`, `DEVNULL`, env, cwd, return codes, `check=True`, timeouts, `terminate`, SIGINT reaching the child as KeyboardInterrupt, nested subprocesses, non-Python programs refused |
| `t_guard` | no `__main__` guard: the child fails with CPython's explanation; a lambda target fails to pickle in the parent |
| `t_numpy` | numpy arrays through a `Pool` (children load the parent's packages) |
| `t_stop` | Stop with children blocked in `recv`, `Queue.get`, `sleep`, `Lock.acquire`, a busy loop and a subprocess |
| `t_memory` | 0, 1, 2, 4, 8 idle children, 2 s each |
| `t_perf` | start+join of an empty process; counting primes, serial vs `Pool(1..8)` |

## Results

Files:
- `results-iphone18promax-sim-314.json` and `-315.json`: all tests, one
  WebContent process.
- `results-iphone18promax-sim-314-memory.json` and `-perf.json`: clean
  runs (a fresh WebContent process).
- `results-node-314.json` and `-315.json`: Node.

All checks pass in every one of them.

| | Node (M-series Mac) | Simulator 3.14 | Simulator 3.15 |
|---|---|---|---|
| boot a worker (Pyodide + preload) | 1.1-1.3 s | 1.5-1.8 s alone; median 2.9-3.7 s, p90 5-7 s when several boot at once | same |
| preload of the multiprocessing modules | ~110 ms | 100-250 ms | 100-160 ms |
| start, warm worker → user code | 20-55 ms | 55-130 ms | 50-90 ms |
| start+join, empty process (warm / median under churn) | 57 / 75 ms | 67-86 / 660-770 ms | 68 / 514 ms |
| `subprocess.run` of `-c "print(..)"` | 24-46 ms | 74-123 ms | 59 ms |
| pipe round trip (small message) | 0.04 ms | 0.1-0.26 ms | 0.08 ms |
| 5 MB through a pipe | 4-5 ms | 10-17 ms | 9 ms |
| Stop → whole tree (7 processes) ended | 53-59 ms | 49-50 ms | 80 ms |
| `Pool(4)` speedup (CPU-bound) | 3.8x | 2.4-3.0x | 3.6x |
| `Pool(8)` speedup | 5.6-5.9x | 3.2-3.7x | 4.1x |
| memory per idle process | ~80 MB (Node RSS) | ~95 MB | ~95 MB |

Memory on the simulator (WebContent RSS, `t_memory`, a fresh run; each
phase also has the root and 2 warm workers):

| idle children | 0 | 1 | 2 | 4 | 8 |
|---|---|---|---|---|---|
| 3.14 | 691 MB | 768 | 844 | 1065 | 1413 |
| 3.15 | 676 MB | 756 | 841 | 1046 | 1438 |

What we learned:
- **The approach is sound.** Stdlib code runs unchanged on top of the
  replaced OS layer: `popen_fork`'s `poll`/`wait`, `subprocess`'s
  `_communicate`, `pool.worker`, `synchronize`'s classes. CPython's
  semantics carry over, including KeyboardInterrupt in children, the exit
  code 1 with "Process X:" and its traceback, the no-guard
  `RuntimeError`, and objects shared only by inheritance.
- **Boot time dominates.** Processes are cheap once a worker is warm. But
  a boot takes 1.5-1.8 s on the simulator, and several boots at once slow
  each other down (p90 5-7 s). Programs that start processes one after
  another use up the warm pool quickly. A bigger pool costs about 95 MB
  per worker.
- **Fresh workers are slower at first.** On the simulator, `Pool(1)`
  reaches only 0.78-0.99x of the parent's serial speed (1.0x in Node), probably because each worker's
  wasm code tiers up again. Boots running in the background (the pool
  refilling) also compete with the work: `Pool(2)` reached only 1.1-1.4x
  on the simulator.
- **Memory is the hard limit on a device.**
  - About 95 MB per idle process. On the iPhone 14 Pro, iOS kills
    WebContent at about 1.9 GB (Q15), so the cap is probably 6-10
    processes, fewer with packages loaded.
  - In the full runs, after about 150 workers had come and gone, RSS
    stayed at 1.8-2.1 GB instead of going back down. Memory of terminated
    workers isn't returned quickly.
  - On a device, either could end in the jetsam kill. That needed a device
    run (Q24). Update 2026-10-17: processes work in the app on the iPhone
    14 Pro (D47).
- **Bugs found on the way, now fixed:**
  - Closing Pyodide's own stdin stream on Node crashes it (`dup2` onto
    fd 0), so stdio is adopted without closing what was there.
  - A Stop that reached a process still in setup escaped as a crash. Now
    the manager ends a process that hasn't started Python yet.
  - Tests that assumed workers start together were wrong: they now wait
    on a `Barrier`.
- **One hang I couldn't reproduce:** `Pool.close()` + `join()` hung once
  in the first full simulator run. That was before the stop and warm-pool
  fixes, and it didn't happen in 6 runs since. `_wait_until` now prints
  the pool's state (`[pool diag]`) when it waits for more than 20 s.

## Not done / open

- **On a device:** memory per process and the jetsam limit with several
  workers, whether churned workers' memory comes back, boot time, speedup
  on 2 performance + 4 efficiency cores, and what `hardwareConcurrency`
  reports there (8 on the simulator).
- **Files:** here each worker has its own MEMFS with the project's files
  copied in. A file one process writes isn't seen by another. In the app
  all workers mount the project folder with HostFS (D35), but its file
  locking is not shared between workers.
- **Not built:**
  - Shared memory (`shared_memory`, numpy views of `Array`).
  - Managers.
  - `os.fork()` (it raises).
  - `ThreadPool` and anything that starts threads.
  - `multiprocessing.Queue` with messages bigger than the 1 MB pipe:
    `put()` blocks until a reader takes them, as a full pipe would block
    the feeder.
- **Possible speedups:**
  - Share the compiled `WebAssembly.Module` between workers (less memory
    and boot time).
  - Apply the patches at boot in warm workers. `install()` still takes
    50-200 ms on the simulator.
  - Preload the parent's packages in warm workers. numpy takes 0.4-0.8 s
    per child.
  - Reuse workers for `Pool` tasks.
- **Async:** asyncio servers need `create_server` in Pyodide's WebLoop,
  not these blocking waits. They are not part of this spike.
- **Leaks:** the manager keeps every shared object of a run until the run
  ends (each pipe is a SharedArrayBuffer).
