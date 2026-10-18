# device-perf

2026-10-13 - iPhone 14 Pro (A16, 6 GB), iOS 27, signed with a free personal
team. Simulator numbers (iPhone 17 simulator on a Mac) for comparison.

**Questions:** Q3 (bridge latency), Q5 (startup, memory, speed), Q6 (background),
Q12 (is the wasm-GC trampoline safe on devices).

## What it is

- `DevicePerf.xcodeproj`: a hand-written minimal project (objectVersion 77,
  synchronized folder pointing at `../pyodide-worker/Sources`, generated
  Info.plist, automatic signing with team `ZRL6J4P42H`, bundle id
  `eu.ronacher.TerrariumSpike`). The `copy-web.sh` build phase bundles the
  pyodide-worker web runtime, `ui-toolkit/web` (as `ui/`), `jspi-repro/web` (as
  `jspi/`) and the Pyodide core.
- `run.sh`: builds with `xcodebuild -allowProvisioningUpdates`, installs and
  launches with `devicectl` (passing `--selftest`, `--page`, `--query`,
  `--fragment`), then polls `Documents/probe-result.json` from the app
  container. The phone must be unlocked.
- `probes.sh`: one unattended session of stack, C recursion, memory and
  background probes (switches to Settings for 30 s).

```sh
./run.sh --selftest ""                                  # pyodide-worker suite
./run.sh --no-build --page ui/index.html --selftest ""  # ui-toolkit suite
./probes.sh                                             # device probes
```

## Results

| Check | iPhone 14 Pro | Simulator |
|---|---|---|
| Interpreter boot (`loadPyodide` in a worker) | 1.06-1.17 s | 0.77-0.95 s |
| Blocking Python → Swift call (Atomics) | 0.30 ms | 0.11-0.22 ms |
| `import numpy` (load time, from the native cache) | 0.30-0.51 s | 0.16-0.18 s |
| matplotlib + 11 deps, render a PNG | 2.2-2.6 s | 1.8-2.2 s |
| micropip install from PyPI | 0.08-0.26 s | 0.07-0.69 s |
| fib(30) / sum of squares 10M / dict 2M | 0.11-0.27 / 1.0-1.5 / 0.44-0.67 s | 0.06-0.10 / 0.65-0.91 / 0.37-0.53 s |
| UI tap round trip / keystroke / 1,000-row reverse | 0.5 ms / 1.1 ms / 30 ms | 0.24 ms / 0.5 ms / 26 ms |
| Memory | WebContent killed by jetsam at about 1.9 GB (no `MemoryError`) | 1 GB OK |
| App in background for about 30 s | script paused (one 29.3 s gap in `time.monotonic`), then resumed and finished | n/a |

For reference, native CPython 3.14 on the Mac runs fib(30) in 0.037 s, so the
phone is roughly 3-7x slower than desktop native.

### Q12: wasm-GC trampoline on a device

The full suite with `gc=1&jspi=1` passes on the device:
- `run_sync` on JS promises and host calls, `run_sync(asyncio.sleep())`,
  `can_run_sync() == True`;
- numpy, matplotlib, micropip, benchmarks;
- 8 s of hot builtin calls through the trampoline (`trampoline_stress`: 363-487
  rounds, the same as the JS trampoline's 364).

WebKit bug 293113 does not reproduce on iOS 27, so D13 stands. The runtime
default is now `gc` + `jspi` on.

### Native stack: workers are small

Maximum recursion depth (`jspi/index.html?only=stack_depth`):

| | plain wasm | wasm with large frames | JS |
|---|---|---|---|
| Device worker | 544 | 404 | 3,139 |
| Device main thread | 1,208 | 1,023 | 7,167 |
| Simulator worker | 545 | 404 | 3,327 |
| Simulator main thread (macOS 8 MB stack) | 638,687 | 638,687 | 49,151 |

WebKit creates worker threads with the Darwin default of 512 KB
(`WTF/Threading.cpp`). CPython's C recursion guard measures Emscripten's
linear-memory stack, not the engine's native stack, so recursion through C
code overflows the native stack before `RecursionError` triggers. Pyodide then
dies with a fatal `RangeError`. Plain Python recursion is not affected
(32,000 frames work).

Recursion that goes through C code, where "crash" means the interpreter dies:

| | worker (device = simulator) | device main thread |
|---|---|---|
| `json.loads` of nested lists | OK at 500, crash at 1,000 | OK at 1,000, crash at 5,000 |
| `repr` of nested lists | OK at 100, crash at 250 | OK at 250, crash at 1,000 |
| `copy.deepcopy` | `RecursionError` at 500 (clean) | not measured |
| recursion through `map(f, ...)` | OK at 100, crash at 250 | OK at 250, crash at 1,000 |

On the device the main thread only buys 2-4x, so moving Python out of workers
is not worth it. Instead:
- the runtime now treats an error escaping the worker as a crash: the run ends
  with "Python crashed: ... (recursion too deep for the worker's native stack)"
  and the worker is replaced (verified: the next run works);
- the next step is to make CPython raise `RecursionError` before the native
  stack runs out (Q14).

## Not covered yet

- App Intents / Shortcuts (Q6 second half) and longer background periods.
- Warm-start numbers across app launches (WebKit's wasm code cache).
- iPhones older than the A16.
