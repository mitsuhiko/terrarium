# Architecture and tradeoffs

How Terrarium is put together, and why. The full reasoning and evidence
for each choice is in [`DECISIONS.md`](../DECISIONS.md).

## How it fits together

```
┌──────────────────────────── SwiftUI app ─────────────────────────────┐
│ files · tabs · console · debugger · find/go to · ui apps (native)    │
│ app:// scheme handler (COOP/COEP) · package + PyPI cache · HTTP      │
│  ┌──── engine web view (no UI) ────┐  ┌── editor web view(s) ──────┐ │
│  │ session, debugger protocol      │  │ CodeMirror, one per pane   │ │
│  │ coding agent (pi-durable)       │  │                            │ │
│  │ ├── Python workers: Pyodide     │  │ lint/completions go to the │ │
│  │ └── analysis worker: ruff + ty  │◄─┤ engine through the host    │ │
│  └─────────────────────────────────┘  └────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
```

- `app/`: the app. See [`app/README.md`](../app/README.md) for features,
  layout, shortcuts and known gaps.
- `uikit/`: the `ui` module, renderer, examples and playground. See
  [`uikit/README.md`](../uikit/README.md).
- `spikes/`: frozen experiments that serve as evidence for the decisions.
- [`GOALS.md`](../GOALS.md): the intended feature set.
- [`DECISIONS.md`](../DECISIONS.md): every design decision with its
  reasoning and evidence, plus open questions.

## Tradeoffs, and why

The short version: **Python runs as WebAssembly inside WebKit because that is
the only place on iOS where code can be loaded at runtime, and everything else
follows from that.**

### Pyodide in WebKit instead of native CPython (D2, D3)

iOS doesn't let apps load native code at runtime. An embedded native CPython
can only use C extensions that were compiled and signed into the app bundle,
so `pip install numpy` on the device is impossible. Pyodide loads compiled
extensions as wasm modules at runtime, and WebKit is the only process on iOS
that is allowed to JIT. The WebContent process also isolates crashes and
memory from the app, and the same runtime runs in any browser, which makes
publishing scripts as web apps possible.

A hybrid (native interpreter, wasm extensions) was rejected: the CPython C
API assumes the interpreter and extensions share one address space, and
bridging that would need a proxy layer with a round trip per C API call.

What it costs:
- Speed: roughly 3-7x slower than native CPython on a Mac (iPhone 14 Pro),
  and about 1.1 s to boot an interpreter.
- No threads and no raw sockets (HTTP goes through the host instead).
- Memory: iOS kills the WebContent process at about 1.9 GB, without a
  `MemoryError`.
- Background: a running script is paused while the app is in the background.
- Python versions follow Pyodide releases, not CPython's.

### A native app with web views for Python and the editor (D30, D31)

The IDE started as a React app in a thin Swift host (D4, D18), which ran the
same in a desktop browser. Native polish (keyboard behavior, selection menus,
hardware shortcuts, lists, sheets) had to be fought for through WebKit, so
the IDE is now SwiftUI. Pyodide still needs WebKit: an engine web view
without UI runs the Python workers and ruff/ty, and the editor stays
CodeMirror in one web view per pane. The host talks to both through a bridge
with replies. `ui` apps are native SwiftUI views driven by the same op
stream the web renderer uses for published apps. The cost: no IDE in the
browser any more, three WebContent processes, and an IPC hop for every
editor and engine call.

### `app://` with cross-origin isolation and a `SharedArrayBuffer` polyfill (D9)

Interrupting Python and making blocking calls from Python need shared memory,
which needs a cross-origin-isolated page. A custom `app://` scheme handler
serves the web app with COOP/COEP headers. WKWebView still hides the global
`SharedArrayBuffer` constructor, but the one obtained from shared wasm memory
works, so the page and every worker install it as a polyfill.

### Workers, one interpreter per run (D6, D11, D16)

Each run gets a fresh interpreter in a Web Worker from a warm pool. Stop
raises `KeyboardInterrupt` and kills the worker if that doesn't work within
1.5 s, so a runaway script can't wedge the app.

The cost: WebKit gives worker threads a 512 KB native stack. Recursion
through C code (deeply nested `json.loads`, `repr`) can overflow it before
CPython's `RecursionError` kicks in, which kills the interpreter. The main
thread only gives 2-4x more on a device, which wasn't worth losing workers
for, so such a crash ends the run as "Python crashed" and the next run gets a
fresh worker.

### JSPI enabled, Atomics for our own blocking calls (D10, D13)

Pyodide's JSPI-based `run_sync` looked like it hung in WebKit. The cause was
CPython's Emscripten build sniffing the iOS user agent and falling back to a
JavaScript call trampoline (a workaround for a WebKit bug that has since been
fixed), which makes stack switching impossible. The worker hides the iOS user
agent before loading Pyodide, which brings back the wasm-GC trampoline and
working JSPI (verified on an iPhone 14 Pro). `input()`, `time.sleep` and
synchronous host calls still use a `SharedArrayBuffer` + `Atomics.wait`
channel, because it can be interrupted by Stop and doesn't depend on JSPI.
The details are in [`spikes/jspi-repro/`](../spikes/jspi-repro/README.md).

### Programs use the project's files in place (D35)

Pyodide's files normally live in memory. Here the program's folder is mounted
as a file system whose operations go to the host one by one (a synchronous
request each, served natively), so `open()`, `sqlite3` and sibling imports
work on the real files: a database is written page by page with its journal,
and a killed program is just a crash SQLite recovers from. Round trips cost
about 0.1-0.2 ms, so the worker queues writes (in order, sent before any
other call and whenever the program idles or blocks) and caches stats and
file blocks; SQLite then runs within a few milliseconds of an in-memory copy.
Folders from iCloud Drive or other apps are not used in place: a run gets a
local copy (coordinated reads), and its changes go back with file
coordination as it goes. The measurements are in
[`spikes/host-fs/`](../spikes/host-fs/README.md).

### micropip and PEP 723, not uv inside the app (D12, D22)

uv cannot run in the browser sandbox without a large port, and its Pyodide
targets stop at 3.13. The app uses micropip against a PyPI proxy in the host
that caches downloads (offline after the first install), but keeps the
formats uv understands (PEP 723 script blocks, `pyproject.toml`), so the same
scripts run with `uv run` on a desktop. There are no lock files yet.

### ruff and ty as WebAssembly (D21)

Real lint, format, type checking and completions on the device, with no
server, at the price of about 30 MB of wasm. ty only knows the standard
library so far; imports of third-party packages are not type-checked.

### A debugger on `sys.monitoring` (D23)

Python 3.14's `bdb` monitoring backend makes breakpoints free until they are
hit (settrace-based pdb is 6-12x slower). That's why every run is debuggable
and there is no separate debug mode. The UI only appears once a program
stops.

### A Solid-style `ui` module (D14, D26)

The first version re-ran a `view()` function and diffed the whole tree on
every change, like React. Signals turned out to be both faster (one change
sends one op, instead of re-rendering 1,000 rows in about 25 ms) and easier
to explain ("the lambda is what updates"), and text fields keep focus and
caret without special care. The same fine-grained ops map directly onto one
observable SwiftUI node per element in the app (D30).

### HTTP through the host (D25)

Requests from the app's origin would hit CORS, so cross-origin `fetch` and
`XMLHttpRequest` calls from the worker are rerouted to the scheme handler,
which performs them natively. Python libraries need no app-specific code. Responses
stream (the agent's model output needs that); there are no WebSockets.
