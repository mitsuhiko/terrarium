# Terrarium

**Terrarium – Python IDE with a coding agent.**

A Pythonista-style Python IDE for iPhone and iPad: a native SwiftUI app that
runs Python on the device ([Pyodide](https://pyodide.org/), CPython 3.14 in
WebAssembly) and has a coding agent built in.

> A demo and research project, written largely with coding agents. It is
> not on the App Store yet and not affiliated with Pythonista.

<p>
  <img src="docs/screenshots/iphone-agent.png" width="24%" alt="The coding agent wrote and ran a program">
  <img src="docs/screenshots/iphone-plot.png" width="24%" alt="Editor and console with an inline matplotlib plot">
  <img src="docs/screenshots/iphone-debug.png" width="24%" alt="The debugger paused at a breakpoint">
  <img src="docs/screenshots/iphone-todo.png" width="24%" alt="A Reminders-style todo app built with the ui module">
</p>
<p>
  <img src="docs/screenshots/ipad-split.png" width="49%" alt="iPad: split view with a turtle drawing in the console">
  <img src="docs/screenshots/ipad-debug.png" width="49%" alt="iPad: split view and the debugger">
</p>

<sub>iPhone 17 and iPad Pro 13" simulators, iOS 27.</sub>

## Features

- **Python on the device**: CPython 3.14 through Pyodide. A streaming console
  with `input()` and a `>>>` prompt, inline matplotlib plots, tracebacks that
  link to the line, and a Stop that always works.
- **Packages**: numpy, pandas, matplotlib and the rest of Pyodide's packages,
  plus pure-Python packages from PyPI. They are declared with PEP 723
  (`# /// script`, as with `uv run`) and cached for offline use.
- **Editor**: CodeMirror with a key bar for touch typing, tabs, split view on
  iPad, outline, go to line, find in folder, and hardware keyboard shortcuts.
- **Code intelligence**: [ruff](https://github.com/astral-sh/ruff) (lint and
  format) and [ty](https://github.com/astral-sh/ty) (type checking,
  completions, go to definition) run locally as WebAssembly.
- **Debugger**: breakpoints, stepping, variables, a `>>>` prompt in the paused
  frame, and inspecting the frames after an error.
- **Native apps from Python**: the `ui` module builds SwiftUI screens, lists,
  sheets, inputs and canvases with Solid-style signals. Turtle graphics draw
  right in the console.
- **Files**: the app's Documents folder (also in the Files app) and linked
  folders from iCloud Drive or other apps. Programs read and write them, with
  `sqlite3` and all.
- **HTTP**: `requests`, `httpx` and `urllib` without CORS limits.
- **Coding agent**: built on
  [pi-durable](https://github.com/earendil-works/pi/tree/main/packages/durable).
  - It works on the folder you are in and knows which file you have open.
  - It reads, writes and edits files, runs Python, and checks and formats
    code with ruff and ty.
  - Conversations survive crashes and relaunches.
  - Sign in with Radius, Claude Pro/Max, ChatGPT, GitHub Copilot and others,
    or use an API key. Credentials stay in the Keychain.

## Building

```sh
make iphone-sim       # build and launch in an iPhone simulator (IPHONE="iPhone 17" picks one)
make ipad-sim         # the same in an iPad simulator (IPAD="iPad mini (A17 Pro)")
make device           # on a paired, unlocked iPhone
make selftest         # end-to-end checks in the iPhone simulator
```

The targets run `app/run.sh`, which also takes these as flags
(`--device`, `--selftest`, `--reset`).

You need Xcode 27, Node, [uv](https://docs.astral.sh/uv/), and Rust with
`wasm-pack` (ty has no published WebAssembly build). More is in
[`app/README.md`](app/README.md). How it is put together and why is in
[`docs/architecture.md`](docs/architecture.md), and every decision is in
[`DECISIONS.md`](DECISIONS.md).

## License

[Apache License 2.0](LICENSE).

## Credits

- **[Pythonista](https://omz-software.com/pythonista/)** by Ole Zorn is the
  inspiration. It showed years ago what Python on iOS should feel like.
- **Built on:**
  - [Pyodide](https://pyodide.org/), [CPython](https://www.python.org/) and
    [Emscripten](https://emscripten.org/);
  - [CodeMirror](https://codemirror.net/);
  - [ruff, ty and uv](https://astral.sh/) by Astral;
  - [SolidJS](https://www.solidjs.com/), whose model the `ui` module copies;
  - [pyodide-http](https://github.com/koenvo/pyodide-http);
  - matplotlib, numpy, pandas and the rest of the scientific Python stack.
- **Built with:** [pi](https://github.com/earendil-works/pi), the agent
  harness by Earendil. The app's own agent uses its pi-durable and pi-ai
  packages.
