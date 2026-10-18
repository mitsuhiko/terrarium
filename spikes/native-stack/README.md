# native-stack

2026-10-17 - WKWebView on the iOS 27 simulator (iPhone 18 Pro), Python 3.14
(Pyodide 314.0.7) in a worker, as the app runs it (wasm-gc trampoline, JSPI).
Not a real device. A simulator worker has the same 512 KB native stack as
one on the iPhone 14 Pro (544 vs 545 wasm frames, `spikes/device-perf/`).

**Question (Q14):** Can CPython raise `RecursionError` before recursion
through C code runs out of the worker's native stack (which ends Pyodide
with "Maximum call stack size exceeded"), e.g. with a smaller stack
protection (`PyUnstable_ThreadState_SetStackProtection`)? If not, what
helps?

**Answer:** Not with CPython's check. It measures the linear (Emscripten)
stack, and how much of it a C call uses has nothing to do with how much
native stack it uses: at the native overflow, the cases below had used
between 0.9 KB and 234 KB of the linear stack, while normal programs use up
to 96 KB (`import pandas`). No limit sits between the two.

What helps is warming up: JSC first runs wasm with its baseline compiler,
whose native frames are much bigger than its optimizing compiler's. A fresh
interpreter that ran the usual paths through C code a few hundred times
(about 20 ms) recurses 1.5 to 6 times deeper before the crash. The app does
that in every new worker (`_terrarium_warmup.py`, D49), and shows the crash
that remains as a `RecursionError` traceback with the program's frames.

## What it is

`./run.sh` builds a SwiftUI app with one WKWebView (hosted like the app's
engine page) and the app's two Pyodide cores, and prints JSON.
- **The page** (`web/main.js`) runs each case in a fresh worker, because a
  crash ends the interpreter.
- **The worker** (`web/worker.js`) boots Pyodide as the app does,
  optionally warms it up or sets a stack protection, and runs the case with
  `runPython` (sync) or `runPythonAsync` (async, how programs run).
- **On a crash**, Pyodide's fatal error hook reads the linear stack
  pointer, which is still where the overflow happened (wasm unwinding
  doesn't restore it). Without a crash, the high-water mark comes from a
  canary written below the stack pointer first.
- **`find=1`** looks for the deepest N that doesn't crash, per case.

```sh
STEPS="modes=sync,async&n=100000&kinds=crash,normal" ./run.sh   # where each case crashes
STEPS="find=1&modes=async&n=20000&warm=generic" ./run.sh         # the deepest N, warmed up
STEPS="modes=sync,async&limits=32768&kinds=crash,normal" ./run.sh   # with a stack protection
STEPS="wasm=1" ./run.sh                                          # plain wasm frames, with and without JSPI
```

## Results

**Deepest recursion before the crash** (async, as programs run). "Warmed
up" is the generic warm-up (`GENERIC_WARMUP`, the same as the app's
`_terrarium_warmup.py`); "the case itself" ran the case 200 times at depth 20
first.

| case | cold | warmed up | the case itself |
|---|---|---|---|
| `repr` of nested lists | 183 | 1153 | 1136 |
| `json.loads` of nested lists | 187 | 1178 | 197 |
| `==` of nested lists | 345 | 1349 | 1332 |
| `__repr__` in Python, nested | 123 | 335 | 330 |
| recursion through `map()` | 114 | 372 | 367 |
| recursion through `@lru_cache` | 79 | 265 | 262 |
| recursion through `__init__` | 205 | 1349 | 1332 |
| recursion through `__getattr__` | 199 | 200 | 354 |
| `==` of nested dataclasses | 149 | 150 | 392 |
| `sorted(key=)` recursion | | 217 | |
| `yield from` chain | | 1614 | |
| `__str__` with an f-string, nested | | 268 | |
| `pickle.dumps` of nested lists | | 875 | |
| `ast.parse` of `- - - ... 1` | 263 | 263 | |
| `isinstance` with nested tuples | 3436 | | 3414 |

The warm-up misses what it doesn't run (`__getattr__` and dataclass `==`
take other paths than the warm-up's), and the parser doesn't improve.
Plain Python recursion doesn't use the native stack at all: 100,000 levels
work with a raised `sys.setrecursionlimit()`.

**Linear stack used at the crash**, cold (sync / async): `isinstance` 0.9 /
1.5 KB, `==` of lists 6.4 / 6.9 KB, `repr` 7.0 / 7.5 KB, `yield from` 12.6 /
12.9 KB, `json.loads` 13.8 / 14.1 KB, `lru_cache` 36.8 / 37.4 KB, `map()`
52.1 / 51.4 KB, `__repr__` 64.5 / 63.7 KB, `__getattr__` 94.0 / 92.3 KB,
`pickle` 158 / 155 KB, `sorted(key=)` 235 / 229 KB. Python frames entered
from C use about 470 bytes of the linear stack each; C recursion like `repr`
or `==` only 20-45 bytes per level.

**Normal programs' high-water marks** (linear stack): `import numpy,
pandas` 96 KB, matplotlib with a plot 56 KB, a dozen stdlib imports 42 KB,
`__repr__` 100 deep 47 KB, `map()` recursion 100 deep 45 KB, 900 levels of
Python recursion 9 KB.

**The stack protection:** with 32 KB in sync mode, CPython raises
`RecursionError: Stack overflow (used 16 kB)`, also for the stdlib imports
and `__repr__` 100 deep. In async mode it has no effect: Pyodide gives each
JSPI task its own thread state (`stack_switching/pystate.c`), with the
default limits from the 10 MB linear stack. Even where it works, a limit
low enough to catch `lru_cache` breaks `import pandas`.

**Other findings:**
- JSPI doesn't change the native stack: 543 plain wasm frames in a
  `WebAssembly.promising` call, 545 without.
- In async mode `json.loads` of 200 nested lists crashes cold (sync: works).
- Pyodide's own dump of the Python stack at a crash shows the main thread
  state, not the task that crashed; the app walks every thread state with
  the C API instead (`py-worker.js`, `crashedStack`).

## Not covered

- A real device with this spike. The app's `crash_recovery` self-test
  passes on the iPhone 14 Pro (2026-10-17): with the warm-up, `@lru_cache`
  recursion got 288 deep there, as in the simulator.
- Python 3.15 (Pyodide 315): not measured.
- What would fix it upstream: CPython counting C recursion on Emscripten
  besides the stack pointer, a native-stack check from Pyodide, or bigger
  worker stacks in WebKit (`WTF/Threading.cpp` uses the Darwin default).
