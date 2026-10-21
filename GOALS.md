# Goals

A modern replacement for Pythonista. People use it to **learn Python, build things
with it, and publish what they build**. A coding agent helps them along the way.
iOS comes first, as a native SwiftUI app (D31). What people build with it also
publishes to the web.

Tags: **[core]** first release · **[later]** planned · **[maybe]** depends on research or demand

## Python runtime

- [core] Current CPython (Pyodide) that keeps up with new Python releases
- [core] Runs offline; the runtime is bundled in the app
- [core] Each run gets a clean interpreter; Stop raises `KeyboardInterrupt`, and a hard kill always works
- [core] A crash or out-of-memory in a script never takes down the app
- [core] `input()`, `time.sleep()` and blocking-style device calls work, with no `async` needed
- [core] Warm interpreter pool for fast starts
- [later] Several scripts running at once
- [core] `multiprocessing` (spawn) and `subprocess` for Python programs, each process its own interpreter (D47)
- [later] Threads, if a pthreads Pyodide build becomes viable
- [later] Socket shim (TCP/TLS through the native host) so ssh, smtp/imap and database clients work
- [core] Choose the Python version per project (`requires-python`, `.python-version`): 3.14 and a 3.15 preview are bundled (D37)

## Packages

- [core] Install pure-Python packages from PyPI at runtime (micropip)
- [core] Install compiled packages from the Pyodide repository at runtime (numpy, pandas, scipy, matplotlib, Pillow, ...)
- [core] Downloaded packages are cached and usable offline
- [core] Per-project dependencies stored in `pyproject.toml`, with a lockfile
- [later] Emscripten wheels from PyPI, if that is supported by then
- [later] Package browser with search and details

## Editor

- [core] CodeMirror 6 editor tuned for touch and for hardware keyboards (in a web view inside the native app)
- [maybe] A native editor (TextKit 2 or Runestone with tree-sitter) instead of CodeMirror
- [core] Python syntax highlighting, indentation, bracket matching, comment toggling
- [core] Color themes for the editor, each light and dark; the app's appearance can be fixed to light or dark (D39)
- [core] Bar of extra keys above the on-screen keyboard (tab, brackets, quotes, `:`, `_`, `#`, cursor keys)
- [core] Swipe on the keyboard bar to move the cursor
- [core] Find/replace, go to line, outline of functions and classes
- [core] Completions and inline errors
- [core] Formatting (ruff, compiled to wasm)
- [later] Type checking (ty compiled to wasm, or similar)
- [later] Split view and multiple windows on iPad
- [later] Vim keybindings
- [core] Markdown files: a preview with links between files and the source to edit, side by side on iPad (D46)
- [maybe] Editing HTML, CSS, JSON and TOML with the same editor

## Console and REPL

- [core] Interactive REPL with history and completion
- [core] Script output streamed as it happens, with stdout and stderr shown apart
- [core] Clickable tracebacks that jump to the line, drawn as expandable frames with source and the failing span (D45)
- [core] Rich output: images, plots and HTML shown inline
- [later] Variable inspector
- [later] Step-through debugger
- [core] Notebooks: `.ipynb` files and `# %%` cells in `.py` files, run cell by cell in a kernel with rich output (D44)
- [later] Interactive widgets (ipywidgets) in notebooks
- [later] Debugger and variable inspector for notebook cells

## Projects and files

- [core] Projects are folders: files, assets, `pyproject.toml`
- [core] File browser: create, rename, move (drag and drop, Move…), delete to a Trash, Quick Look and share, favorites (D41)
- [core] Shown as a folder in the iOS Files app
- [core] Open external folders the user grants access to (e.g. Working Copy, iCloud Drive)
- [core] Python code sees project files through ordinary `open()` and `pathlib`
- [later] iCloud sync between devices
- [later] Git: clone, commit, push, pull
- [core] File templates for New File, built in and your own (Documents/Templates) (D41)
- [later] Project templates (several files, assets)
- [later] Selecting several files to move or delete

## Learning

- [core] Built-in examples you can run and edit
- [core] `turtle` drawn on a canvas
- [core] Friendly explanations of errors, from the agent or built in
- [later] Interactive lessons and exercises with checks
- [core] Python documentation available offline, searchable, opened by `help()` and Show Info; the agent searches and reads it too (D37)
- [core] The app's own modules (ui, turtle, the device modules) documented in the same viewer and index (D42)
- [maybe] Classroom features (sharing assignments, collecting submissions)

## Building apps: UI toolkit

- [core] Pythonic declarative UI API: views, layouts, inputs, lists, navigation, sheets/alerts
- [core] Event-driven callbacks; updates rendered as diffs; Python runs in a worker
- [core] Native SwiftUI views inside our app (D30); iOS-like HTML in published web apps; themes; dark mode
- [core] Apps run full screen in our app and as standalone web pages
- [core] Canvas drawing (the browser's canvas API, drawn natively in the app)
- [later] More native components: search bar, pull to refresh, context menus, maps, video
- [later] 2D graphics and games API (scene/sprite-style), with touch and motion input
- [later] pygame-ce support (pygbag)
- [maybe] Streamlit-compatible mode (stlite)
- [maybe] Partial compatibility layer for Pythonista's `ui` and `scene` modules

## Data and plotting

- [core] matplotlib renders inline and inside apps
- [core] SQLite access to project files (`sqlite3`), saved while the program runs
- [core] numpy and pandas ready to use
- [later] Interactive charts (Plotly, Bokeh, or our own)

## Device features (Python API)

One Python API with two implementations: the native bridge inside our app, and
browser APIs (or graceful degradation) in published web apps.

Inside the app these use Pythonista's module names and API (D40): `clipboard`,
`console`, `dialogs`, `keychain`, `notification`, `photos`, `location`, `motion`,
`sound`, `speech`, `contacts`, `reminders`, plus `haptics`; `webbrowser` opens links.

- [core] Clipboard, share sheet, haptics, dialogs (alert, text input, pickers) (D40)
- [core] Opening URLs; HTTP from Python via `requests`/`httpx`/`urllib`, with no CORS problems inside the app
- [core] Secure key/value storage (Keychain inside the app) (D40)
- [core] Location, motion sensors, camera/photo library, microphone recording, sound effects and playback (D40)
- [core] Speech (text-to-speech, recognition), local notifications (D40)
- [core] Contacts and reminders (D40)
- [later] Bluetooth LE (Pythonista's `cb`), calendar events, HealthKit (only inside the app; review needed)
- [later] Browser implementations of the device modules for published apps
- [maybe] Apple's on-device Foundation Models

## iOS integration

- [core] Native SwiftUI app; Python and analysis in a web view without UI (`app://` file serving, native bridge)
- [core] Home Screen icons for programs: a "Run Python Program" Shortcuts action and `terrarium://run` links open the app and run one (D38)
- [later] Shortcuts / App Intents: run a script with inputs and return its outputs, without opening the app
- [later] Share extension: send text, URLs or files to a script
- [later] Home screen widgets fed by scripts
- [later] Universal links to open or run scripts (the `terrarium://` scheme is there, D38)
- [maybe] Running scripts in the background (BGTaskScheduler)

## Coding agent (pi-durable)

Built last (D8), on top of everything above.

- [core] Chat with an agent about the current project; it can read, edit and create files
- [core] Agent tools: run Python, install packages, run tests, inspect output, look at screenshots of the running app
- [core] Durable sessions: picked up again after the app is killed or sent to the background
- [core] Several conversations per project; forks; history search
- [core] The learner stays in control: diffs to review, approvals, undo
- [core] Teaching mode: explains concepts and nudges rather than writing everything
- [later] Agent runs in the cloud and continues while the phone sleeps; tool calls that need the device wait for it
- [later] Bring your own API key or provider sign-in, as an alternative to the hosted gateway
- [maybe] On-device model for small tasks

## Publishing and sharing

- [core] Publish a project as a static web app at a URL (code, pinned runtime, packages)
- [core] Installable from the published URL as a home-screen app (PWA)
- [core] Share a project as a file or link; others can open it and remix it
- [core] Published apps only use web capabilities; native extras degrade gracefully
- [later] Public gallery inside the app (moderation, reporting, App Store guideline 4.7)
- [later] Custom domains, versioning, unpublish
- [maybe] Export a project as an Xcode project, or a cloud build for App Store submission

## Platforms

- [core] iPhone and iPad (iOS 27+), and the foldable iPhone Duo (iOS 27.1, D58)
- [core] The wide workspace's other half: console, agent, app or docs (D59)
- [later] macOS (SwiftUI)
- [maybe] Android (would need its own native UI)
- Dropped: the IDE in desktop browsers (D31). Published apps still run in any browser.

## Accounts, models, billing

- [core] Works without an account for local coding
- [core] Account needed for publishing and for the hosted model gateway
- [later] Paid tiers and in-app purchases for agent usage
- [later] Collaboration and sharing between accounts

## Privacy and safety

- [core] Code and files stay on the device unless published or sent to the agent
- [core] Clear indication of what the agent sends to model providers
- [core] Published apps run in the browser sandbox; each published app has its own origin
- [core] Device features require explicit user permission

## Non-goals

- Native (non-wasm) Python or C extensions downloaded at runtime
- Compiling C extensions on the device
- Full compatibility with Pythonista scripts or `objc_util`
- A general-purpose terminal or shell
