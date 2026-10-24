# Decisions

Append-only. Never rewrite a decision: add a new one that supersedes it and mark
the old one `Superseded by D<n>`.

## D1: Product scope: learn, build, publish, with an agent

2026-10-13 · Accepted

The app exists so people can learn Python, build apps with it, and publish them.
A coding agent based on pi-durable ships with it. Every other decision follows
from these three goals.

## D2: Python runs on Pyodide (CPython compiled to wasm) inside WebKit

2026-10-13 · Accepted

Do not embed native CPython (`Python.xcframework`).

Why:
- iOS forbids loading native code at runtime. Native CPython can only use
  compiled packages that were signed into the app bundle at build time.
- Pyodide loads compiled extensions (wasm side modules) at runtime, so
  numpy, pandas and similar packages can be installed on demand.
- WebKit is the only place on iOS where JIT is allowed, and its WebContent
  process gives us crash and memory isolation for free.
- The same runtime runs in any browser, which makes publishing possible (D5).

Costs we accept: no threads (pthreads build pending), no raw sockets (needs a
shim), a filesystem bridge, startup and speed costs of wasm, WebKit suspending
work in the background, and Python versions lagging behind CPython releases.

Evidence: `spikes/webkit-probe/` (iOS 27 Safari, simulator).

## D3: Rejected: native CPython with wasm extension modules

2026-10-13 · Rejected

Idea: run the interpreter natively and run extension modules as wasm inside
WebKit, with calls passed between the two.

Rejected because the CPython C API needs the extension and the interpreter in
one address space: extensions read object fields and buffers directly through
raw pointers and macros. Separating them needs a cpyext-style proxy layer (as in
PyPy) plus a process round trip for every C API call, which is orders of
magnitude too slow. Running a wasm interpreter inside the app process instead
is too slow without JIT.

## D4: Web stack for the whole app; Swift is only a thin host

2026-10-13 · Superseded by D31

The IDE, the agent and the runtime are a TypeScript web app inside a WKWebView.
The Swift host only provides:
- `app://` file serving (with the COOP/COEP isolation headers)
- a package cache
- a network proxy (no CORS problems)
- the native bridge: Keychain, files, SQLite, share sheet, App Intents, OAuth

Why: one codebase for iOS and the browser, reuse of pi-durable/pi-mobile
(TypeScript, React), and published apps that match what runs in the IDE.

## D5: Publishing means static web apps

2026-10-13 · Accepted

A published project is static files: the user's code, a pinned Pyodide version
and its packages. It is hosted at a URL and installable as a PWA. Published
apps use only web capabilities. The native bridge is a bonus for the user's own
code inside our app; this keeps the App Store risk under guideline 4.7 low.

Consequence: device APIs exposed to Python have two implementations, the
native bridge and browser APIs (or graceful degradation).

## D6: Python runs in Web Workers, one interpreter per run

2026-10-13 · Accepted

Each run gets its own worker (from a warm pool). Reset means `worker.terminate()`.
Interrupts use Pyodide's interrupt buffer (a SharedArrayBuffer). Blocking-style
calls use JSPI, or Atomics on a SharedArrayBuffer as the fallback.

## D7: The agent is pi-durable running in the web app

2026-10-13 · Accepted

- `ExecutionEnv.FileSystem` is implemented over the project filesystem.
- `Shell` is replaced by `python` and `pip` tools that run in Pyodide workers.
- Storage goes through the `SqliteDatabase` adapter: native SQLite through the
  bridge on iOS, SQLite compiled to wasm on OPFS in the browser.
- Provider HTTP goes through the native host on iOS.

Moving the agent loop to the cloud (Durable Objects) stays open (see Q4).

## D8: The pi-durable agent is built last

2026-10-13 · Accepted

The coding agent is the last phase in every plan. It is built on top of the
runtime, project files, packages, UI toolkit and publishing, and only after
those are validated on a device. Its tools (`python`, `pip`, the filesystem)
wrap features that must already work for people writing code by hand.

## D9: Serve the web app from `app://` and polyfill `SharedArrayBuffer`

2026-10-13 - Accepted

A `WKURLSchemeHandler` serves the app's web files from `app://app/` with the
COOP/COEP/CORP isolation headers. On the simulator this gives a secure,
cross-origin-isolated context with JSPI and shared wasm memory. WKWebView hides
the global `SharedArrayBuffer` constructor, but the one from shared wasm memory
works, so the page and every worker install it as a polyfill before any
Pyodide code runs. Evidence: `spikes/ios-host/`.

## D10: Blocking Python uses Atomics, not JSPI

2026-10-13 - Superseded by D13

WebKit exposes JSPI, but Pyodide's `run_sync` (and therefore its JSPI-based
`time.sleep`) hangs in it. Workers hide `WebAssembly.Suspending` and
`WebAssembly.promising` before `loadPyodide`. Everything that has to look
blocking to Python goes through a SharedArrayBuffer channel with
`Atomics.wait`: `input()`, synchronous host/device calls (`host.call_sync`,
about 0.14 ms per round trip on the simulator) and `time.sleep` (which waits on
the interrupt buffer, so Stop wakes it). Async code can still use `await`.
Revisit when WebKit's JSPI works with Pyodide. Evidence:
`spikes/pyodide-worker/`.

## D11: Stop escalates from KeyboardInterrupt to killing the worker

2026-10-13 - Accepted

Stop sets Pyodide's interrupt buffer, re-asserts it every 50 ms, and wakes any
blocked stdin, sleep or host call. If the run hasn't ended after 1.5 s, the
worker is terminated and the next run takes a fresh one from the pool.

## D12: Packages go through a native, on-disk cache

2026-10-13 - Accepted

Pyodide's `packageBaseUrl` points at `app://app/pkgs/`. The Swift scheme
handler serves wheels from Application Support and downloads misses from the
CDN of the pinned Pyodide version. PyPI installs (micropip) should be routed
through the same mechanism (not done yet).

## D13: Use the wasm-GC call trampoline and enable JSPI; keep Atomics for our own blocking calls

2026-10-13 - Accepted (device check passed on iPhone 14 Pro / iOS 27, `spikes/device-perf/`)

The JSPI "hang" was not a WebKit bug. CPython's Emscripten build sniffs the
iOS user agent and falls back to a JavaScript call trampoline (gh-130418, for
WebKit bug 293113, which was fixed in 2025). That puts a JS frame on every C
function-pointer call, so suspension is impossible. Pyodide then loses the
resulting `SuspendError` and hangs.

The Python worker hides the iOS user agent before `loadPyodide`, which selects
the wasm-GC trampoline. JSPI then works in WKWebView: `run_sync`,
`run_sync(asyncio.sleep())`, `can_run_sync() == True`. So:
- the worker keeps JSPI enabled (no more deleting `WebAssembly.Suspending`);
- stdin, synchronous host calls and `time.sleep` stay on the Atomics channel
  (D10's mechanism), because it is interruptible and doesn't depend on JSPI;
- if the device check (Q12) fails, fall back to D10 (JS trampoline, JSPI hidden).

Evidence: `spikes/jspi-repro/`.

## D14: User UI is a declarative Python tree rendered by a JS renderer

2026-10-13 - Superseded by D26 (was P2)

Python apps describe their UI with `ui.state()` plus a `view()` function that
returns components. Each state change re-runs `view()`; the whole tree goes to
the page as JSON, and a keyed JS renderer patches the DOM with iOS styling.
Callback ids are positional so they stay stable across renders. The same
renderer and runtime power the IDE playground and exported apps. Evidence:
`spikes/ui-toolkit/` (about 0.25 ms per tap round trip; 1,000 rows re-rendered
in about 25 ms).

## D15: Published apps are plain static sites with Pyodide from a CDN

2026-10-13 - Accepted (refines D5)

An export contains the app code, `ui.py`, the renderer, the worker runtime, a
manifest and an icon (37 KiB). Pyodide comes from jsDelivr at the pinned
version. No special headers are required: without cross-origin isolation the
app runs without SharedArrayBuffer (no `input()`, no Stop), which UI apps don't
need. Offline support and self-hosted Pyodide come later.

## D16: Python stays in Web Workers; an escaped error counts as a crash

2026-10-13 - Accepted

On devices, WebKit worker threads have a 512 KB native stack (about 544 wasm
frames). The main thread has only about 2x more on iOS (simulators overstate
this, since they use macOS's 8 MB main-thread stack). Recursion through C code
(e.g. `json.loads` of deeply nested data, `repr`, recursion via `map`)
overflows the native stack after 100-1,000 levels and Pyodide dies with a
fatal `RangeError`, because CPython's guard only measures Emscripten's
linear-memory stack. Moving Python to a main thread would cost JSPI-only
blocking and a more complex Stop for 2-4x more depth, so workers stay (D6).
Any error escaping the worker ends the run as "Python crashed" and the worker
is replaced. Making CPython raise `RecursionError` in time is Q14. Evidence:
`spikes/device-perf/`.

## D17: The editor is CodeMirror 6

2026-10-13 - Accepted (was P1)

CodeMirror 6 with lang-python, soft wrapping with a hanging indent, our own
key bar above the keyboard, and one cached EditorState per open file (undo
history survives file switches). Works in WKWebView on the simulator, and
typing works on the iPhone 14 Pro (2026-10-17).

## D18: The web app is React + Vite + TypeScript

2026-10-13 - Superseded by D31 (was P3)

Same stack as pi-mobile. The Python worker, `_terrarium.py` and `ui.py` are served
as static files (`public/runtime/`), not bundled. `npm run dev` runs the app in
a desktop browser with a localStorage mock of the host bridge.

## D19: The Xcode project is hand-written, no generator

2026-10-13 - Accepted (replaces P4)

A minimal `project.pbxproj` (objectVersion 77, synchronized source folder,
generated Info.plist, automatic signing) is small enough to maintain by hand.
`run.sh` drives `xcodebuild`, `simctl` and `devicectl`.

## D20: Product code lives in `app/`; projects live in Documents

2026-10-13 - Accepted

`app/` holds the real app; spikes stay frozen as evidence. User projects are
plain files in the app's Documents folder (shown in the Files app). Running a
file copies its folder into the interpreter as the working directory and
writes new or changed files back afterwards.

## D21: ruff and ty run as WebAssembly in an analysis worker

2026-10-13 - Accepted

ruff comes from npm (`@astral-sh/ruff-wasm-web`, 11 MB wasm). ty has no npm
wasm package, so `app/scripts/build-ty.sh` builds `crates/ty_wasm` from a
pinned astral-sh/ruff commit (19.6 MB wasm including typeshed), the same way the
ty playground does. Both run in one module worker. ruff runs its CLI default
rules plus bugbear, plus formatting. ty provides type checking and completions
(hover, go-to-definition and inlay hints are available for later). Undefined
names come only from ty (ruff F821 is dropped), and `unresolved-import` is
suppressed for modules Pyodide can install itself or that are already declared.

## D22: Dependencies are declared with PEP 723 and installed with micropip

2026-10-13 - Accepted

Scripts declare dependencies in a `# /// script` block (PEP 723, as `uv run`
does); otherwise `pyproject.toml` in the folder is used. Before each run the
worker installs them with micropip (patched to accept `app://` URLs) against
the host's PyPI proxy: Simple JSON API cached for 10 minutes with an offline
fallback, files cached forever. Pyodide's own packages still come from
`/pkgs/`. `requires-python` is enforced.

uv is not used inside the app: it cannot run in the browser sandbox without a
large port (tokio, rayon, real file system), and its Pyodide targets stop at
3.13 (`wasm32-pyodide2025`) while we run 3.14 (`pyemscripten_2026_0`). We keep
the formats uv understands (PEP 723 now, possibly `pylock.toml` later), so the
same scripts run with `uv run` on a desktop. Resolution or locking with uv
(natively in the host or as a service) stays open (Q16).

## D23: A visual debugger on bdb's `monitoring` backend, shown only when a program stops

2026-10-13 - Accepted (was P1; `spikes/debugger/`)

`_terrarium_debug.py` subclasses `bdb.Bdb(backend="monitoring")`, new in 3.14.
With breakpoints set but not hit, programs run as fast as without the
debugger, while settrace and pdb are 6-12x slower. That is why every run is
debuggable and there is no "Debug" mode. The other options considered were
text pdb in the console, which stays as a fallback, and debugpy, which needs
threads and sockets.

How it works:
- **Stopping:** at a stop the worker makes a blocking `debug` call through the
  Atomics channel (D10). It answers requests (scopes, variables, evaluate,
  setBreakpoints) until it gets a resume command. The messages follow DAP's
  shapes.
- **Stop while paused:** it uses the interrupt path of D11, because Stop
  already answers pending sync calls.
- **Signals through the interrupt buffer:**
  - `SIGUSR1` pauses at the next line of user code.
  - `SIGUSR2` makes the program fetch breakpoints that changed while it runs.
  - The worker's `time.sleep` wakes on any signal and runs its handler
    immediately via `checkInterrupt` (except for Stop). Pause ends the sleep;
    other signals sleep on.
- **Only project files stop.** The stdlib, site-packages and our runtime are
  skipped and hidden from the stack.
- **`breakpoint()`** uses the same debugger; `import pdb` still gives text pdb.
- **Inspect** after an error runs `post_mortem()` on `sys.last_exc` in the
  finished run's interpreter.

UI, aimed at staying out of the way:
- **Nothing new until the program stops.** Run stays the only button.
- **Breakpoints:**
  - Long-press a line number to add one; a plain tap does nothing, to avoid
    accidents while scrolling.
  - Long-pressing an existing breakpoint offers Disable and Remove.
  - On a blank or comment line, the breakpoint moves to the next line of code.
  - Breakpoints live in app state (not the source). They follow edits,
    renames and deletes.
  - They look like Xcode's blue tags behind the line number.
- **While paused, the editor is read-only.**
  - A green band marks the current line; a red band marks the failing line
    when inspecting an error.
  - Tapping a name or `a.b` chain shows its value in a popover with
    expandable children.
- **No inline values.**
- **While paused, controls and console:**
  - Run becomes Continue.
  - Step over, in and out and Stop sit in the console sheet's header on
    iPhone, so they work with the sheet collapsed, and in the nav bar on
    iPad.
  - The console gets a paused block at its end: reason and location, stack
    chips with only user frames (tap one to switch frame), and variables.
  - `>>>` runs in the selected frame, and assignments stick.
- **Pause** is a button in the console header while a program runs.
- **Inspect:** a run that ended with an error offers Inspect in its header;
  Done ends the inspection.
- **UI apps:** a stop inside a callback hides the app view until the program
  continues.

## D24: Panes with tabs, one way to open a place in a file

2026-10-13 - Accepted

- **Panes:** the editor area is one pane (iPhone) or two (iPad split view).
  Each pane has its own tabs and its own CodeMirror view. Edits to a file
  that is open in both panes are mirrored as remote transactions, which are
  not saved twice or added to the other pane's undo history.
- **Opening a place:** traceback links, go to definition and the debugger all
  use `openLocation(path, line)`. It focuses the pane where the file is
  already shown, otherwise adds a tab to the focused pane, and flashes the
  line.
- **Tab limit:** a pane keeps at most 10 tabs; the least recently used one
  closes.
- **Library files:** the standard library and our runtime stubs (ty's
  vendored files) open as read-only tabs (`ext:` paths) and are not linted.
- **Analysis root:** ty gets the running program's folder as an extra search
  path, so sibling modules resolve as they do at run time. That path is only
  applied once ty has a file from that folder, because it rejects search
  paths that don't exist in its in-memory file system.
- **Jump to Definition on touch:** a `WKWebView` subclass adds it to the text
  selection menu through `buildMenu(with:)`, which WebKit consults for that
  menu. It shows only while the editor (not `>>>`) has focus.
- **Loading:** an editor never shows a file before its text is loaded. It
  would otherwise create an empty document that saving writes back, which
  happened with restored tabs.

## D25: HTTP from Python goes through the native host

2026-10-13 - Accepted

Requests from the app's origin to other hosts would hit CORS. The worker
therefore routes cross-origin `XMLHttpRequest` and `fetch` calls to
`app://app/__http?url=…`, and the scheme handler makes the real request with
`URLSession`:
- It forwards the method, headers and body and follows redirects.
- The status and headers come back unchanged, except for headers that no
  longer apply (encoding, length) or would override our cross-origin isolation
  headers.
- Headers that browsers don't let scripts set, like `User-Agent` and `Cookie`,
  travel in `X-Terrarium-Headers`.
- A network failure answers 502 with `X-Terrarium-Error`, which the shim turns
  back into a network error.

On the Python side there is nothing app-specific:
- `requests` uses urllib3's Pyodide backend, which goes through fetch with
  JSPI. We empty its `HEADERS_TO_IGNORE` so `User-Agent` reaches the proxy.
- `urllib` gets pyodide-http's patch (sync XHR) when a program imports it.
- `httpx` and `pyfetch` work as they are.

The dev server implements the same `/__http` contract.

Published apps (D15) have no host, so they keep the browser's CORS rules; the
proxy only exists inside the app. Unhandled promise rejections in the worker
only count as crashes (D16) when they show a broken interpreter: urllib3
leaves a rejected promise behind in WebKit.

## D26: UI apps use Solid-style fine-grained reactivity

2026-10-13 - Accepted (was P1; supersedes D14; `uikit/`; in the app they render natively, D30)

The `ui` module works like SolidJS:
- Components are plain functions that run once.
- State lives in signals, computed values and deep reactive stores.
- Any function passed as a prop or child is a live binding that updates one
  DOM property.

Python keeps the element tree and sends batched ops (`mount`, `move`,
`unmount`, `set`). `For` reconciles keyed lists with minimal moves. Nothing is
re-rendered or diffed: text fields keep focus, and one change sends one op.
The library covers navigation stacks, tabs, sheets, dialogs, every common
input with two-way binding, canvas with a frame loop, async resources, and
raw HTML through `h()`.

D14 re-ran `view()` and resent and re-diffed the whole tree on every change
(23-26 ms for 1,000 rows). Its positional callback ids were fragile, and
controlled inputs needed care to keep the caret. Signals are also easier to
explain: "the lambda is what updates".

How it fits into the app:
- It uses the worker's existing `_uihost.render`/`set_dispatcher`.
- Every new renderer asks for a full snapshot (`resync`), so the app view can
  mount late or be re-created after the debugger hid it (D23). The session
  no longer replays messages.
- The source of truth is `uikit/`; `uikit/scripts/install.sh` copies
  `ui.py`, the renderer, the CSS and the todo example into `app/web`.
- Files a UI app writes after its script returned are written back when the
  app view closes (Done) or the app goes to the background. The worker
  answers a `sync` message with the files changed since the last sync.
- Examples in Documents are updated when the user hasn't edited them
  (checked by hash), so the D14-era examples get replaced.

Evidence: 88 host tests, plus 12 browser checks in desktop Chrome and
Playwright WebKit (0.1-0.23 ms per tap, 10-11 ms in Python for 1,000 rows,
one op and about 1 ms to toggle one row of 1,000). The `ui_app` and
`ui_todo` app selftests pass in WKWebView in the iPhone 17 simulator. Works
on the iPhone 14 Pro (2026-10-17).

## D27: Program files are written back while the program idles, deletions included

2026-10-13 - Accepted (extends D20, D26)

A program still works on a copy of its folder in the interpreter (D20), but
the copy no longer waits for the run to end:
- While the program idles (a 500 ms timer in the worker, which only fires
  between Python's tasks), the worker posts the files that changed. The page
  writes them back in order, one write-back after the other. A UI app's saved
  data reaches the disk within about a second, so a killed app, a crash or
  jetsam loses at most that. The end of a run, Done and going to the
  background still sync too.
- A change is a different mtime or size (mtimes are in milliseconds).
- A file the program wrote back and then deletes is deleted in the project
  too. Files the program did not write are never deleted, and if the program
  removes its working directory nothing is deleted at all.
- The order follows SQLite's: rollback journals (`-journal`, `-wal`) first,
  then the other files, then deletions. A database on disk is never newer than
  its journal, and the journal deleted at commit never stays behind as a "hot"
  journal that would roll the database back on the next open.

With that, `sqlite3` (in Pyodide's standard library here, SQLite 3.39) works
on project files like any other file: `Examples/Todo App.py` keeps its data
in `todos.db` and imports an old `todos.json` once. The whole database file is
copied on every change, which is fine for app-sized data (a few MB) but not
for big databases; a VFS that writes pages through the host would be the next
step if that matters.

Evidence: the `ui_todo` selftest adds a to-do and finds it in `todos.db` on
disk while the app is still open (0.7-0.9 s later), then reads it back in a
second run, with no journal left behind (iPhone 17 simulator, WKWebView).
Works on the iPhone 14 Pro (2026-10-17).

## D28: Linked folders (iCloud Drive, other apps) through security-scoped bookmarks

2026-10-13 - Accepted

"Open Folder…" in the file browser shows the system folder picker
(`UIDocumentPickerViewController` for `.folder`). The picked folder is kept as
a bookmark in the user defaults, opened with
`startAccessingSecurityScopedResource` at launch, and listed under Locations
at the top of the file browser. This covers iCloud Drive, other apps' folders
(Working Copy, ...), file providers (Dropbox, ...) and external drives, and
needs no entitlement.

- The web app addresses a linked folder as `@<name>/...` with the same `fs.*`
  bridge calls as Documents, so the editor, Run, write-back (D27), Find in
  Folder and ty work unchanged. Top-level names starting with `@` are reserved
  (hidden in Documents).
- Files in linked folders are read and written through `NSFileCoordinator`.
  Files that are only in iCloud are downloaded first (coordinated read, plus
  `startDownloadingUbiquitousItem` for `.name.icloud` placeholders).
- All file operations now run on one serial queue off the main thread, since
  a coordinated read may wait for a download.
- The root of a linked folder cannot be deleted or renamed from the app;
  "Remove" only forgets the bookmark.

The app's own iCloud container ("iCloud sync between devices" in GOALS) needs
the iCloud entitlement, which personal teams cannot use (Q20).

Evidence: the `linked_folder` selftest links a folder outside Documents
through the same bookmark code (the picker itself cannot be driven), lists,
writes, runs a script with a sibling import and file write-back, and removes
the link (iPhone 17 simulator). Works on the iPhone 14 Pro (2026-10-17).

## D29: `turtle` is CPython's module on a browser canvas, drawn inline in the console

2026-10-13 - Accepted

Pyodide ships neither `tkinter` nor `turtle`. We ship CPython's own
`turtle.py`, so the whole API and its behavior are the standard library's
(speeds, undo, stamps, shapes, `setworldcoordinates`, `Vec2D`, ...). Only its
Tkinter interface, which CPython keeps in one block (`TurtleScreenBase`,
`ScrolledCanvas`, `_Root`) for exactly this kind of port, is replaced by
`_terrarium_turtle.py`. `app/scripts/make-turtle.py` generates the app's
`turtle.py` from the host's 3.14 standard library.

- The backend keeps Tk's canvas model in Python (items with coordinates and
  options) and sends the changes as ops. The worker sends them on at most
  every 16 ms, and always before the program sleeps, blocks, prints or ends,
  so the console keeps the order and animation follows turtle's own delays.
- The page mirrors the items per screen (`TurtleScene`) and redraws them on
  a `<canvas>` once per frame. A screen is a console line, like a plot: it
  stays in the transcript after the run, fits the console (never scaled up),
  and >>> input can keep drawing on it. On iPhone the console sheet expands
  to full height when a drawing appears.
- Events: taps (screen and turtle clicks, drags, releases) and hardware
  keys are queued by the page while the program has handlers, and the
  program fetches them with a blocking call when it updates the screen (at
  most every 30 ms) or waits in `mainloop()`/`done()`, where Tk handles
  events too. Turtles get 10 canvas units of slack for fingers. Timers run in
  the same places. `textinput`/`numinput` use the native prompt dialog.
- Differences from Tk, on purpose: `done()`/`mainloop()`/`exitonclick()`
  return right away when nothing could happen (no handlers, no timers), since
  the drawing stays either way. A script that ends with handlers or timers
  keeps running as if it called `done()`, like in IDLE. `bye()` keeps the
  drawing and only ends its events. `save()` writes EPS from the items.

On the other hand, the window has no scrollbars (it always shows the middle
of the canvas), and there is no on-screen keyboard for key handlers on a
phone.

Evidence: the `turtle_*` selftests (draw a filled square and check its
pixels, a tap and a key reach the handlers, `bye()` ends `done()`, a timer
program keeps running until Stop, `Examples/Turtle.py`, and a tap that
catches the turtle in `Examples/Catch the Turtle.py`) pass in the iPhone 17
and iPad Pro 11 simulators (WKWebView). Works on the iPhone 14 Pro (2026-10-17).

## D30: In the app, ui apps are native SwiftUI views; the web renderer is for published apps

2026-10-14 - Accepted (extends D26)

`ui.py` keeps the element tree and its op stream (`mount`, `move`,
`unmount`, `set`, `call`, `dialog`, `toast`, `frame`, `reset`). In the app,
those ops drive a SwiftUI renderer (`app/ios/Sources/UIRenderer/`). Published
apps (D15) keep using `uikit/web/renderer.js`, and web pages only need to look
iOS-like, not like the native views.

How the native renderer works:
- **One observable node per element.** `UIStore` mirrors the tree as
  `@Observable` `UINode`s (type, props, children). A `set` op changes one
  node, so only the views that read that node update, the same fine-grained
  model as Solid. Event and value changes go back as `"<id>:<event>"` with
  JSON arguments.
- **Inputs echo nothing.** A change is written into the node before it is
  sent, and Python remembers it, so its echo is a no-op.
- **Native components where they exist:**
  - Screens are inset grouped `List`s. Sections become list sections, Rows
    become list rows (swipe to delete with `.swipeActions`). Any other child
    is a row on the background.
  - Navigation uses `NavigationStack(path:)`. The path leaves out screens the
    user already popped (back button or edge swipe) until Python unmounts
    them.
  - `TabView`, sheets with detents, alerts and confirmation dialogs, a toast
    overlay. Sheets, dialogs and toasts are presented from the topmost
    layer.
  - Controls: `Picker` (segmented and menu), `DatePicker`, `ColorPicker`,
    `Stepper`, `Slider`, `Toggle`, `TextField` (with keyboard kinds),
    `LabeledContent`.
  - Icon names map to SF Symbols, with emoji as the fallback.
- **Canvas** replays the recorded drawing calls (the browser's canvas 2D API)
  into Core Graphics. Paths are kept in canvas units, so `fill()` followed by
  `stroke()` works as in the browser. `on_frame` runs on `CADisplayLink`
  with one frame in flight. While the program listens for pointer events,
  touches on the canvas don't scroll the list.
- **The Done button** sits on the leading side of the app's first screen
  (each tab's first screen in a `TabView`). Replaced by a close button, D43.

The web-only escape hatches are gone: `h()`, `Html`, `css()`, `class_`,
`style` and arbitrary DOM events. Modifiers are now plain values that each
renderer translates:
- `padding` and `margin`: a number, (vertical, horizontal) or (top, right,
  bottom, left).
- Sizes: points, or `"fill"`.
- `flex`: a number.
- Colors: hex, `rgb()`, CSS names, iOS system colors (`red`, ..., `gray`) or
  semantic names (`primary`, `secondary`, `tertiary`, `tint`, `background`,
  `separator`, `fill`).
- `font_weight`: a name or a number.
- `text_align`: `leading`, `center` or `trailing`.
- `border`: a color, or (width, color).
- `shadow`: `True` or a radius.
- New: `tint`, and `accessibility_label` (`aria_label` still works).
The `Escape Hatches` example became `Async Data`.

Phase A wired this into the old React app as an overlay. D31 then made the
whole app native, and the renderer and its bridge carried over unchanged.

Evidence (iPhone 17 simulator, iOS 27):
- The `ui_app`, `ui_todo` and new `ui_navigation` selftests pass. They check
  push, the prompt dialog, back, and a sheet with a text field.
- Rendering a message takes 0.08 ms for 2 ops.
- Screenshots of every uikit example look like native iOS.
- `uikit/run.sh --selftest` passes (88 host tests, 12 browser checks).
Works on the iPhone 14 Pro (2026-10-17).

## D31: The IDE is a native SwiftUI app; web views only run Python and CodeMirror

2026-10-14 - Accepted (supersedes D4 and D18)

The React app is gone. Everything visible is SwiftUI:
- the file browser
- tabs and split view
- the navigation bar with Run, Stop and Continue, and native menus
- the console
- the debugger's controls and views
- the Find in Folder, Go to, Problems and Settings sheets
- ui apps (D30) and turtle screens

Pyodide still needs WebKit (D2), so two kinds of pages remain, built with Vite
and without a UI framework:
- **The engine** (`engine.html`) has no UI and never shows. It keeps the old
  session code: Python workers (D6, D10-D13, D16), the debugger protocol
  (D23), file write-back (D27), turtle scenes and their event queues (D29),
  and ruff and ty (D21).
  - The host sends commands through `window.__engine.command`. The engine
    reports session state through the bridge: the transcript goes as patches
    (new lines, appended text, the current order), the rest whole.
  - Its web view stays in the window as a 1-point view, with
    `WKPreferences.inactiveSchedulingPolicy = .none` so it is never throttled.
  - The self-test runs here and drives the native app through `app.*` hooks.
- **The editor** (`editor.html`) is one CodeMirror pane per web view (D17),
  two on iPad.
  - It is driven by `window.__editor.call`. It reports edits, focus,
    problem counts, breakpoints that moved, taps on names while paused,
    and long presses on line numbers.
  - Lint, completions, hover and go to definition go through the host to the
    engine. One ty instance serves both panes.
  - The problem bar with its quick fixes stays inside the page for now.
  - Edits are mirrored to the other pane right away. The text is saved after
    300 ms of quiet, and is flushed before a run.

The host owns breakpoints, settings and open tabs (in the user defaults) and
pushes them to the pages. Files are read and written natively through
`FileStore` (D20, D28). Linking a folder uses SwiftUI's `fileImporter`.

What this gets us:
- Real native controls: `NavigationStack`, swipe actions, context menus,
  `.searchable`, `Menu`, popovers anchored to code.
- Hardware shortcuts as `UIKeyCommand`s through `.keyboardShortcut`, which
  iPadOS lists in the ⌘ overlay.
- The console fields are `UITextField`s with no capitalization,
  autocorrection or smart punctuation, and ↑/↓ history.
- Turtle screens are drawn with Core Graphics from the scene ops.
- A crash of the engine's WebContent process no longer takes the editor
  with it.

What it costs:
- The IDE no longer runs in a desktop browser (`npm run dev` only serves the
  pages), and Android would need its own UI. GOALS is updated.
- There are three WebContent processes instead of one.
- Every editor and engine call is an IPC hop. Completions now take two.

Evidence: `./run.sh --selftest` passes all 40 checks in the iPhone 17 and
iPad Pro 13" simulators (iOS 27), including typing into the native console
fields through UIKit and pixel checks on the native turtle view. Works
on the iPhone 14 Pro (2026-10-17), with three WebContent processes, the keyboard and focus.

## D32: The agent's platform: native SQLite, a project ExecutionEnv, keys added by the proxy

2026-10-15 - Accepted (refines D7); the host-side key injection is superseded by D33

pi-durable and pi-ai run in a web view unmodified. What D7 left open is
decided like this:
- **Storage:** pi-durable's `SqliteStorage` on native SQLite. Every
  `SqliteDatabase` call is one bridge round trip. The page serializes the
  calls, so a transaction is `BEGIN IMMEDIATE` … `COMMIT` in call order.
  Whenever the page goes away, the host rolls back an open transaction.
  The database lives in Application Support, not in WebKit storage (Q2).
- **Files:** an `ExecutionEnv` over the project folder. The agent sees the
  folder as `/`, and paths that leave it are refused. There is no shell:
  `exec` answers `shell_unavailable`.
- **Provider HTTP:** a patched `fetch` sends it through `/__http` (D25),
  which streams. The host adds the API key header for the target host, but
  only for requests carrying a per-launch token that only the page's main
  thread holds. The page uses a placeholder key; Python workers can't
  borrow the credential.
- **Durability:** submissions use a `requestId`, and the page calls
  `harness.resume()` after a reload or crash. An interrupted answer retries.
  An interrupted tool that is not replay-safe becomes an error result the
  model sees.

Evidence: `spikes/agent/` (iPhone 17 simulator):
- pi-durable's storage conformance suite passes 24/24 on the bridge.
- Bridge round trip: 0.14 ms. Tool rounds cost about 20 ms of storage each
  (about 140 statements); streamed answers cost nothing extra.
- Server-sent events arrive in chunks as they are sent.
- The key is injected with the token (200) and not without it (401).
- After a reload in the middle of a stream and in the middle of a tool call,
  the turn continues as described above.

Not yet tried: a device, a real model, a real WebContent crash.

## D33: Sign-in runs pi-ai's own flows; credentials live in the engine page and the Keychain

2026-10-15 - Accepted (supersedes D32's key injection)

OAuth makes D32's "keys never enter the web view" impossible to keep: pi-ai
exchanges the code for tokens and refreshes them in JavaScript. One model
covers API keys and OAuth alike:
- **Credentials** are pi-ai's `CredentialStore` over page-only bridge ops,
  stored in the Keychain: one item per provider, this device only, readable
  after first unlock. While the app runs they are in the engine page's
  memory. The proxy only forwards; it adds no keys.
- **Who cannot reach them:**
  - Python workers (user or agent code) cannot read the page's memory or
    call the bridge.
  - The scheme handler never serves credentials.
  - Editor pages are refused: the `agent.*` ops are for the engine only.
- **Login flows** are pi-ai's own:
  - They are bundled through Vite aliases and registered with
    `registerBundledOAuthFlowLoaders`, as pi-ai's Bun build does.
  - `node:http` and `node:crypto` are shimmed. `node:http` runs on a native
    loopback listener (`LoopbackServer.swift`, 127.0.0.1 and ::1), so
    `startOAuthCallbackServer` and the ChatGPT flow's server run unmodified.
  - Auth URLs open in `ASWebAuthenticationSession`. Device-code flows open
    nothing: the sheet shows the code and the full address
    (`radius.earendil.com/pair`), so the user can sign in on another device
    or tap the address to open it in Safari (2026-10-15: changed from opening
    the link right away).
  - pi-ai's prompts (method, key, pasted code) are a native sheet. The
    bridge call stays pending until the user answers.
- **The proxy drops WebKit's own User-Agent.** Anthropic's token endpoint
  answers a browser or curl User-Agent with a fake 429 rate limit; a CFNetwork
  or node one is accepted. A User-Agent the code sets (pi-ai's `claude-cli/…`)
  travels in `X-Terrarium-Headers`, as Python's does (D25).
- **OpenAI Codex uses server-sent events** (`stream.transport: "sse"`): a
  browser WebSocket cannot carry auth headers.
- **Simulator:** unsigned simulator builds need their entitlements embedded
  for the Keychain (`__TEXT,__entitlements` via the linker, as Xcode does).
  That only works with `ENABLE_DEBUG_DYLIB = NO`.

Evidence: `spikes/agent/` (iPhone 17 simulator):
- `oauth-mock` passes end to end: the sign-in sheet, the redirect to
  localhost, the native listener, the code exchange, the Keychain, Bearer
  requests carrying the `claude-cli` User-Agent, a forced refresh, and a
  reload.
- A real Claude Pro/Max sign-in: requests, refresh, and after a reload.

The simulator shares the Mac's network. On the iPhone 14 Pro (2026-10-17)
the agent works, the sign-in sheet reaches the app's loopback listener, and
the other providers' sign-ins work too.

## D34: The coding agent in the app

2026-10-15 - Accepted (from P1)

The agent runs in the engine page (`app/web/src/agent/`, loaded on first
use) on D32 and D33.
- **Tools:**
  - pi-durable's `read`, `write` and `edit` over the project folder.
  - `ls`, `find` and `grep` (there is no shell).
  - `run_python`: a fresh Pyodide worker per call, with the project folder
    copied in and written back (D27). It streams output and returns
    matplotlib figures as images. `input()` gets EOF; ui apps are stopped.
  - `check` (ruff + ty) and `format` (ruff format).
  - `write` and `edit` append new ruff/ty problems of Python files to their
    result.
- **Conversations:** one per project folder: the open file's folder, else
  the folder on screen. The host remembers the conversation and the last
  model in the user defaults.
- **System prompt:**
  - the environment: Pyodide, no shell, PEP 723 dependencies, turtle and
    ui apps only through Run;
  - the `ui` module's reference, from `uikit/README.md`.
- **UI:** a native sheet (`AgentViews.swift`) fed by the conversation's
  `viewState()` as a compact transcript (`agent.state`). It has:
  - collapsible tool calls with diffs and an "Open file" link;
  - a model menu;
  - Accounts: subscriptions, other sign-ins, API keys;
  - the sign-in sheet.
- **Editors:** the agent's first read in a tool call saves unsaved editor
  text. Its writes reach open editors and the file list through
  `files.changed`.

Not built yet from P1:
- refusing a write when the editor's buffer changed since the agent read it;
- per-turn undo;
- teaching mode;
- a docked panel on iPad instead of a sheet.

Evidence: the `agent` self-test check. A scripted model (pi-ai's faux
provider) drives every tool against a real folder. The check confirms:
- the files on disk;
- `run_python`'s write-back;
- lint feedback after `write`;
- the diffs;
- the open editor showing the edit;
- the native transcript.

It passes with the other 42 checks on the iPhone 17 simulator (2026-10-15).

## D35: Programs use the project's files in place; linked folders through a local copy

2026-10-15 - Accepted (supersedes D27; changes D20 and D28)

A run no longer copies its folder into MEMFS and writes changed files back.
The worker mounts the folder as `HOSTFS`, an Emscripten file system
(`app/web/public/runtime/hostfs.js`, modelled on NODEFS) whose operations
go to `HostFS.swift` as synchronous XHRs (`POST /__fs` on the scheme
handler). That handler does the real `open`/`pread`/`pwrite`/`fsync`. The
mount sits at the same path as the copy did (`/home/pyodide/project`), so
tracebacks, the debugger and `>>>` are unchanged.

What this changes:
- **Writes:** they land in the file itself, page by page. SQLite works on
  the real database with its journal, and a killed program is a crash that
  SQLite recovers from.
- **No copies:** nothing is copied at the start, so big folders cost
  nothing.
- **Gone:** the manifest, the write-back ordering and the 64 MB tree limit.

Every call is a round trip (0.1-0.2 ms on the simulator), so the worker
keeps three things (`spikes/host-fs/`):
- **A write-behind queue** for all files:
  - It goes to the host in one call before any other call, so the host
    sees every operation in program order.
  - It is also sent when the program idles (every 250 ms), blocks
    (`input()`, sleep, the debugger, turtle) or ends.
  - A killed worker loses at most what is queued, as if it had crashed a
    moment earlier. The spike's crash test confirms SQLite recovers from
    that.
- **A stat cache:** missing files included, entries live for 1 s.
- **A 64 KB block read cache:** checked against size and mtime when a file
  is opened, dropped where this worker writes.

Both caches are dropped when the mount's generation changes. The host
raises it when the app (editor, agent, file browser) or another interpreter
changes project files; each reply carries it.

Linked folders (iCloud Drive, file providers, other apps) are not used in
place: every operation would need `NSFileCoordinator`, and a file provider
can't be trusted with page-level writes into a database. Instead:
- **Mounting** copies the folder into `Caches/Staging/<mount>` with
  coordinated reads (downloading what is only in the cloud; 512 MB at
  most).
- **The program** works on that local copy.
- **Sync back:** `HostFS` records which paths the program changed, and
  writes them back with coordinated writes:
  - after 0.3 s of quiet (at least every 2 s while the program keeps
    writing);
  - when a run ends;
  - when the app goes to the background;
  - at unmount.
  Journals go first, then files, then folders and removals. The copy is
  cloned first (APFS), so the program can keep writing meanwhile.

Also:
- **Notifications:** the host tells the views about changed files itself
  (file list, open tabs, ty's folder). The page's write-back path is gone.
- **Agent:** `run_python` mounts the folder the same way and reports the
  files the host saw change.
- **`PYTHONDONTWRITEBYTECODE`:** imports of sibling modules no longer leave
  `__pycache__` in the user's folders.

What it costs, and what is open:
- **Many small files are slow:** creating, writing and closing one is
  about 6 calls, about 0.5 ms each on the simulator.
- **SQLite is close to MEMFS with the caches:** a todo-style save takes
  about 2 ms.
- **Outside edits during a run** (Files app, iCloud) are seen within 1 s
  for stats. Contents are only checked when a file is opened.
- **No real file locks:** Emscripten answers `F_SETLK` itself, so two
  interpreters writing the same database (a run and the agent's
  `run_python`) are not protected from each other.
- **Main thread:** both the scheme handler and the bridge run on the main
  thread, so a busy UI adds latency.

Evidence:
- `spikes/host-fs/` (iPhone 18 Pro simulator): the costs, the caches, and
  the crash and integrity tests.
- In the app, the new `project_files_in_place` check:
  - writes are on disk while the program waits in `input()`;
  - an edit made meanwhile is seen;
  - renames and deletions happen right away;
  - SQLite leaves no journal;
  - no `__pycache__` appears.
- The `linked_folder` check now also syncs back a new folder and a deletion.
- All 44 checks pass in the iPhone 18 Pro simulator (2026-10-15).
- Works on the iPhone 14 Pro (2026-10-17).

## D36: The agent's conversations per project, and IDE tools

2026-10-15 - Accepted (was P1; extends D34)

**Projects.** A conversation works on a project. Before, the project was
the open file's folder, so a file in a subfolder switched to another
conversation. Now the project is:
- the top-level folder in Documents;
- a linked folder's root (D28);
- Documents itself, for loose files.

The same project is used whether the agent is opened from a file or from
the file browser.

**Conversations.** A project has several. A conversation is never kept per
file, because the work spans files.
- **Opening the agent** shows the conversation on screen if it belongs to
  the project, else the project's most recent one, else a new one.
- **New** starts another one. A new conversation without messages is
  reused instead of making more empty ones.
- **The list** (tap the title) shows the project's conversations, newest
  first, each with a running spinner and an unread dot. Conversations can
  be renamed and archived.
- **Archived** conversations are kept, listed apart, and can be
  unarchived. Nothing is deleted.
- **Titles** are the first line of the first message.
- **In the background:** a conversation keeps running when another one is
  on screen (pi-durable runs them concurrently). The ✨ button pulses
  while any of them works.
- **Renaming or moving a folder in the app** moves its conversations'
  project and their `cwd` with it.

**Index.** pi-durable has no call that lists conversations, so the engine
keeps its own index (`app/web/src/agent/conversations.ts`), a second
SQLite database ("conversations") on the bridge from D32. Each row has:
- `id`, `project`, `title`;
- `created`, `updated`, `seen` (unread means updated after seen);
- `archived`;
- the IDE context the model last got.

The old user-defaults map (project -> conversation) is imported once.
Those conversations keep their folder as their project and show up under
the project that contains it.

**Two kinds of tools:**
- **Project tools** (D34): `read`, `write`, `edit`, `ls`, `find`, `grep`,
  `run_python`, `check`, `format`. They work on the files on disk; the user
  sees nothing happen.
- **IDE tools** (`app/web/src/agent/ide.ts`), all named `ide_*`, change what
  is on the user's screen:
  - `ide_state`: tabs per pane, the active file, cursor line, the
    selection with its text (cut at 4000 characters, and marked when cut),
    whether a program runs;
  - `ide_open(path, line?, end_line?, pane?)`: open or switch to a file,
    scroll to the line, and select and flash a range;
  - `ide_close(path)`: close its tabs. What was typed is saved first, as
    when the user closes a tab;
  - `ide_lint(path?)`: ruff + ty on the editor's text, typed text
    included. The problems show in the editor and come back in the result;
  - `ide_format(path?)`: ruff format in the editor, undoable there.

  `ide_lint` and `ide_format` work on files open in a tab (default: the
  active one). For other files they point the model to `check`/`format`
  or `ide_open`.

**Keeping the model from confusing them:**
- every IDE tool's description starts with the same sentence: it acts on
  the editor, not on files on disk, and names the project tools for those;
- results are short messages, never file contents (except the selection
  in `ide_state`), so an IDE tool can't be used to read code;
- the system prompt has a section on the two kinds: IDE tools are for
  showing the user something, or for acting in the editor when asked;
- the transcript shows an IDE call as one line with its message (the whole
  result when tapped), not as a call with a diff. The tools are told apart
  by the `ide_` prefix; there is no extra flag on the tool definitions.

**Behaviour:**
- **Only for the conversation on screen:** called from a background
  conversation, an IDE tool changes nothing. It answers that the user is
  not looking at this conversation.
- **No confirmations:** nothing here loses data.
- **Typing:** if the user typed in the focused editor in the last 3
  seconds, `ide_open` doesn't switch that pane away. It opens the file in
  the other pane (iPad) or adds a tab behind the current one (iPhone).
- **iPhone:** the agent sheet has medium and large detents and lets the
  editor behind it be used at medium. After `ide_open` it drops to medium,
  so the file shows.

**IDE context:** the open tabs, the active file, the cursor line, the
selection, a running program and the active file's last failed run. It is
sent only when it changed since the model last saw it:
- **With a message:** before the message, as an `<ide>` block. This
  replaces the `<editor>` block that D34 sent with every message.
- **Mid-turn:** when the tabs or the active file change while the
  conversation on screen works. The host tells the engine; 400 ms later
  the engine reads the state again and compares.
  - If it changed, a `terrarium.ide` entry is submitted as a write with
    a model message. pi-durable places it at the next boundary, like a
    steer.
  - pi-ai has no system role mid-conversation, so the block goes in as a
    user message. The transcript shows it as a note: "Now in greet.py ·
    line 1".
  - A queued entry the next message supersedes is withdrawn.
  - Changes made by the agent's own IDE tools are ignored: their results
    already told the model.

`ide_run` (Run in the app, so turtle and ui apps can be seen) stays for a
later decision.

Not built: recording which files a conversation touched (to list
conversations about a file), a filter across projects, and better titles
than the first line.

Evidence: the self-test's `agent-ide` and `agent-conversations` checks
(`app/web/src/selftest.ts`), with the scripted model of D34. They check:
- **`agent-ide`:**
  - no `<ide>` block when nothing changed;
  - each IDE tool's result and its effect on the editor, including the
    formatted file on disk after `ide_close`;
  - the medium detent on iPhone;
  - the user moving to another file mid-turn reaching the model at the
    next step, and the note in the transcript;
  - `ide_open` of a missing file failing.
- **`agent-conversations`:**
  - a second conversation;
  - a background run whose `ide_open` is refused;
  - unread;
  - titles;
  - archiving the conversation on screen and unarchiving it;
  - rename;
  - a renamed folder.

All 46 checks pass in the iPhone 18 Pro simulator. In the iPhone 17
simulator only `turtle_catch_example` fails, and it fails the same way
without this change. The three agent checks also pass in the iPad Pro 13"
simulator (2026-10-15). Works on the iPhone 14 Pro (2026-10-17).

## D37: Two bundled Pythons (3.14 and a 3.15 preview) and the Python docs on the device

2026-10-15 - Accepted

**Versions.** The app bundles Pyodide `314.0.7` (Python 3.14.2, the
default) and Pyodide `315.0.0-alpha.2` (Python 3.15.0rc1, labelled
"preview"). Both are pinned in `app/runtimes.json`, the one list the
scripts, the engine and the host read. Each has its core under
`web/pyodide/<python>/`, its packages under `/pkgs/<python>/` (cached per
Pyodide version, from its own CDN folder: the 3.15 one is `v315.0.0a2`, not
the npm version) and its docs. 3.13 is not offered.

3.15's Pyodide has only 31 packages (numpy and scipy, no matplotlib,
pandas or Pillow). Pure-Python wheels from PyPI, `ui` and turtle work.

**Which one a program runs on** (`app/web/src/runtimes.ts`), following uv
so a project runs the same with `uv run`:
1. `requires-python` (the PEP 723 block, else `pyproject.toml` in the
   folder) limits the candidates; none left is an error that names both
   versions;
2. a `.python-version` (the folder or one above it) picks one of them;
3. else the default from Settings;
4. else the newest stable candidate, a prerelease only when nothing else
   fits.

Specifiers compare release numbers only, so 3.15.0rc1 satisfies
`>=3.15`. The ⋯ menu shows the file's version and pins its folder by
writing `.python-version` (as uv does). The console's run header shows
the version. The warm pool keeps a spare for the default and for the
last other version used. ty and ruff check each file against its version
(the engine sends `setPython` before each request). `run_python` uses the
same rules and reports the version.

**Docs.** The official HTML archives from docs.python.org, pinned by
sha256 in `runtimes.json`. The archives are rebuilt in place upstream, so
`scripts/build-docs.py` refuses a changed one until `--update-pins`. The
build:
- prunes the C API, extending, What's New older than two versions, the
  changelog, the general index, Sphinx's search and images over 1 MB
  (about 66 -> 35 MB for 3.14);
- patches each page for the viewer: no site header, sidebar, switchers or
  scripts beyond Sphinx's own and the copy button, links to pruned pages
  go to docs.python.org, and a small stylesheet (field lists stacked on
  phones, the target entry highlighted). The theme's dark mode follows
  the system;
- writes `docs.sqlite`: Markdown chunks (one per section, API entry and
  glossary term; about 13,500), an FTS5 index (porter, bm25 weighted to
  titles and names) and a symbol table (about 10,800 names). About 19 MB.

The official HTML was chosen over EPUB: iOS has no EPUB view to embed,
and the EPUB is the same XHTML with a plainer stylesheet and no dark mode.
The HTML's theme already has a mobile layout. The text archive has no
anchors, so the Markdown is derived from the same HTML, and refs are the
same in the viewer and for the agent.

**Using them:**
- **Viewer** (`Shell/DocsView.swift`): a web view on
  `app://app/docs/<python>/`, native search over the index, back/forward,
  a version switch, links out open in Safari. Presented with UIKit over
  whatever is on screen, so it also opens over the agent's sheet. From
  the ⋯ menus, ⌘⇧0, Show Info ("Open Documentation" when ty resolves the
  name into the standard library) and `docs:<version>/<ref>` links in the
  agent's answers.
- **`help(x)`** in Python opens the viewer for standard library objects
  (private modules are mapped to the public name: `pathlib._local.Path`
  is documented as `pathlib.Path`) and falls back to pydoc's text.
- **Agent:** `docs_search` (names first, then words), `docs_read` (a
  section with its subsections or one entry, as Markdown, in parts of
  16,000 characters) and the IDE tool `ide_show_docs`. The version
  defaults to the project's. The prompt asks the model to look things up
  rather than guess, especially recent APIs.
- The host searches (`DocsIndex.swift`, the system SQLite with FTS5,
  opened `immutable`).

The 3.14 docs are 3.14.8's while the runtime is 3.14.2, and the 3.15
docs are a snapshot of the 3.15 branch (2026-10-15) while the runtime is
3.15.0rc1. Patch releases rarely change the docs.

Evidence: the self-test's `python_versions`, `docs_index`, `docs_viewer`,
`help_opens_docs`, `show_info_docs` and `agent-docs` checks. All 52 checks
pass in the iPhone 18 Pro and iPad Pro 13" simulators (2026-10-15). Both
versions, 3.15 included, and the docs work on the iPhone 14 Pro (2026-10-17).

## D38: Home Screen icons for programs go through the Shortcuts app

2026-10-15 - Accepted

iOS doesn't let an app put icons on the Home Screen. The ways around it:
- **the Shortcuts app**: a shortcut can be added to the Home Screen with a
  name and an icon, and can run an app's App Intent;
- **a Safari web clip** that redirects to a custom URL scheme: it needs a
  page on the web (or a configuration profile) and goes through Safari;
- **publishing the program** as a PWA (D5, D15): needs hosting, and runs in
  Safari's engine, not in the app.

We take the first, as Pythonista does. The app has:
- a **"Run Python Program"** App Intent (`app/ios/Sources/ProgramIntents.swift`)
  that opens the app and runs a program like the Run button (a ui app opens
  full screen). Its parameter is an entity for each `.py` file in
  Documents; files in linked folders can be picked by path but are not
  listed, since listing may download them. An App Shortcut ("Run <program>
  in Terrarium") makes it show up in Shortcuts, Spotlight and Siri;
- **`terrarium://run?path=<app path>`** (and `open?path=`) links, for an
  "Open URL" action or anywhere links open;
- **"Add to Home Screen…"** for `.py` files (the editor's ⋯ menu and the
  file browser's context menu): a sheet with the steps in Shortcuts, a
  button that opens a new shortcut, and the program's link to copy.

Both ways in go through `LaunchRouter`: requests wait until the app has
restored its tabs and the engine page is ready, which matters on a cold
launch from the Home Screen. A program that is running when another one
is launched is stopped first.

Not possible from the app: making the shortcut itself (a `.shortcut` file
has to be signed, which only macOS can do), or opening Shortcuts at the
action.

Evidence: the self-test's `launch_shortcuts` check (a link, the intent with
a ui app, a second launch ending the first, the entity list, the sheet).
A cold launch with a link (`simctl launch … --launch-url`) runs the Todo
app in the iPhone 18 Pro simulator. All 53 checks pass there (2026-10-15).
The Shortcuts app's side was not driven by the test.

## D39: Editor color themes, each light and dark; the app's appearance in Settings

2026-10-15 - Accepted

The code editor has five themes (`app/web/src/editor/themes.ts`), each with
a light and a dark palette:
- **Terrarium** (the default), drawn from the app icon: on light, deep
  Python blue keywords, blue definitions and amber strings on near-white
  with a yellow-tinted current line; on dark, Python yellow keywords and
  caret, light blue definitions and orange strings on the icon's navy;
- **Xcode** (the colors the editor had before), **GitHub**,
  **Solarized** and **One** (Atom's One Light / One Dark).

A palette is a set of CSS variables on `:root[data-theme=<id>]`, light by
default and dark under `prefers-color-scheme: dark`; the editor's
CodeMirror theme and highlight style only use the variables. The generic
iOS colors of the page (tint, red, the problem bar) stay as they were.

**Appearance** (Settings: System, Light, Dark) applies to the whole app by
overriding the windows' interface style, so the native views, the editor
pages and the docs viewer agree; forcing only the editor would leave it
light inside dark chrome. Settings lists the themes with a swatch of both
variants and previews the selected one in the current appearance, with the
colors the editor page reports (one definition, no copy in Swift). Saved
settings from before keep their other values.

Evidence: the self-test's `editor_themes` check (the list, the default,
Solarized's dark and light backgrounds after switching the appearance),
in the iPhone 18 Pro simulator (2026-10-15).

## D40: iOS device modules with Pythonista's names and API

2026-10-15 - Accepted

Programs can use the device through modules named and shaped like
Pythonista's, so its scripts and tutorials often run unchanged. The API
follows Pythonista's reference docs (3.4); the implementation is our own:
- **Python** (`app/web/public/runtime/python/`): `clipboard`, `console`,
  `dialogs`, `keychain`, `notification`, `photos`, `location`, `motion`,
  `sound`, `speech`, `contacts`, `reminders`, and `haptics` (not in
  Pythonista); `webbrowser.open()` opens links in the app. A shared
  `_device.py` makes one blocking call per function through the sync
  channel `input()` uses (D10), like `host.call_sync`.
- **Native** (`app/ios/Sources/Device/`): one `device.*` bridge op each,
  on UIKit, PhotoKit, Core Location, Core Motion, AVFoundation, Speech,
  Contacts, EventKit, UserNotifications, MapKit and the Keychain.

How they behave:
- **Blocking, like Pythonista:** a dialog returns its answer. Alerts'
  Cancel raises `KeyboardInterrupt`; the `dialogs` sheets return None.
  Stop ends the wait and closes the dialog; whatever a program left on
  screen goes when it ends, and sensors, sounds, speech and recordings stop
  when the next program starts.
- **Files** are passed by reference: a path in the program's folder, which
  the host resolves through the mount (HostFS, D35, which now also hears
  about files the host writes, e.g. recordings), or the bytes of a file
  elsewhere. Results bigger than the 1 MB channel (photos) come in pieces.
- **Images** are PIL images. Pillow loads with a program that imports
  `photos`, `clipboard` or `location`; HEIC and other formats Pillow can't
  read arrive as JPEG; `raw_data=True` gives bytes. 3.15 has no Pillow.
- **Permissions:** each module asks when first used; Info.plist explains
  why. Denied access raises `PermissionError`.
- **Not from the agent:** `run_python` refuses device calls
  (`PermissionError`), so the agent can't read contacts or photos, or put
  up dialogs, behind the user's back.

Differences from Pythonista: `scene`, `ui`'s Pythonista API, `cb`,
`appex`, `keyboard`, `editor`, `canvas`, `objc_util` and
`linguistictagger` are not provided; built-in sound effects are a small
synthesized set (beep, coin, laser, …) instead of Pythonista's asset
library; `photos.get_moments()` is empty (PhotoKit dropped moments);
contacts' ids are strings and their notes field is not available (it
needs an entitlement); `console.set_font` only does bold. Published web
apps (D5) don't have the modules yet.

Evidence: the self-test's `device_basics`, `device_dialogs` (every dialog
kind, answered through a test hook, plus Quick Look, the share sheet and
a cancelled alert), `device_stop_closes_dialog` and `device_pim`
(contacts, reminders, notifications without permission, location, photos)
checks, with the simulator's permissions granted by `run.sh`. The camera,
microphone and speech recognition were not exercised (no hardware in the
simulator). All 59 checks pass in the iPhone 18 Pro and iPad Pro 13"
simulators (2026-10-15); `device_modules_typed` (ty resolves and checks
the modules) was added after and passes in the iPhone 18 Pro simulator.

## D41: File management: Trash, moving, Quick Look and sharing, favorites, templates

2026-10-15 - Accepted

- **Trash:** deleting from the browser or the editor moves a file or
  folder in Documents into `Documents/.Trash`, with where it came from;
  it can be put back (next to a file of the same name if one appeared) or
  deleted for good, and goes after 30 days. Because it can be undone, it
  asks nothing. In a linked folder it goes to the provider's trash
  (iCloud Drive's Recently Deleted) or, if it has none, is gone, so that
  still asks. Programs (`os.remove`), the agent and the self-test delete
  directly, as before.
- **Moving:** drag a row onto a folder, or Move… (context menu, editor ⋯)
  with a folder picker that includes linked folders. Open tabs,
  breakpoints, favorites and agent conversations follow, as with renames.
- **Quick Look and sharing:** images, PDFs, audio, video and Office files
  open in Quick Look instead of the editor; every file has Quick Look and
  Share… (Open in, AirDrop, Save to Files). Files in linked folders go
  through a copy.
- **Favorites:** files and folders pinned at the top of the browser; they
  follow renames and moves and go with deletions.
- **Templates:** New File is a sheet with a name and a template: Empty,
  Script, App (`ui`), Turtle Drawing, Plot, Dialogs, Script with Packages
  (PEP 723), Notes (Markdown), and the files in `Documents/Templates`.

Not built: selecting several files at once, previews of SQLite databases.

Evidence: the self-test's `file_management` check (move with the tab
following, favorites following and leaving, trash and restore, restore
beside a same-named file, delete for good, two templates, Quick Look of a
PNG). All 59 checks pass in the iPhone 18 Pro and iPad Pro 13" simulators
(2026-10-15).

## D42: The app's own modules are documented next to the Python docs

2026-10-15 - Accepted (extends D37)

`ui`, turtle in the app and the device modules (D40) have reference pages
written by hand in Markdown (`app/docs/*.md`): an overview of how programs
run (Run, input, Stop, packages, versions, HTTP, links, help, shortcuts),
one page per module with an introduction, examples and every function,
class, method and attribute.

`scripts/build-docs.py` renders them into `terrarium/` inside each bundled
docs set, in the HTML Sphinx makes: sections with ids, API entries as
`dl.py` with the full name as id (`ui.Button`, `sound.Player.play`),
code highlighted with the archive's Pygments styles. So the viewer shows
them like the Python docs (dark mode, the stylesheet, the breadcrumbs), and
the same index takes them in: chunks, symbols, full-text search. Nothing
treats them differently:
- the agent's `docs_search` and `docs_read` find and read them like the
  standard library (`terrarium/photos.html#photos.pick_image`); their
  descriptions and the prompt say they are there;
- `help(clipboard.get)` and Show Info open them;
- the docs' start page links them first, and the viewer's book menu has
  "Terrarium Modules".

Rendering from Markdown keeps the sources readable and diffable; writing
them by hand (not from docstrings) gives room for introductions, examples
and the differences from Pythonista. The turtle page has no module id, so
`turtle` still means the standard library's reference. The build stamp
includes the sources, so editing a page rebuilds the docs.

Three examples use the device modules in `ui` apps: `Photo Booth.py`
(camera, library, Pillow filters, saving, sharing, haptics), `Level.py`
(motion read every frame on a canvas, haptics, location with a reverse
geocoded address and a map image) and `Birthdays.py` (contacts' birthdays
with reminders, yearly notifications and a message link).

Evidence: the self-test's `app_docs` (search by name in both versions, by
words, reading a class, `help()` for a function and a class, Show Info)
and `device_example_apps` (each example opens and closes without an error)
checks. All 62 checks pass in the iPhone 18 Pro simulator (2026-10-15).

## D43: ui apps close with an X that can restart them, or close themselves

2026-10-15 - Accepted (amends D30)

A ui app stays full screen, both when it runs from the editor and when a
Home Screen shortcut launches it (D38). A sheet over the IDE was
considered and rejected: a shortcut's app has to fill the screen, and an
app run from the editor should look the same.

"Done" was the wrong word, because the button ends the program and saves
nothing. It is now the system's close button, a round X, still on the
leading side of the app's first screen. A tap ends the program, as before.
Touch and hold it for a menu with **Restart**, which runs the program
again like Run: the app view stays up with a spinner until the new run
shows its UI, so it doesn't slide away and come back. A run that ends
without a UI brings the editor back. The app's own leading toolbar items
come after a small gap, so they don't share the X's glass background.

An app can leave the button out and own its exit:
- `ui.run(app, close_button=False)` hides it (a `close_button` key in the
  `config` op).
- `ui.close()` ends the app (a new `close` op). The native renderer
  ignores whatever the program sends after it and calls the same close
  path as the button. The web renderer calls `onClose`, which clears the
  view by default, because a published page has nothing to close.
- Without the button, a two-finger swipe down anywhere closes the app, as
  in Pythonista with `hide_title_bar`. The recognizer sits on the window
  next to the views' own gestures, so lists and canvases keep working.

The engine now ignores render messages from a worker that is no longer
the session's. A closed program that is still flushing, or the program a
restart replaced, can no longer reopen the app view.

Later: "Show Code" in the X's menu, which would hide the app and keep it
running with a way back from the IDE. And a Run menu in iPadOS's menu
bar (Run, Stop, ⌘.), which would also show Stop while an app is up.

Evidence: `uikit/run.sh --test` (89 tests; the new one checks the config
key and the `close` op). The app's `ui_app` self-test restarts the
Counter App: a new run, the count back at 0, and the view never hidden.
The new `ui_close_from_python` test runs a program with
`close_button=False` and a button that calls `ui.close()`. All 63
checks pass in the iPhone 18 Pro simulator (2026-10-15). The two-finger
swipe was not tested: the self-test can't make touches.

## D44: Notebooks: .ipynb and `# %%` cells in the editor, run in a kernel

2026-10-15 - Accepted (GOALS' "notebook mode" moves from [maybe] to [core])

Both kinds of notebooks work: Jupyter's `.ipynb` (course material, Colab,
GitHub) and Python files with cells in the percent format (`# %%`, `# %%
[markdown]`, as VS Code, Spyder and jupytext write them). A `.ipynb` opens
as a notebook; "Show JSON Source" in the ⋯ menu shows the file itself.

**The editor.** A notebook is one CodeMirror document in the existing
editor page, not a CodeMirror per cell or native cells:
- Each cell is a marker line followed by its source. A state field keeps
  each cell's id, type, outputs and count. It follows the markers through
  edits by mapping their positions, and structural edits (insert, move,
  delete, change type) carry the cells' new order in an effect that undo
  inverts.
- In a `.py` the markers are the file's own `# %%` lines, which get a ▶
  button and a count. In a `.ipynb` they are ours (`# %%` plus a
  private-use character, so no source line can pass for one). They are
  hidden behind cell headers (▶, `[n]`, and for the cell with the cursor:
  code/Markdown, move, add, delete), atomic for the cursor, and
  protected: typing and deleting that touch one are cut down to the parts
  inside cells, so Backspace at the start of a cell does nothing, as in
  Jupyter.
- Outputs are block widgets under their cell, updated in place. Markdown
  cells render while the editor doesn't have focus or the cursor is
  elsewhere. A `.ipynb` gets a toolbar (Run All, Restart, Clear, the
  kernel's state) and an add bar at the end.
- One document keeps what the editor already does: lint, completions, go
  to definition, find, undo, the key bar, the split view's mirroring. And
  focus never has to jump between text fields, which iOS's keyboard
  makes hard.
- ruff and ty see a `.ipynb` as `<name>.ipynb.py`: the document with
  Markdown, magics and `%%html`-style cells blanked to spaces, so every
  position is the editor's. In both kinds of notebooks, E402, E703, B018 on
  a cell's last line, top-level `await` and `display` go unreported.
  Format Code formats each code cell on its own.

**The file.** The editor reads and writes `.ipynb` (nbformat 4, written
4.5 with cell ids, keys sorted, indent 1, as Jupyter writes it, so diffs
stay small). Metadata, attachments and outputs are kept. Outputs from a
run are saved by the pane that ran the cells. A `.py` keeps no outputs.

**The kernel.** The session's interpreter becomes the notebook's kernel
and stays for its cells (one program at a time, as before). Running a
script, another notebook, Restart, or Stop's kill (D11) ends it, and the
notebook shows that. The first cell of a new kernel installs the
notebook's dependencies (a PEP 723 block or `pyproject.toml`, D22). Cells
run one after the other from a queue, and an error drops the rest, as Run
All does in Jupyter. Outputs reach the editors as events (queued, start,
output, update, clear, done, kernel), batched per frame, which the host
passes to every pane with the notebook. The console's `>>>` runs in the
kernel while it lives.

**Python** (`_terrarium_notebook.py`): `run_cell` runs a cell in `__main__`.
The last expression is shown unless it ends in `;`, top-level `await`
works, figures are shown at the end, and errors (with KeyboardInterrupt
and SystemExit) become error outputs with the cell's frames only, so the
kernel lives on. The display protocol is IPython's: `_repr_html_`,
`_repr_png_`, `_repr_markdown_`, `_repr_mimebundle_` and so on, and
`display()` with display ids. An `IPython` module of our own (a meta path
finder) has `IPython.display` (HTML, Markdown, Image, SVG, JSON, Latex,
IFrame, clear_output, update_display) and `get_ipython()`. Its shell has
the `events` and `enable_gui` that matplotlib calls once IPython is
imported. Pyodide's real IPython is not loaded: imports of it are left out
of package auto-loading. Magics become one call per line, so line numbers
stay: `%pip`, `%time`, `%timeit`, `%run`, `%cd`, `%who`, `%%html`,
`%%writefile`, `obj?` and more; `!cmd` explains that iOS has no shell.
`input()` in a cell asks with a native alert, since the console is not on
screen. Turtle graphics draw in the console.

**Security.** Markdown and HTML outputs are sanitized (DOMPurify) and drawn
in shadow roots. HTML with scripts runs in a sandboxed `srcdoc` frame (an
opaque origin). The self-test found that WebKit gives subframes the
`bridge` message handler, so the host now refuses bridge messages from
frames that are not a page's main frame.

Not done: ipywidgets (a comm protocol), the debugger and breakpoints in
cells, a variable inspector, LaTeX math, and outputs of `.py` cells
surviving a reload. The agent edits a `.ipynb` as its JSON (the prompt
says how); it has no cell tools and can't run cells in the user's kernel.

Evidence: five self-test checks (`notebook_run_all`,
`notebook_input_and_plot`, `notebook_html_sandbox`, `notebook_py_cells`,
`notebook_edit_and_analysis`) cover Run All stopping at an error, values,
streams, `display(HTML)`, `%time`, outputs and ids in the saved file, the
kernel keeping and losing state, `input()` through the alert, a figure
after `import IPython`, the sandbox (a frame's bridge call is refused, it
can't reach the page), `.py` cells and Run still running the script,
diagnostics, cell edits, protected markers, the JSON view and the
template. All 68 checks pass in the iPhone 18 Pro Max simulator
(2026-10-15). Screenshots of the example notebook, rich outputs and a
`.py` with cells were checked in the simulator. Works on the iPhone 14 Pro (2026-10-17);
not tried on an iPad.

## D45: Tracebacks are data, drawn as frames for small screens

2026-10-15 - Accepted

A traceback was text: the worker posted the error message and
`cleanTraceback` removed Pyodide's frames with a regex. In a phone's
console, wrapped monospace text was hard to read. The exception still
exists when the run fails, because Pyodide keeps it in `sys.last_exc`. So
`_terrarium_traceback.py` describes it once, in Python, and the console and
notebooks draw that description.

**The data.** `describe(exc)` returns:
- the classic text (still used to copy, by the agent and by the
  self-test);
- the chain, oldest first, as Python prints it, with "cause" or
  "context" between exceptions;
- for each exception: its type (module-qualified, as Python shows it),
  its message with "Did you mean" and its notes;
- its frames, most recent call last. Each frame has the qualified
  function name, the file and line, the span in characters (the
  traceback's UTF-8 byte columns converted), and source lines around it,
  dedented so they fit a phone. App frames get three lines either side;
  library frames get only their own line.

Python's rules decide which frames are whose. The runtime's own frames
(Pyodide's, `/lib/terrarium`) are dropped, in the text too. Frames in the
project, the console and cells are "app". The standard library and
installed packages are "library", named by module path (`json/decoder.py`).
Repeated frames (recursion) fold into one frame with a count. Very long
stacks keep their first 20 and last 40 frames. A SyntaxError gets its
place with a span, ExceptionGroup members are nested chains, and frames
of the run's uncaught exception carry their index in the post-mortem
debugger's stack.

That replaces the separate filters in the worker, the notebook kernel,
`ui.py` and turtle:
- The worker sends the description of `sys.last_exc` with a failed run's
  `done` message. `mark()` before a run keeps an earlier run's exception
  out.
- Exceptions the runtime catches and shows (a ui callback, a turtle event
  handler) go through `report()` as an "exception" display message, as
  data, without failing the run or the cell.
- Each console input now compiles as `<console-n>` and goes into
  `linecache`, so its frames show their source, including a function
  defined in an earlier input.
- A console line keeps its classic text and gets an optional `trace`.
  Such a line never merges with other output.
- Printed tracebacks (`traceback.print_exc()`, logging) stay text with
  links to their files.

**The view.** The console (`TracebackView.swift`) and notebook error
outputs (`editor/trace.ts`, the same design in HTML) draw an exception as:
- its frames as rows (function name, then `file:line`, which opens the
  line), with the innermost app frame open. An open frame shows its
  source with line numbers. The failing lines are tinted and the span is
  marked. Long lines scroll sideways, starting at the span when it is far
  to the right.
- consecutive library frames folded into one row ("3 library frames").
- the exception at the bottom, where Python puts it and where the console
  is scrolled to: the type in red, then the message in the regular font.
- earlier exceptions of a chain folded to one line, followed by Python's
  sentence for how they connect.

A frame's menu has Show in Editor, Copy Line and, for the run's uncaught
exception, **Inspect Here**: the post-mortem debugger opens at that frame
(`post_mortem(selected)`). In a notebook, `<cell n>` frames jump to that
line of the cell with that count. Project files open in the editor.
`.ipynb` files never get the data: nbformat's `traceback` stays text.

Not done: syntax highlighting of the source lines, local variables in
frames, and parsing printed tracebacks.

Evidence: the self-test's `traceback` check covers the frames, spans,
source and debugger indices. `traceback_data` covers a chain through
`json` (library frames, "cause"), recursion folded with a count, a
SyntaxError's place, "Did you mean", a function from an earlier console
input, and a reported exception that doesn't fail its run. `debugger_inspect_error` covers Inspect Here on the
outer frame, `traceback_link` opens a frame's file through the native
view's code path, and `notebook_run_all` checks the drawn error (its
span, the open frame) and that a tap jumps to the cell's line. All 69
checks pass in the iPhone 18 Pro Max simulator (2026-10-15). Screenshots
of the console were checked in light and dark mode: a library error, a
chain, and a span on a long line scrolled into view. The notebook view was
checked in Chrome. The data was also checked with Python 3.14 and 3.15
in Pyodide under Node. Works on the iPhone 14 Pro (2026-10-17); not tried on an
iPad.

## D46: Markdown files open as a preview, with their source a tap away

2026-10-16 - Accepted (GOALS' Markdown editing moves from [maybe] to [core])

The app already rendered Markdown in notebook cells, the agent's answers
and Show Info, but a `.md` file opened as Python: highlighted as code,
with Run and breakpoints. READMEs and notes are common in projects, and
the agent writes them.

**Two views, as a `.ipynb` has (D44).** A pane shows a Markdown file as
its preview or as its source, remembered per file and pane. A file
with something to read opens as its preview. A file with nothing but
headings (a new note, the Notes template) opens as its source, to write
in. The button where Run is switches between them (Run has nothing to
run in a `.md`), and so do the ⋯ menu and ⇧⌘V. On an iPad the split view
gives a live side-by-side preview: one pane shows the source, the other
the preview. The split view already copies edits into the other pane,
and the preview redraws on every change, including the agent's.

**The source** is CodeMirror with lang-markdown's GFM parser:
- Headings, emphasis, links and inline code are highlighted with the
  theme's colors (D39), and the markup is dimmed.
- Fenced Python is highlighted as Python, and lists continue on Enter.
- It always wraps (it is prose), list items and quotes under their text.
- There is no lint, completion, formatting, Run or breakpoints.

`markdown()` from lang-markdown brings HTML, CSS and JavaScript
parsers along (200 kB), so the language is put together from its parts
(60 kB).

**The preview** (`editor/markdown.ts`) is drawn in the editor page,
which already has marked and DOMPurify (D44). It is drawn in the page
itself, not in a shadow root, so that the web view's find (UIFindInteraction)
sees its text. Its styles are scoped to `.md-preview`. `<style>` and
forms are dropped, along with scripts and handlers as everywhere.
- Each top-level block is tagged with its first source line. Switching
  views keeps the place, and Go to (and the agent's `ide_open`) scrolls
  the preview to the block and flashes it.
- Go to lists the headings (by level).
- Fenced Python is highlighted with the editor's own highlighter.
- Images next to the file are read through the host and shown as data
  URLs before the page swaps, so it doesn't jump. Web images load as
  they do in a browser.
- Links:
  - `#anchor` scrolls to a heading (GitHub's anchors).
  - `docs:` opens the Python docs (D37), and so it does in notebook
    Markdown now too.
  - Web, `mailto:` and `terrarium:` links leave the app.
  - Relative paths resolve against the file's folder, and a leading `/`
    against the root of its location. A file opens in the editor, at
    `#L12` as a line or at `#heading` in another Markdown file. A folder
    opens in the browser, images and PDFs in Quick Look, and a missing
    file gives a toast.

Not done: tapping the preview to edit at that place, toggling task list
checkboxes, math, Mermaid, and the agent opening a file in a chosen view.

Evidence: the self-test's `markdown_preview` covers:
- the preview on open;
- heading anchors, an image next to the file, Python highlighting, a
  table and task lists;
- sanitizing (a `<script>`, an `onerror`) and source lines;
- the headings outline, Go to and anchors in the preview;
- the source starting where the preview was, edits drawn in the
  preview, and the file saved;
- Run doing nothing, and the find bar coming up.

`markdown_links` covers a link to a `.py` at a line, to another `.md`
at a heading, `../`, a `docs:` link, a missing file, and a new note
opening as its source. All 71 checks pass in the iPhone 18 Pro Max
simulator (2026-10-16). Screenshots were checked on iPhone (preview and
source, dark) and iPad (split view, source next to preview, light).
Works on the iPhone 14 Pro (2026-10-17).

## D47: Programs can start processes: each one a Pyodide worker

2026-10-16 - Accepted (was P1; `spikes/processes/`)

`multiprocessing` and `subprocess` work. Every process is a Python
interpreter of its own, a Pyodide worker (D6), so a `Pool` runs on several
cores. This is also the base for local servers and for running several
programs at once.

**The tree** (`src/processes.ts`):
- A ProcessTree belongs to the worker a program runs in, the root (pid
  100). It starts the children that worker's interpreter asks for, from
  two spares that preload the multiprocessing modules (like forkserver's
  preload). Spares are only kept once the program has started a process.
- Every child is a `PyWorker` (`startProcess`, a `process` message in
  `py-worker.js`). It mounts the root's folder through HostFS with `share`,
  so a linked folder's staged copy is shared (D35, D28), and loads the
  parent's packages: Pyodide's by name, PyPI ones with micropip from the
  app's cache.
- Output goes to the console, with no prefix, as children share a
  terminal. `input()` in a child gets end-of-file. The device modules
  follow the root (none in the agent's runs, D40).
- Limits: at most 10 processes alive at once. `os.cpu_count()` is
  `min(hardwareConcurrency, 4)`, because each process costs about 100 MB.
- **Stop** sends SIGINT to the root and then every child. A child that
  hasn't started Python yet just ends (POSIX's default action); the rest
  get SIGKILL after 1.5 s (D11). Children's tracebacks after Stop are
  dropped.
- When the program ends, `program_finished()` does what the interpreter
  does at exit: joins the children that aren't daemons and ends the daemon
  processes. A ui app keeps its processes while it runs. Closing the root
  (the next run) ends whatever is left of the tree.

**Shared state** (`runtime/procs-shared.js`, `procs-worker.js`):
- **Control block:** one SharedArrayBuffer per tree with pids, wait
  statuses, semaphore values and an epoch that every pipe change and exit
  bumps.
- **Pipes:** SharedArrayBuffer rings behind Emscripten file descriptors (a
  small file system mounted at runtime). They count the read and write ends
  per pid, so a dead process's ends go away and EOF/EPIPE work across
  processes.
- **Waits:** they happen in JS, because Emscripten's `poll()` ignores its
  timeout. Stop ends them: SIGINT makes the call return a marker, and
  Python raises KeyboardInterrupt. A pipe read gets EINTR. A Stop wins over
  an event that happened at the same time, so a parent stopped together
  with its children raises KeyboardInterrupt in `join()`, as on POSIX.

**Python** (`_terrarium_procs.py`): the stdlib runs unchanged on a replaced OS
layer.
- **Replaced:** `os.getpid`/`getppid`/`pipe`/`waitpid`/`kill`/`cpu_count`,
  `select.poll`/`select.select`/`selectors.PollSelector`,
  `_multiprocessing.SemLock` (so all the locks, `Event`, `Condition` and
  `Barrier` are the stdlib's), `Value`/`Array` on SharedArrayBuffers,
  `subprocess._fork_exec` (Python programs only; anything else raises
  `FileNotFoundError`).
- **Without threads:** `Queue`, `Pool` and `ProcessPoolExecutor` have no
  feeder or handler threads. A put that doesn't fit is kept and sent while
  the process waits. A pool does its bookkeeping (and runs callbacks)
  whenever the parent waits on it.
- spawn is the only start method; fork raises.
- The patches are applied when a module is first imported. A child
  imports the script again as `__mp_main__`, as spawn does; for that, the
  root now sets `__main__.__file__` for file runs.

Not possible: fork, shared memory, managers, threads (`ThreadPool`).
Functions typed into the console or a notebook cell can't be pickled for
a child; ones from a module in the folder can.

Evidence: five self-test checks:
- `processes`: Pool, Value with a lock, a file a child wrote,
  ProcessPoolExecutor, subprocess;
- `processes_stop`: Stop ends root and children, about 50 ms;
- `processes_packages_and_console`: a PEP 723 package in children, a Pool
  from `>>>`;
- `processes_example`: `Processes.py`, 3.1-3.2x on 4 processes;
- `processes_linked_folder`: children share the staged copy, and their
  files go back.

All 76 checks pass in the iPhone 18 Pro Max simulator (2026-10-16). The
spike's own tests (102 checks, both Pythons, Node and WKWebView) cover the
rest of the API. Works on the iPhone 14 Pro (2026-10-17).

## D48: HostFS's requests go through a fetch relay, not synchronous XHRs

2026-10-17 - Accepted (changes D35's transport; answers Q25's workaround)

WebKit sometimes answers a worker's synchronous XHR about a second late
after the worker slept in `Atomics.wait` (Q25, `spikes/xhr-wait/`). In
the app that hit HostFS (D35) once or twice per run: a file call after
`time.sleep()` or `input()`, and Stop of a program with child
processes (D47).

So a blocked worker no longer makes the request itself:
- **The relay** (`runtime/fetch-relay.js`): one worker per page, started
  with the first Python worker. It never blocks: it waits for requests with
  `Atomics.waitAsync` and makes them with an asynchronous XHR.
- **The client** (`runtime/relay-client.js`): each Python worker has a
  1 MB SharedArrayBuffer shared with the relay. It writes the request
  there and sleeps in `Atomics.wait` until the response is there.
  Requests and responses bigger than the buffer go in pieces.
- **HostFS** sends its calls through it (`createHostFS(py, token,
  fetchSync)`). Without `Atomics.waitAsync` or cross-origin isolation, or
  with `?fs=xhr`, it uses the synchronous XHR as before.

Costs (iPhone 18 Pro simulator, 1000 calls each):
- **Per call:** about 0.18 ms against 0.15 ms for the synchronous XHR. The
  SharedArrayBuffer round trip to the relay is about 0.02 ms. With
  `fetch()` in the relay instead of an XHR it was 0.22-0.30 ms.
- **Through HostFS:** a missing-file `os.stat` costs 0.26-0.30 ms
  against 0.23-0.24 ms; creating and writing a small file 1.4-1.6 ms
  against 1.4-1.5 ms. 4 MB writes and reads take 6-8 ms against 4-5 ms
  (the pieces).
- **After a sleep:** the first call after `time.sleep(2)` took 1-3 ms in
  every one of over 100 samples. With the synchronous XHR, 9 of 36 took
  1001-1003 ms.

Evidence: the self-test's new `files_after_sleep` check (four calls
right after `time.sleep(2)`, and 3 MB through the relay both ways) fails
with `?fs=xhr` and passes with the relay. `processes_stop` stops in
about 50 ms. All 77 checks pass in the iPhone 18 Pro simulator. Works
on the iPhone 14 Pro (2026-10-17).

Still synchronous XHRs: HTTP from Python programs (D25: urllib through
pyodide-http, requests, `open_url`) to `/__http`. They could go
through the relay too.

Update 2026-10-17: they do. A program's synchronous XHR to `/__http` never
opens; `py-worker.js` sends it through the relay and answers the XHR's
getters (status, headers, `response` for each `responseType`, the final
URL), its events and its timeout from the relay's response. The `http`
self-test check covers it after a `time.sleep()`.

## D49: Recursion through C code: warmed-up interpreters, and the crash as a RecursionError

2026-10-17 - Accepted (answers Q14)

CPython's stack check can't catch a worker's native stack overflow
(D16). It measures the linear (Emscripten) stack, and the linear stack a C
call uses has nothing to do with the native stack it uses: at the overflow,
cases had used 0.9-234 KB of it, while `import pandas` uses 96 KB without
any trouble. A smaller stack protection
(`PyUnstable_ThreadState_SetStackProtection`) would break normal programs
and still miss most crashes. In async runs it doesn't even apply: Pyodide
gives each JSPI task its own thread state with the default limits.

What the app does instead:
- **Warm-up:** every new worker runs `_terrarium_warmup.py` (about 20 ms in
  the simulator) before it waits as a spare. It runs the usual paths
  through C code (`lru_cache`, `map()`, `__repr__`, `json`, `==`, `yield
  from`) a few hundred times, so JSC compiles them with its optimizing
  tier, whose native frames are much smaller. Recursion through them gets
  1.5-6 times deeper before the crash: `@lru_cache` recursion 79 -> 265,
  `map()` 114 -> 372, `json.loads` 187 -> 1178. Paths it doesn't run don't
  improve. `?warm=0` turns it off.
- **The crash as a traceback:** when Pyodide fails, the worker walks the
  Python stacks of all thread states with the C API (Pyodide's own dump
  shows the main thread state, not the program's task) and sends the
  deepest one with the crash. The page shows it as `RecursionError:
  maximum recursion depth exceeded (Python ran out of stack space and was
  restarted)`, with the program's frames and the repeated one folded
  (`trace.ts`, `crashTrace`). The program can't catch it; the run counts as
  crashed and the next one gets a new interpreter.
- **Plain Python recursion** never touches the native stack (100,000
  levels work), so `sys.setrecursionlimit()` stays as it is.

The real fix is upstream: CPython counting C recursion on Emscripten as
well as the stack pointer, a native-stack check in Pyodide, or bigger
worker stacks in WebKit.

Evidence: `spikes/native-stack/` (simulator; its worker has the device's
512 KB stack). The `crash_recovery` self-test check runs a deep `repr` and
`@lru_cache` recursion 5000 deep: both show a RecursionError at the right
line (the recursion got 288 deep, in the simulator and on the iPhone 14
Pro), and the next run works. All 79 checks pass in the iPhone 18 Pro
simulator and on the iPhone 14 Pro (2026-10-17).

## D50: Python's heaps share a memory budget, and the console survives iOS ending the engine

2026-10-17 - Accepted (answers Q15)

iOS ends the web content process at about 1.9 GB on the iPhone 14 Pro
(`spikes/device-perf/`) without a `MemoryError`, and all Python workers
live in the engine page's process.
- **The budget:** the host sets one for all Python heaps together:
  0.12 times the device's memory, 512 MB to 3 GB (680 MB on the 6 GB
  iPhone 14 Pro). There iOS ended the process with the heaps at 925 MB
  (and 1000 MB) but not at 850 MB, with every page written; the spike's
  1.9 GB was a much lighter page. The rest leaves room for the agent and
  bigger analysis. Each worker wraps
  `WebAssembly.Memory.prototype.grow`, and the workers count their pages
  in a SharedArrayBuffer (`python.ts`). A heap that would grow past the
  budget doesn't: Emscripten's `malloc` returns NULL and Python raises
  `MemoryError`. An ended worker's pages no longer count. After a
  `MemoryError`, the console says how much memory Python has.
- **Recovery:** if iOS ends the process anyway, the host reloads the page
  (as before) and gives the new one the console it still has
  (`restoreSession`). A program that was running is marked crashed and
  says why; its dialogs, sensors and a notebook's kernel end. Turtle
  drawings stay.

Not covered: memory outside the heaps (the workers' JavaScript, the
analysis worker, the agent), and terminated workers whose memory WebKit
returns late (`spikes/processes/`).

Evidence: the self-test's `memory_budget` check (a 300 MB budget: a
program fills it in 16 MB pieces, gets `MemoryError` at 256 MB, frees it
and goes on) and `engine_recovery` (the self-test ends the engine's process
through WKWebView's `_killWebContentProcess` while a program runs; the new
page shows the old console and the crashed run, and runs programs). All 79
checks pass in the iPhone 18 Pro simulator and on the iPhone 14 Pro
(2026-10-17). On the phone, the opt-in `memory_full` check (a program
fills the budget, writing every page) got `MemoryError` at 624 MB and
survived with the 680 MB budget; with budgets of 925 MB and more, iOS
ended the process first.

## D51: Ready for the App Store: privacy manifest, consent for the agent, store builds without test SPI

2026-10-18 - Accepted

What a submission needs is in the repository; `app/appstore/README.md`
lists it, the steps left in App Store Connect and the open risks.
- **Privacy:** `PrivacyInfo.xcprivacy` declares no tracking and no
  collected data, with the required reasons for UserDefaults and file
  timestamps. The policy is `docs/privacy.md`. Settings has an About
  section with it, support, the version and the acknowledgements.
- **The agent asks first** (guideline 5.1.2(i)): before the first message
  to a model provider, an alert names the provider and what goes to it
  (messages, files, program output). The answer is kept per provider. The
  agent's intro says the same.
- **Store builds leave out the self-test's SPI:** `SELFTEST_SPI` compiles
  in `_killWebContentProcess` and `UIKeyboardImpl`. Debug builds and
  `run.sh --device` set it. `scripts/archive.sh` does not set it, and it
  checks the binary. The SPI the features use (120 Hz pages, the key bar's
  WKContentView subclass, keyboard traits, programmatic focus) stays. It
  is listed as a review risk with its fallbacks.
- **Export compliance:** `ITSAppUsesNonExemptEncryption` is NO. The app's
  encryption is Apple's (HTTPS, Keychain).
- **Acknowledgements:** the web build writes `licenses.json` from the npm
  packages in the bundle (pages and workers) and `licenses-extra.json`
  (Pyodide, CPython, Emscripten).
- **Shipping:** `make archive` and `make upload` (`app/scripts/archive.sh`,
  `ios/ExportOptions.plist`: App Store Connect, automatic signing, build
  number from the time). `app/scripts/store-screenshots.sh` takes the
  6.9" iPhone and 13" iPad screenshots.

Evidence: a Release archive (2026-10-18) has the manifest,
`licenses.json` and the encryption key. None of the self-test's selectors
are in its binary. Not yet uploaded or reviewed.

## D52: The app is called Terrarium

2026-10-18 - Accepted

The name has to stay clear of "Pythonista" for the store (guidelines 4.1
and 5.2.1). The app is **Terrarium**: a home for a python, and a small
enclosed world where programs grow. The store shows it as "Terrarium – Python IDE with a coding
agent" (name and subtitle). If the name is taken in the store, the
fallback is "Terrarium – Python IDE".
- Everything users see says Terrarium: the display name, the docs (the
  app's modules are under `terrarium/` in the docs tree), the editor theme,
  the agent's prompt, messages from Python, the privacy policy and the
  listing.
- Identifiers follow the name:
  - the bundle ID is `eu.ronacher.Terrarium`;
  - the link scheme is `terrarium://run?path=…` (D38);
  - the OAuth callback scheme is `terrarium-auth`;
  - the Keychain services, the theme id `terrarium` and the agent's entry
    types follow;
  - the Xcode project is `app/ios/Terrarium.xcodeproj` (target, scheme and
    product `Terrarium`).
- Internal names follow: the runtime's Python modules are
  `_terrarium*.py` in `/lib/terrarium`, and the host's headers are
  `X-Terrarium-*`. The same goes for `_terrariumhost`, `TerrariumShell` and
  the other prefixes.

## D53: The bundle ID is `eu.ronacher.pyterrarium`, signed by the paid team

2026-10-18 - Accepted

The app was signed by the free Personal Team (`ZRL6J4P42H`), which cannot
upload to App Store Connect, and automatic signing had registered
`eu.ronacher.Terrarium` to that team. Store builds need the paid Apple
Developer Program team, which may not be able to register an ID that the
personal team holds. The bundle ID is now `eu.ronacher.pyterrarium`
(supersedes D52's bundle ID); the Keychain services and queue labels
follow it. Installs start fresh again; nothing is published yet.

The repository is `mitsuhiko/terrarium`, and the privacy policy and
support URLs in Settings → About and in `app/appstore/metadata.md` point
there.

## D54: The app needs iOS 27

2026-10-18 - Accepted

The deployment target is iOS 27.0 (it was 26.0). On iOS 26, WKWebView
pages from a custom scheme are not cross-origin isolated, whatever the
COOP/COEP headers say, so the engine page cannot share memory with Python's
workers (D9). Every program fails ("The object can not be cloned."), and
`input()`, Stop, `time.sleep`, blocking HTTP and processes all depend on it.
The editor, analysis, docs and files work. Supporting iOS 26 would mean
serving the pages over loopback HTTP instead of `app://`: Safari 26.4
isolates `http://localhost` with the same headers, but WKWebView was not
tried. Not worth it for a first version.

Evidence: the self-test's `environment` step (simulator, iPhone 17 Pro):
`crossOriginIsolated` is false on iOS 26.0 and 26.4 and true on 27.0, and
JSPI is only on 27.0. Safari 26.4 on `http://localhost`: isolated.

## D55: Pages render at WebKit's default rate (no 120 Hz SPI)

2026-10-19 - Accepted

The web views no longer turn off WebKit's
`PreferPageRenderingUpdatesNear60FPSEnabled` through WKPreferences'
`_features` / `_setEnabled:forFeature:` (added before D31, when the whole
IDE was a page). It was the only private API in the features that no other
store app ships (`app/appstore/README.md` lists what Capacitor,
react-native-webview, Blink, a-Shell and Code App do), and a direct call
to private methods that review's scan looks for. Since D31 navigation and
animations are SwiftUI, and the editor scrolls in UIKit, at the display's
rate either way. Only what the editor page paints (typing, the caret,
CodeMirror's updates while scrolling) is now held near 60 fps.
`CADisableMinimumFrameDurationOnPhone` stays for the native views. The
keyboard SPI (programmatic focus, the key bar's content view subclass,
plain traits) stays: other store apps ship the same.

Note on D53 (2026-10-19): there is no second team. `ZRL6J4P42H` itself
became the paid team (Apple Developer Program, individual, renewed
2027-10-20), so the project and `ExportOptions.plist` keep it. Xcode kept
the team's free status cached ("Failed to Use Accounts: App Store Connect
access is required") until the Apple Account was signed out and in again.
The export then signs with Apple Distribution and an App Store profile for
`eu.ronacher.pyterrarium`.

Since it is the same team, the bundle ID is `eu.ronacher.Terrarium` again
(the one D53 replaced; the Keychain services and queue labels follow it).
"Terrarium" is taken as a store name, so the App Store Connect record is
"Terrarium – Python IDE" (D52's fallback) with the subtitle "With a coding
agent"; the name on the Home Screen stays "Terrarium".

## D56: No private keyboard API

2026-10-19 - Accepted

The editor's keyboard uses public API only. The two swizzled WebKit
selectors (D51's review risk) are gone:
- **Plain traits:** `_updateTextInputTraits:` forced no capitalization,
  autocorrection, spell checking or smart punctuation. On iOS 27 WebKit
  derives all of them from CodeMirror's `autocapitalize="off"
  autocorrect="off" spellcheck="false"` (smart quotes and dashes follow
  `autocorrect`).
- **Focus without a tap:** `_elementDidFocus:…` claimed every focus came from
  the user. Now the page asks the host first (`keyboard.take`, through
  `takeFocus` in the editor), the host makes WebKit's content view first
  responder, and then the page focuses; WebKit brings up the keyboard for an
  element focused while its content view is first responder. A tap in the
  page needs neither.

The key bar's runtime subclass of the content view stays: it overrides
only `inputAccessoryView`, and the view is found as the scroll view's
`UITextInput` subview, not by its private class name. `archive.sh` fails if
a private WebKit selector is in the binary.

Evidence (simulator, iOS 27, 2026-10-19): with each patch switched off in
turn, the content view's traits stay none/no/no/no/no without
`_updateTextInputTraits:`; focus from the page alone shows no keyboard
(with or without the patches), and the content view made first responder
before or after the page's focus shows the keyboard with the key bar. The
self-test's `editor_keyboard_from_native` step checks it (iPhone; iPad with
a hardware keyboard).

## D57: No itms-services in the bundle

2026-10-21 - Accepted

App Review rejected 0.1 (build 20261019.1852, reviewed 2026-10-21 on an iPad
Air 11-inch (M3)) under guideline 2.5.2: "the app uses the itms-services URL
scheme to install an app". The app never opens such a URL. The string is in
CPython's `urllib/parse.py` (`uses_netloc`), which Apple's scan flags; it is
the reason for CPython's `--with-app-store-compliance` (always on for
CPython's iOS builds), but Pyodide's Emscripten builds keep it. The bundle
had it in both cores' `python_stdlib.zip` and, as plain text, in the docs'
`library/urllib.parse.html` and `docs.sqlite` (the list of schemes and the
note about this very problem).

- `scripts/fetch-pyodide.sh` removes `'itms-services'` from `uses_netloc` in
  each core's `python_stdlib.zip` (what CPython's compliance patch does), on
  fetch and for cores already in `vendor/`.
- `scripts/build-docs.py` drops the scheme from urllib.parse's list and the
  implementation-detail note, and fails if any page or `docs.sqlite` still
  names it.
- `scripts/archive.sh` fails if the string is in any file of the archived
  app or inside its zips.

The only change for programs: `urljoin` and friends no longer treat
`itms-services:` URLs as having a netloc, as on CPython for iOS. Self-test
passes (simulator, iPhone, 87 steps, 2026-10-21).

## D58: The iPhone Duo: two layouts, and the fold divides the inner screen

2026-10-21 - Accepted

The iPhone Duo (iPhone19,4, iOS 27.1) is a book-style foldable with the
phone idiom. Its simulator profile (Xcode 27.1, `iPhone Duo.simdevicetype`)
has two built-in screens: the outer one 1398x2034 @3x (466x678 pt), the
inner one 2007x2853 @3x (669x951 pt) and landscape by default (951x669 pt).
There is no Info.plist opt-in. What the 27.1 SDK adds for it:
- a `division` reserved region where the screen folds
  (`GeometryProxy.reservedRegions(kind:options:)`, UIKit's
  `UIView.reservedRegions(kind:)`), with margins that interactive content
  should avoid and an `isActive` flag, and an `occlusion` kind;
- the hinge: `onHingeChange` / `UIHingeInteraction` (closed, partially open,
  fully open, and the angle);
- a vertical bar: in some layouts the system puts navigation and toolbar
  items in a bar on the leading or trailing edge
  (`UITraitCollection.verticalBarEdge`, `preferredVerticalBarBehavior`,
  `toolbarVerticalCompressionBehavior`), which adds a safe area inset;
- `UIArrangementViewController` with split and overlay arrangements.

What the app does (the deployment target stays 27.0; all of it is behind
`#available(iOS 27.1, *)` in `Shell/Fold.swift`):
- The layouts follow the size class as before: the outer screen gets the
  iPhone layout, the inner one the iPad layout.
- **The file on screen stays on screen** when the window goes from wide to
  narrow (`AppModel.setWide`): the editor is pushed, and a file in the
  right pane of a split view moves to the first pane, which is the one the
  narrow layout shows. Before, folding (or rotating a Pro Max to portrait,
  or iPad multitasking) landed on the file list.
- **The fold divides.** If a division region crosses the workspace edge to
  edge and leaves at least 280 pt on each side, the docked console takes
  the half past it (side by side for a vertical fold, below for a
  horizontal one). In split view a vertical fold divides the two panes
  instead, until the divider is dragged (`splitRatio` is now optional; a
  double tap puts it back on the fold or in the middle). Flat, the fold is a
  hairline divider; bent (an active region), the gutter covers its margins.
- The hinge's state is kept on the model, so the layout looks again at the
  fold when the hinge moves, even if the view's size doesn't change.
- iPhone orientations now include upside-down portrait, as on iPad (Face ID
  iPhones ignore it).

Not done: the vertical bar is left to the system (no tab bar, so the
automatic compression fits), nothing avoids `occlusion` regions beyond the
safe area, and Python programs can't read the hinge (a `motion`-style
module could).

Evidence: builds against the iOS 27.1 SDK. The self-test's `fold_handoff`
step (wide to narrow with a file in the right pane) passes in the iPhone
18 Pro simulator (iOS 27.0); split view passes in the iPad mini simulator.

Note (2026-10-22, the iPhone Duo simulator, iOS 27.1): the simulator boots
closed (the outer screen). Nothing headless opens it: the hinge slider is
DeviceHub's (Xcode 27's device window), and `simctl`/`devicectl` have no
hinge command (SpringBoard's display tool needs an entitlement).
`devicectl device appResize` moves the app to a resizable display of any
size (no fold there): 951x669 and 669x951 both get the wide layout, so the
inner screen in tabletop (portrait) is wide too. `RESIZE=951x669` in
`run.sh` does that for a run. Opened in DeviceHub, the division region is
where the fold is (the console's divider lands on it), in the view's
coordinates. All 89 self-test checks pass closed and open.

The vertical bar is in use on both screens: on the trailing edge in
portrait, on the leading edge in landscape, with the status bar and the
navigation bar's buttons in it. Our buttons were one custom view (packed
for the iPhone's title), which stays in the horizontal bar, so:
- `TrailingButtons` packs them only without a vertical bar; with one
  (`VerticalBarProbe`, the `verticalBarEdge` trait) they are separate items
  with `axisBehavior(.verticalPreferred)`.
- With a vertical bar there is no title row: the active tab is the title
  (a tap opens Go to, as the title did; the tab strip shows from one tab
  on), the sidebar toggle is ours and in the vertical bar, and the top bar
  goes away.
- Wide, the file sidebar has no agent button: the editor's is the one.

Note (2026-10-22): the system's sidebar toggle was removed only while
there was a vertical bar (`toolbar(removing:)` switched on with it). On
the open Duo it came back and stayed (seen after a UI stress run with
rotations), in a top row of its own next to ours in the vertical bar. Now it is always removed and the toggle
is always ours: in the vertical bar, or at the leading end of the editor's
bar (iPad; checked in the iPad Pro 11-inch simulator, iOS 27.0).

Note (2026-10-23): the open Duo's vertical bar has room to spare, so it
also gets Jump to Definition, Show Info and Settings (still in ⋯ too).
Only plain buttons, one item each, go into the vertical bar: the bordered
Pause and the debugger's `HStack` stayed horizontal, and the system brought
back a top bar for them alone (an empty strip above the tabs while a
program ran). With a vertical bar they are now plain items, and while
debugging the step buttons and Stop take the lookups' place (iPhone Duo
simulator).

Note (2026-10-23): with the bar buttons in the vertical bar, the top
inset (24 pt) only holds the screen's rounded corners, so the workspace
goes up into it and leaves 10 pt (`topLift`). A top row that touches the
window's left or right edge moves its content in by 12 pt
(`clearOfTopCorners`), measured against the simulator's framebuffer mask:
14 pt below the top edge the corner takes 18 pt. A half at the top without
a row (the console on the left) keeps its old top. Checked in the iPhone
Duo simulator with the console on either side; the rotated layout (the
vertical bar on the leading edge, the actions in the right-hand corner)
is not checked: XCTest's rotation doesn't turn that simulator. The closed
Duo's editor does the same (its tab row is the first thing at the top):
checked on the outer screen in landscape, whose top corners are the small
ones on the hinge side.

## D59: The wide workspace's other half shows what the user picks

2026-10-22 - Accepted

The docked console's place in the wide layout (right in landscape, below
otherwise, past the fold on an open iPhone Duo, D58) is now "the other
half". A segmented control in its header picks the console, the agent,
the running ui app or the docs; nothing switches by itself (a run still
brings the half up, whatever it shows). The main half shows the editors or
the app; a swap button moves the app between the halves, and another moves
the other half before the main one (left of it, or above; on the Duo left
of the fold, with the files out of the way). The picks are remembered.

- The agent opens in the half when it shows the agent (no sheet), the docs
  likewise (`help()`, Show Info, the agent's links), and a ui app runs in
  its half instead of over everything. Turtle and plots stay in the console.
- Agent, docs and ui apps have navigation stacks of their own. Inside the
  workspace's stack SwiftUI leaves out their bars and moves their buttons
  into the workspace's bar, from a hosting controller of their own too. So
  the halves keep a slot and report its frame, and `RootView` draws them
  there at the window's top level (`HalfOverlays`), laid out (not offset)
  and clipped: else their backgrounds reach into the vertical bar and
  cover the workspace's buttons. Their bar buttons are
  `axisBehavior(.horizontalOnly)`: the window has one vertical bar, and
  theirs would take it from the workspace.
- An iPad's sidebar in portrait slides over the workspace; while it does,
  the halves' overlays are hidden.
- Only ever one agent and one docs viewer: when the half comes to show
  them (unfolding a Duo whose folded screen had the agent's sheet up,
  showing the half, picking them) their sheet closes (the docs' page moves
  over). Folding opens nothing; the agent button brings the sheet.
- A ui app can still have the whole screen: `ui.run(full_screen=True)`
  asks for it (a game, say; the op protocol's `config` carries
  `full_screen`, which pages ignore: they are always full screen), and the
  user switches with the half's expand button or the close button's menu
  (touch and hold: Full Screen / Show Next to the Code). The switch lasts
  for the run.

Evidence: the self-test's `halves` step (agent and docs in the half, an app
in the half and swapped to the main one, the half first) passes in the iPhone
Duo simulator, open (iOS 27.1) and in a 951x669 window, and is skipped on the
outer screen. Screenshots: iPad mini (portrait, app below), the open Duo
(agent, docs, app right of the fold; console and app left of it).

Note (2026-10-22): on an open iPhone Duo, a full screen app whose half is
set to show apps has a button next to its close button that puts it back in
the half (the menu's Show Next to the Code, one tap away). The halves'
overlays are clipped for touches too (`contentShape`): "No App Running"'s
background took the vertical bar's taps, Run's among them.

Note (2026-10-22): the button is there whenever the window has a vertical
bar and the app is over everything (not only when the hinge has reported
and a half is set to show apps), on every screen of the app but not in its
sheets. If no half shows apps it puts the app in the other half (and shows
the half); the close button's menu does the same on iPad. Tested on the Duo
simulator's outer screen forced to the wide layout (a temporary trait
override), which has a vertical bar.

## D60: Reliability: transitions can't lose views or dialogs, and the app watches itself

2026-10-22 - Accepted

A stress run on the iPhone Duo simulator (`app/uitests/`, XCUITest with
real touches) and the self-test found three ways the UI "locked up":
- **The editor went blank** with its tabs showing (open Duo): its web view
  was in no window. A pane's web view moves between SwiftUI containers;
  while two existed for a moment, an update of the one going away took it
  back and left with it. Now it always goes to the newest container in a
  window (`WebViewSlot`), and an audit once a second puts back a web view
  that isn't in its place (and logs it).
- **Dialogs that never went away**: UIKit ignores `present` on a controller
  that is coming or going and `dismiss` while one is still coming up. A
  program's dialog answered or stopped right after it appeared stayed up
  and took every touch; the self-test left an alert and a sheet behind
  that way. `Modal` waits for transitions and cancels presentations
  dismissed before they happened; every UIKit presentation uses it.
- **A blank outer screen** after folding with those stray dialogs up: the
  app was idle but drew nothing and took no touches; a relaunch was fine.
  Not reproduced without them (folding can't be scripted).

What stays, to keep it that way:
- Diagnostics (all builds): a watchdog logs main-thread hangs over 250 ms
  while the app is active; the web view audit. Category `Diagnostics`.
- The self-test reports each step's hangs and fails a step that leaves
  anything presented.
- `app/uitests/run.sh`: seeded monkey and transition scenarios, with
  checks after each step (responsive, an editor with the tabs, taps land)
  and the app's Diagnostics log collected.

Evidence (simulators): the self-test passes on the open Duo (89 checks)
with no stray modals; the monkey ran 150-400 steps on the open and closed
Duo and the iPad mini (iOS 27.0) without a lost editor or a hang over
0.7 s. The blank editor was seen once and never reproduced on purpose
(the trigger is likely a fold or a rotation, which the simulators can't
script), so the fix is not proven by a repro.

Note (2026-10-22): on the closed Duo, `editor_keyboard_from_native` failed
(also before the changes above): the keyboard came up with prose traits or
without the key bar. Each editor page reports its own focus
(`keyboard.mode`), and the two panes' reports interleave: the other pane's
editor losing focus after this one took it switched the key bar off. A
"plain" from a page that doesn't have the keyboard is now ignored; the
step passes 6 of 6 times (failed about half before), and the editor page
keeps a short focus timeline that the step prints when it fails.

## D61: Wide layouts have one top row, a navigator sidebar and one way to the other half

2026-10-23 - Accepted

The wide layouts (iPad, an open iPhone Duo, a Pro Max in landscape) had a
title row and a tab row, two sidebar toggles at times, two agent buttons
(the bar's and the half's picker), and on a short window three squeezed
columns. Now:

- **One top row, no navigation bar** (`TopRow.swift`): `[files] [tabs]
  … [split] | [console agent app docs] [⋯] [Run]`, 44 pt. The active tab is
  the title (a tap opens the outline, ⌘⇧O); a problem count on it opens the
  problems; run state is the tab's dot and Run (Stop, Continue), Pause and
  the debugger's buttons sit before ⋯ while a program runs. The actions
  stay in the workspace's top-right corner: above the other half when it
  is on the right, else at the end of the last pane's row (or a row of
  their own when the main half shows the app).
- **The other half's icons** replace the half's segmented picker, the
  `sidebar.right` toggle and the bar's agent button: a tap shows the half on
  that, a tap on the shown one hides it; the agent's icon pulses while it
  works, also with the half hidden. The agent (⌘⇧A, the ⋯ menu) and the
  docs (⌘⇧0, help(), links) always open in the half; their sheets are only
  for the narrow layout. The half's header is gone (the console gains
  40 pt) except where it carries the corner; moving the half and swapping
  the app are in the icons' long-press menu and ⋯ → Layout.
- **The sidebar is a navigator** (`Navigator.swift`): Files, Outline (the
  Go to list, following the edits and marking the symbol with the cursor;
  the filter takes `:line`), Find (in folder) and Problems. A pick closes
  it when it is over the code. iPhone keeps the sheets.
- **Never three squeezed columns**: when the files (320 pt), an editor of
  about 60 columns and the other half next to it don't fit, the sidebar
  slides over the code (dimmed, a tap beside it closes it) and starts
  closed. The columns are ours now, not a NavigationSplitView: on an iPhone
  in landscape its hidden sidebar kept its room (a blank strip), and its
  own toggle came and went (the double toggle).
- **The divider between the halves** can be dragged; the share is
  remembered (`halves.ratio`), a double tap or ⋯ → Layout resets it (on the
  Duo back to the fold).
- The editor scrolls under the home indicator (the page pads its end by the
  inset); its background fills the side insets in landscape.

The open questions, decided:
1. **The Duo's vertical bar keeps ⋯, Run and the files toggle** (it costs no
   height and the system puts it there anyway, D58); the tab row and the
   half's icons are as everywhere else.
2. **Find and Problems are in the navigator** with Outline: the same lists
   as the sheets, which stay for iPhone.
3. **The narrow iPhone layout stays as it is** (title row, agent, ⋯, Run):
   393 pt can't fit tabs and the actions, and the bar works there.
4. **iPad windowed mode**: the row's first item and the navigator's picker
   use `containerCornerOffset(.leading, sizeToFit:)`, which moves them
   clear of the window's controls (and does nothing otherwise). Not seen in
   a windowed simulator yet.

Hiding the row while typing: not done; with one row the keyboard leaves
the editor enough room on the iPads and the Pro Max in the simulator.

Also found and fixed on the way: a moved half's slot frame could be lost
(the old slot's late update took it back, then cleared it; the self-test's
`halves` step on the iPad mini), and an editor focused from code didn't
always report its focus (no key bar, iPad).

Evidence (simulators): the self-test passes on the closed iPhone Duo (89
checks); on the iPad mini (iOS 27.0) all but `keybar_only_with_software_keyboard`,
which failed before these changes too, and `help_opens_docs`, which fails now
and then on both (order-dependent). `app/uitests` scenarios (13 transitions)
pass on the iPad mini; the monkey ran on the iPad mini and the Pro Max in
landscape. Screenshots: Pro Max (both orientations), iPad mini, iPad Pro 11,
the closed Duo. Open: the open Duo (its vertical bar with the new row) is
not checked, folding can't be scripted.

Note (2026-10-23): the open Duo's sidebar came up in several ways: as a
column or sliding over, depending on the rotation, whether the other half
was beside the code and the font size, and its files laid out for a
vertical bar of their own. Now:
- **On a phone the sidebar always slides over** (`sidebarSlidesOver`: the
  open Duo, a Pro Max in landscape); iPads keep the rule above. It starts
  closed, and asking for a half (its icons, the agent, the docs, Run)
  closes it.
- **A half past the sidebar stays** (`sidebarCovers`): on the open Duo the
  other screen keeps its agent, docs or app, isn't dimmed and takes its
  own taps; the dimming covers the code only. Halves under the sidebar are
  hidden as before.
- **The sidebar's files have no NavigationStack.** A navigation controller
  in the sidebar added the window's vertical bar inset (84 pt) at the
  sidebar's trailing edge, far from the bar: the list was narrower than
  the sidebar, and a pushed folder's back button sat alone in that strip.
  Neither `axisBehavior` nor ignoring the safe area helps, and
  `preferredVerticalBarBehavior` is per window. The files are now a stack
  of our own over `route` with a header like the other panes' (back, title,
  ⋯, new file) and a search field; iPhone keeps its navigation stack.

Evidence (the iPhone Duo simulator, open in DeviceHub, landscape): the
sidebar's list fills it (cells 12..328 of 340 pt), folders and the Trash
push and pop, the docs half stays beside it; the new header in the iPad
Pro 11-inch simulator (iOS 27.0). The self-test (`--reset`) passes 87 of
89 open, the same two (`help_opens_docs`, `halves`) failing before these
changes; both pass alone. Not seen: the open Duo in portrait (XCUIDevice
doesn't turn the inner screen).

Note (2026-10-24), two regressions found retaking the store screenshots:
- **The editor scrolls past its end again.** The CSS rule that kept the
  text's end above the home indicator replaced the theme's 40vh bottom
  padding, so a short file hardly scrolled and a paused line in its lower
  part stayed under the console (bisected to this decision's commit). The
  padding is `40vh` plus the inset now, in the theme. Self-test:
  `debugger_reveals_paused_line`.
- **An iPad's sidebar starts open where it fits.** Its first decision
  (`sidebarSlidesOver`, before the workspace's layout) assumed the other
  half beside the code, so a portrait iPad started with the sidebar
  closed. Until the layout says, the window's shape decides
  (`panelSideBySide`).
- **The other half keeps its frame when it moves at launch.** Moving the
  docs half to the left in the first render made two slots at once, the
  short-lived one newer; when it went it cleared the frame, and the half
  stayed blank (the open Duo, no saved halves). All slots on screen are
  kept now (`liveHalfSlots`): the newest has the place, and when it goes
  the place goes back to one still there.
- **The console half isn't dimmed by the sliding sidebar.** Only the
  agent, docs and app reported their half's frame, so with the console the
  dimming went to the window's edge and took the console's taps. The
  console reports it too.

Evidence: the iPhone Duo simulator (iOS 27.1, open in DeviceHub,
landscape), the iPhone 18 Pro Max and iPad Pro 13-inch (M5) simulators
(iOS 27.0). The self-test (`--reset`) passes on the iPhone, with the
known flaky steps (`help_opens_docs`, `editor_keyboard_from_native`)
failing now and then; on the iPad `keybar_only_with_software_keyboard`
fails, as it does without these changes.

## D62: Narrow layouts show Go to, Find and Problems instead of a title

2026-10-23 - Accepted

On a portrait iPhone the bar had the file name (a tap opened Go to) with a
status line under it, and the agent, ⋯ and Run. Outline, search and
problems were only in ⋯, so nothing on the screen said they exist; the
problem count under the title was drawn as a bare icon, away from the
name. The closed iPhone Duo had only the agent, ⋯ and Run (no title at
all), the open Duo the lookups, Settings and the sidebar (D58, D61).

Now every narrow layout (iPhone in portrait, the closed Duo) has the same
buttons: **Go to, Find and Problems**, the wide sidebar's panes (D61) as
sheets, with its symbols, then the agent, ⋯ and Run. On iPhone the three
sit in a group after Back, on the closed Duo in the vertical bar. Find is
the file's (CodeMirror's panel, or the preview's find bar); a long press
offers Find in Folder. Problems is red or orange while there are any and
disabled otherwise.

There is no title: the **active tab is the title** as on the closed Duo
(D58) and the wide layouts: it has the chevron, a tap opens Go to, and the
problem count sits on it. The tab strip shows whenever a file is open, not
only from two tabs. The status line goes: run state is the tab's dot and
Run, the debugger's state the console bar and the editor's marked line,
read-only the tab's lock. Jump to Definition, Show Info and Settings stay
in ⋯ and the selection menu: a phone's bar has room for about seven
buttons at 390 pt.

Evidence (simulator, iOS 27.0 iPhone 18 Pro Max and iOS 27.1 iPhone Duo,
closed): the buttons in both bars; Go to, Find and Problems open the
outline sheet, the find panel and the problems sheet on the Pro Max
(`uitests/run.sh script`); the self-test passes 89 of 89 (Pro Max). Monkey
runs (seeds 7 and 8, 150 steps): clean on the Pro Max; on the closed Duo
"⋯ did not open its menu" now and then, as often without this change. Not seen: the long press, the narrowest
iPhones, a notebook's running cell (it lost its line under the title).

## D63: Run shows the other half on the app or the console

2026-10-24 - Accepted

D59 left the other half on whatever the user had picked: running
`Adventure.py` with the half on the agent, the docs or the app meant a tap
on the console before the game's `input()` could be answered. Now Run
picks for the program (wide layouts only; on iPhone the console comes up
as before):

- A ui app gets the app in the other half, unless a half (the main one
  too) shows it already. Anything else gets the console.
- Which one a program is is only sure once it runs, so Run guesses from
  its source (a line that starts with `import ui` or `from ui import`) and
  switches right away, without the console flashing up first. The guess
  is put right as the run goes: a UI that comes up (`ui` imported
  elsewhere) moves the half to the app; a run guessed to be a ui app that
  waits for `input()` or ends without a UI gets the console, as does an
  app that asks for the whole screen (`full_screen=True`, known once it
  shows), since the console is what's left to see when it closes.
- The user's own picks while the program runs stay; nothing switches back
  when it ends.

This replaces D59's "nothing switches by itself".

Evidence (simulator, iOS 27.0 iPad Pro 13-inch): the `halves` step runs a
plain program with the half on the agent (console), Counter App with it on
the docs (app), a program that imports `ui` through `importlib` with it on
the console (app once the UI shows), one that imports `ui` without an app
(console) and a full screen app (console). The self-test passes 89 of 90;
`keybar_only_with_software_keyboard` fails without this change too. While
writing the test: two runs started in quick succession (the second before
the first's worker is up) can overlap in the session, and the first one's
app shows up during the second; not new, not fixed here.

## Proposed (not yet decided)

(none)

## Open questions

- **Q25:** WebKit sometimes delivers the response of a worker's synchronous XHR to the app's scheme handler late: about 1 s in the app, about 3 s in a bare page (`spikes/xhr-wait/`, simulator). The handler has answered within a millisecond. It follows `Atomics.wait` (a sleeping program), never a busy loop. The app no longer makes synchronous XHRs from Python workers: HostFS and programs' HTTP go through a fetch relay (D48). Open: report it to WebKit (a draft is in `spikes/xhr-wait/README.md`), and whether it happens on a device.

- **Q21:** Provider terms and App Review for subscription sign-ins (Claude Pro/Max, ChatGPT) used from a third-party app.
- **Q2:** Can WebKit evict `app://` web storage? It survives relaunch and reinstall, but `persist()` is denied (`spikes/ios-host/`).
- **Q4:** Should the agent run locally, in the cloud, or both, given background suspension? (Local works and survives a page reload mid-turn, D32. Open: what happens when the app is suspended mid-stream, and whether running while the phone sleeps needs the cloud.)
- **Q6:** Can Python run when triggered from App Intents / Shortcuts while the app is in the background? (Known: a running script is paused while the app is in the background and resumes afterwards, `spikes/device-perf/`.)
- **Q7:** Do Pyodide's packages cover typical teaching material? Does PyPI accept Emscripten wheels? (Pyodide's version numbers now follow CPython: 314.x is 3.14, 315 is in alpha; 357 packages; wheels tagged `pyemscripten_2026_0_wasm32`.)
- **Q8:** JSPI support in Chrome and Firefox (matters for published apps).
- **Q9:** App Review: guideline 2.5.2 (learning-to-code exception), 4.7 (gallery of user apps), 1.2 (user-generated content).
- **Q10:** Model access for learners: hosted gateway, billing, in-app purchase rules.
- **Q13:** File the upstream reports listed in `spikes/jspi-repro/README.md` (CPython UA check, Pyodide lost `SuspendError`, WebKit `Suspending` callable).
- **Q16:** Lock files / reproducible installs: write a lock (e.g. PEP 751 `pylock.toml` or micropip's freeze) per script, and decide whether uv resolves it (linked into the iOS host, or as a service), which needs a 3.14 Pyodide target in uv.
- **Q17:** Type information for third-party packages in ty: feed installed packages (or their stubs) into ty's in-memory file system as `extra-paths`.
- **Q18:** ty in a WebKit worker on larger files: watch for native stack overflows (D16); fall back to running ty on the main thread if needed.
- **Q19:** Debugger: run the overhead benchmark and the debugger self-tests on
  a device. Pause cannot interrupt a program that is suspended in JavaScript
  (JSPI `await`); it stops when Python resumes. Conditional breakpoints and
  hardware-keyboard shortcuts (⌘. / F6-F8) are not built yet.
- **Q20:** iCloud sync between devices: the app's own iCloud Drive container needs the iCloud entitlement (paid developer account). Until then, linked folders (D28) reach iCloud Drive.
