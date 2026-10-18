# Processes

A program can start more Pythons: `multiprocessing` runs functions in other
processes, and `subprocess` runs other Python programs. Every process is a
Python interpreter of its own, so work spread over several processes runs
on several CPU cores at the same time. The example `Processes.py` shows all
three ways below.

```python
import multiprocessing as mp


def square(n):
    return n * n


if __name__ == "__main__":
    with mp.Pool() as pool:
        print(pool.map(square, range(10)))
```

## Starting processes

Processes are started fresh, as with the `spawn` start method on macOS and
Windows: a new process imports your program's file again, then runs the
function it was given. Two things follow from that:

- **Keep the `if __name__ == "__main__":` guard.** Code outside it runs again
  in every new process. Without the guard, starting a process from there
  fails with a `RuntimeError` that explains this.
- **What a process gets has to be picklable**: functions defined at the top
  of a file (not lambdas or functions defined inside other functions) and
  their arguments. Functions typed into the console or defined in a
  notebook cell can't be pickled this way.

`fork` and `forkserver` are not available (`os.fork()` raises `OSError`):
an interpreter can't be copied here, only started.

A new process takes a moment to start, about a tenth of a second when a
spare one is ready and a second or more when one has to be started first.
`os.cpu_count()` is at most 4, so `Pool()` and `ProcessPoolExecutor()`
start 4 processes; each one is a whole Python and uses about 100 MB of
memory. At most 10 processes run at once.

## What works

- `multiprocessing.Process`: `start()`, `join()` with or without a timeout,
  `is_alive()`, `exitcode`, `terminate()`, `kill()`, `daemon`, `pid`,
  `name`, `sentinel`, `current_process()`, `parent_process()`,
  `active_children()`.
- **Communication**: `Pipe()`, `Queue`, `SimpleQueue`, `JoinableQueue` and
  `multiprocessing.connection.wait()`.
- **Synchronization**: `Lock`, `RLock`, `Semaphore`, `BoundedSemaphore`,
  `Event`, `Condition` and `Barrier`.
- **Shared values**: `Value`, `Array`, `RawValue` and `RawArray` with simple
  types (`"i"`, `"d"`, `ctypes.c_double`, …).
- **Pools**: `multiprocessing.Pool` (`map`, `imap`, `imap_unordered`,
  `starmap`, `apply_async`, callbacks, `maxtasksperchild`, `initializer`)
  and `concurrent.futures.ProcessPoolExecutor` with `as_completed()` and
  `wait()`. An exception in a worker is raised again in your program, with
  the worker's traceback attached.
- `subprocess` for Python programs: `sys.executable`, `python` or `python3`
  with `-c`, `-m` or a script, `run()`, `check_output()`, `Popen`,
  `communicate()`, pipes for stdin, stdout and stderr, `timeout`, `env`,
  `cwd` and return codes. Other programs don't exist on iOS: running them
  raises `FileNotFoundError`.
- `os.getpid()`, `os.getppid()`, `os.waitpid()` and `os.kill()` with
  `SIGINT`, `SIGTERM` and `SIGKILL`.

All processes work in the program's folder, and they see each other's
files. Their `print()` output goes to the console; `input()` in a child
process gets end-of-file, as a `multiprocessing` child's would.

Packages the program uses (numpy, or ones declared in a `# /// script`
block) are loaded in the new processes too.

## Differences from a computer

- **No shared memory**: `multiprocessing.shared_memory` and numpy arrays on
  top of an `Array` are not available (a `SharedMemory` raises `OSError`;
  importing the module works, so libraries that import it, like
  scikit-learn through joblib, load fine). `Value` and `Array` work, but each
  access is a small message, so they are slower than on a computer.
- **No managers**: `multiprocessing.Manager()` needs threads, which the app
  doesn't have; it raises `NotImplementedError`. `ThreadPool` and
  `ThreadPoolExecutor` don't work either.
- **Bookkeeping without threads**: `Queue`, `Pool` and `ProcessPoolExecutor`
  do the work that has threads of its own on a computer whenever your
  program waits on them (`get()`, `join()`, `result()`, iterating `imap`).
  Callbacks run then too, not in the background.
- **Notebooks and the console** have no file for new processes to import,
  so they can only start processes with functions from a module in the
  folder (`from helpers import work`).

## Stop

**Stop** ends the program and all of its processes: each one gets
`KeyboardInterrupt`, and a process that doesn't end within a second and a
half is ended. When the program ends, it waits for the processes it started
(as Python does at exit) and ends the daemon processes; processes still
running when you run something else are ended.
