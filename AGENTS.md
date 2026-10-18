# AGENTS.md

A Pythonista replacement for iOS: a native SwiftUI app, with Pyodide and
CodeMirror in web views (D31), native ui apps (D30) and a pi-durable coding
agent. Early research phase.

## Where things live

- `app/`: the real app (see `app/README.md`). Build and test with `app/run.sh`
  (`--selftest`, `--device`). Keep `./run.sh --selftest` passing.
  - `app/ios/Sources/Shell/`: the native IDE (SwiftUI). `app/ios/Sources/UIRenderer/`: ui apps.
  - `app/web/`: two pages, `engine.html` (Python, analysis, the self-test) and `editor.html` (CodeMirror).

- `uikit/`: the `ui` module (D26, Solid-style signals): `python/ui.py`, the
  web renderer for published apps (`web/renderer.js`, `web/ui.css`), examples
  and a playground. Edit it there, then run `uikit/scripts/install.sh` to copy
  `ui.py` into `app/web`. Test with `uikit/run.sh --selftest` (host pytest +
  headless Chrome). A change to the op protocol needs both renderers: the web
  one and `app/ios/Sources/UIRenderer/`.

- `GOALS.md`: the feature set, tagged [core]/[later]/[maybe]. Update it when scope changes.
- `DECISIONS.md`: decisions D<n> (append-only), proposals P<n>, open questions Q<n>.
  When a spike answers a question, add a decision or note that cites the spike,
  and remove the question.
- `spikes/<name>/`: throwaway experiments. Each one has a `README.md` with the
  question, how to run it, the results and the date. Spikes are never production code.

## Current work

App (`app/`): native SwiftUI IDE (D31) with files, editor, run, console, native UI apps (D26, D30, `uikit/`), turtle (D29), ruff + ty,
PEP 723 dependencies, visual debugger (D23), tabs and split view with
traceback links and go to definition (D24), outline / go to line / find in
folder / show info / settings / keyboard shortcuts, HTTP through the host (D25),
and the coding agent (D34: pi-durable in the engine page, sign-in with pi-ai's
flows, D33; conversations per project and IDE tools, D36), two bundled
Pythons (3.14 and a 3.15 preview) and the Python docs on the device, for the
user and the agent (D37), Home Screen shortcuts that run a program
(D38), editor themes (D39), iOS device modules with Pythonista's API (D40)
and file management with a Trash, moving, Quick Look, favorites and
templates (D41), documented with the Python docs (D42; sources in
`app/docs/`), and notebooks: `.ipynb` and `# %%` cells run in a kernel
with rich output (D44), and tracebacks as data, drawn as frames in the
console and notebooks (D45), and Markdown files as a preview or their
source, with links between files (D46), and processes: `multiprocessing`
and `subprocess`, each process a Pyodide worker (D47), and robustness:
blocking HTTP through the fetch relay (D48), warmed-up interpreters and
stack overflows shown as a RecursionError (D49), a memory budget for
Python's heaps and the console kept when iOS ends the engine (D50). All of it works on the iPhone 14 Pro (2026-10-17). Ready for an App Store submission (D51: privacy manifest, consent before the agent sends to a provider, store builds without the self-test's SPI, `make archive`/`make upload`; checklist and risks in `app/appstore/README.md`). Next: the first TestFlight upload, then the rest of D34's list (write
conflicts, per-turn undo, teaching mode, iPad panel), then the gaps in
`app/README.md` (Q16-Q18). `app/scripts/build-ty.sh` needs Rust + wasm-pack.
Bundled Python versions and docs archives are pinned in `app/runtimes.json`
(`app/scripts/build-docs.py --update-pins` after upstream rebuilds an archive).

Spike queue (update the status here). The pi-durable agent always comes last
(D8); never start agent work before the spikes ahead of it are done.

1. [x] `ios-host`: Swift host, WKWebView, `app://` scheme handler; probe inside it (Q1 answered: D9; Q2/Q3 narrowed)
2. [x] `pyodide-worker`: bundled Pyodide in a worker: console, `input()`, interrupt, restart, package cache (D10-D12; open: PyPI offline cache, Q11)
3. [x] `ui-toolkit`: declarative Python UI in the app and exported as a static site (D14, D15)
4. [x] `device-perf`: real-phone startup, memory, speed, bridge latency, backgrounding, wasm-GC trampoline check (D13 confirmed, D16; Q14 and Q15 answered by D49 and D50; open: App Intents Q6)
5. [x] `debugger`: breakpoints, stepping, pause and post-mortem on bdb's `monitoring` backend (D23, built into the app; open: Q19)
6. [x] `agent`: pi-durable in a web view on native SQLite, a project `ExecutionEnv`, streaming proxy, resume after a reload, pi-ai sign-in flows with a loopback listener and the Keychain (D32, D33). Built into the app (D34).

Done:
- [x] `jspi-repro`: JSPI "hang" root-caused to CPython's iOS JS-trampoline fallback (D13)
- [x] `webkit-probe`: wasm and threading features of iOS 27 Safari (simulator)
- [x] `host-fs`: Pyodide on the host's files (an Emscripten FS over sync XHR), costs, caches, SQLite crash safety (D35, built into the app)
- [x] `xhr-wait`: why a worker's synchronous XHR is sometimes a second late (Q25; worked around with a fetch relay, D48; WebKit report drafted, not filed)
- [x] `native-stack`: recursion through C code vs. the worker's native stack; CPython's stack protection can't help, a warm-up does (Q14, D49)
- [x] `processes`: `multiprocessing` (spawn) and `subprocess` (Python only), each process a Pyodide worker, on stock Pyodide (D47, built into the app; works on the iPhone 14 Pro). First step towards local servers and several programs at once.

## Conventions

- Environment: Xcode 27, iOS 27 simulator, macOS 26.
- Python tooling on the host goes through `uv`.
- Write dates as YYYY-MM-DD.
- Spikes with a web part have `run.sh --selftest [steps]`, which prints JSON from
  the simulator. Prefer the app over Safari for automated runs; driving Safari
  with `simctl openurl` reuses tabs and is unreliable.
- Never claim a result from the simulator or Safari applies to a real device or to WKWebView; say which one was tested.
- Device runs: `spikes/device-perf/run.sh` (paired iPhone 14 Pro, personal team `ZRL6J4P42H`). The phone must be unlocked; ask the user first.
