# debugger

2026-10-13 - Pyodide 314.0.7 (Python 3.14.2). Node 25 (V8) for the protocol
probes; the overhead benchmark also ran inside the app in the iPhone 17
simulator (WebKit). Not yet run on a device.

**Question:** How do we add an interactive debugger (breakpoints, stepping,
variables, pause), and how does it stay out of the way?

## How to run

```sh
node node-run.mjs   # probes A-E below; the main thread plays the page
```

`bench.py` is standalone. To run it in the app, copy it into the simulator's
`Documents` and run it (`FRAGMENT="open=DebugBench.py&run" ./run.sh`). It
writes `debug-bench.json` next to itself (`results-iphone17-sim.json`).

## Results

**A. Capabilities.** `sys.monitoring` (PEP 669) works in Pyodide, and so does
`bdb.Bdb(backend="monitoring")`, which is new in 3.14.

**B. Overhead with one breakpoint set but never hit.** The workload is
recursive `fib(20)`, a 200k-iteration loop and a 50k sort. Times are the best
of three, in ms:

| | Node (V8) | iPhone 17 sim (WebKit) |
|---|---|---|
| no debugger | 13.5 | 19 |
| `sys.monitoring`, LINE events returning `DISABLE` | 14.0 | 21 |
| `bdb`, `monitoring` backend | 13.5 | 19 |
| `sys.settrace`, minimal tracer | 70 | 121 |
| `bdb`, `settrace` backend (classic pdb) | 140 | 232 |

The monitoring backend makes breakpoints effectively free, while settrace is
6-12x slower. The debugger can therefore be armed on every run that has
breakpoints, with no separate "Debug" run mode.

**C. Pause.** Writing `SIGUSR1` (10) into Pyodide's existing interrupt buffer
runs a Python signal handler, which receives the running frame and its locals.
This happens within a few ms during a busy loop, and also during `time.sleep`,
because our `host.sleep` waits on the same buffer (checked in Chrome in the
app). One catch: the signal wakes the sleep early (a 3 s sleep returned after
1.48 s), so the sleep wrapper must sleep again for the remaining time.

**D. Stop, inspect, step.** In `user_line` the debugger blocks in
`Atomics.wait` until the page sends a command. Evaluating in the frame
(`name` → `'Ada'`, `message.upper()`), `next`, `continue` and a second hit of
the same breakpoint all work. `bdb.run` starts in step mode, so the first stop
has to `set_continue()` silently.

**E. Pause into the debugger.** A signal handler that calls
`dbg.set_trace(frame)` stops inside the running function (`spin()`), and then
eval, `next` and `continue` work.

**F. What already works in the app today, with no new code** (checked in
Chrome against the dev server):
- `breakpoint()` gives a text pdb in the console through the inline `input()`;
  `p`, `w` and `c` work.
- Pdb's `w` shows Pyodide's own frames (`webloop`, `_pyodide/_base`); a real
  UI must hide them.
- After an uncaught exception, `sys.last_exc` is set and its traceback keeps
  the frames alive. The console REPL runs in the same worker, so
  `import pdb; pdb.pm()` already works.

## Options considered

1. **Text pdb in the console.** It works today (F), but it is unfriendly on a
   phone keyboard and uses settrace (B). Keep it as the fallback for people
   who `import pdb`.
2. **debugpy / DAP over a socket.** Not possible: pydevd needs threads and
   sockets, and Pyodide has neither.
3. **Our own bdb subclass on the `monitoring` backend, driving a visual UI.**
   The worker blocks through the existing sync channel, so Stop works while
   paused, because it already answers pending sync calls with "interrupted".
   The messages follow DAP's shapes (setBreakpoints, stopped, stackTrace,
   scopes, variables, evaluate, continue/next/stepIn/stepOut/pause), so a
   later agent tool can drive the same protocol. **Recommended.**
4. **Recording mode (Python Tutor style).** Record every line event with
   `sys.monitoring` and scrub back and forth. This is great for teaching, but
   the cost grows with run length. It is a possible later "step through" mode
   built on the same events.

## Implementation sketch (option 3)

- **`_terrarium/debugger.py`.** Subclass `bdb.Bdb(backend="monitoring")` and set
  `sys.breakpointhook` to it, so `breakpoint()` opens the visual debugger.
  - It is armed only when the run has breakpoints or `breakpoint()` is called.
  - It only stops in project files ("just my code"). Step-in skips the
    stdlib, site-packages and our runtime, and stack traces hide those frames.
  - At each stop it makes a sync call `debug.stopped` (file, line, frames) and
    loops on the replies: `variables(ref)`, `evaluate(expr, frame)`, then a
    resume command.
  - Values are `reprlib`-limited and expanded lazily by reference id, the way
    DAP's `variablesReference` works.
- **Breakpoints that change while the program runs.** The worker can't
  receive `postMessage` while Python runs synchronously. The page writes
  `SIGUSR2` into the interrupt buffer; the handler fetches the new list with
  a sync call and calls `sys.monitoring.restart_events()`.
- **Pause.** `SIGUSR1` → `set_trace(first user frame)`. The `time.sleep`
  wrapper re-sleeps the remaining time.
- **Post-mortem.** "Inspect" on a traceback opens the same UI on
  `sys.last_exc.__traceback__`. It needs no tracing at all.

## Outcome

Option 3 was built into the app (D23, `app/web/public/runtime/python/_terrarium_debug.py`).
Two things the spike did not show:
- CPython polls the interrupt buffer only periodically, and runs the handler at
  a later check. A sleep loop could therefore miss Pause and sleep on. The
  worker's sleep now runs pending non-Stop signals through
  `pyodide.checkInterrupt()` as soon as it wakes.
- A breakpoint update that arrives before the program starts was overwritten
  by the list sent with the run. `start()` now asks the page for the current
  list.

## Open risks

- Device numbers: the benchmark has only run in the simulator so far.
- Stepping across `await` when JSPI is suspended in a JS promise. Pause
  cannot interrupt a suspended coroutine; it takes effect when the coroutine
  resumes.
- UI apps: while paused, the app's UI can't respond, so it needs a "Paused in
  debugger" overlay.
- Deep recursion: the debugger's own frames use some of the 512 KB native
  stack (D16, Q14).
