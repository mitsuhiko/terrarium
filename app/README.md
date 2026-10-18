# Pyslopnista app

The actual app (not a spike): a Pythonista-style Python IDE for iPhone and
iPad. A native SwiftUI app (D31); Python runs in Pyodide workers (D2, D6) in a
web view without UI, the editor is CodeMirror in a web view per pane, and ui
apps are native views (D30).

## Features (first version)

- **Files**: projects live in the app's Documents folder, which also shows up
  in the Files app ("On My iPhone"). Create, rename, duplicate and delete files
  and folders (native dialogs). Examples are copied into `Examples/` on first
  launch.
- **File management** (D41): delete goes to a Trash (at the bottom of the
  file list; restore or delete for good, emptied after 30 days); drag a
  row onto a folder or use Move… to move it; images, PDFs, audio and
  documents open in Quick Look; Share… sends any file to other apps;
  favorites pin files and folders at the top; New File offers templates
  (script, app, turtle, plot, dialogs, PEP 723, notes, and your own files
  in `Templates`).
- **Linked folders** (D28): "Open Folder…" (⋯ menu, or under Locations at the
  top level) adds a folder from iCloud Drive, another app (e.g. Working Copy),
  a file provider or a drive. It works like a folder in Documents: edit and
  run. A program runs on a local copy, and what it changes goes back with
  file coordination as it goes (D35). Files that are only in iCloud are
  downloaded when opened.
  Swipe a location to remove it (its files stay).
- **Editor**: CodeMirror 6 with Python highlighting, autocompletion, auto-indent,
  bracket closing, search, undo history per file, soft wrapping with hanging
  indent, light/dark themes. Saves automatically. A row of extra keys sits above
  the keyboard (indent/dedent, brackets and quotes with the cursor placed
  inside, operators, undo/redo, comment), also for the console's `>>>` and
  `input()` fields. It shows only with the software keyboard (not with a
  hardware keyboard, or after hiding the keyboard on iPad).
- **Code intelligence** (ruff + ty as WebAssembly in their own worker):
  wavy underlines for real mistakes (ruff's default rules + bugbear, ty's type
  checks), a problem bar above the keyboard that shows the problem at the
  cursor with its quick fixes (touch has no hover), a problem count badge,
  ty-powered completions, and "Format Code" (ruff format) in the ⋯ menu.
  Imports that Pyodide can install by itself are not flagged.
- **Dependencies**: a PEP 723 block (`# /// script` … `dependencies = [...]`),
  the format `uv run` uses, or `pyproject.toml` in the folder. They are
  installed with micropip before the program runs; `requires-python` is
  checked. An unresolved import offers "Add “x” to dependencies", which writes
  the block. PyPI goes through the host's cache (offline after the first
  install).
- **Python versions** (D37): Python 3.14 (the default) and a 3.15 preview
  (3.15.0rc1; few compiled packages, no matplotlib or pandas) are
  bundled. A program runs on what its `requires-python` and a
  `.python-version` in its folder (or above) ask for, like with `uv run`,
  else on the default from Settings. The ⋯ menu shows the file's version
  and pins its folder (writes `.python-version`); the console's run header
  shows it. ty and ruff check each file against its version.
- **Python documentation** (D37): the official docs of both versions, on
  the device. The viewer has search, back/forward and a version switch;
  it opens from the ⋯ menus or ⌘⇧0, from Show Info ("Open
  Documentation" for standard library names), from `help(x)` in Python
  (standard library objects; the rest stays pydoc's text) and from
  `docs:` links in the agent's answers.
- **Device modules** (D40): Pythonista's `clipboard`, `console`, `dialogs`,
  `keychain`, `notification`, `photos`, `location`, `motion`, `sound`,
  `speech`, `contacts` and `reminders`, plus `haptics`; `webbrowser.open()`
  opens links. Dialogs block until answered; images are PIL images;
  permissions are asked on first use. Not available in the agent's runs.
  Examples: `Device Tour.py`, and the apps `Photo Booth.py`, `Level.py`
  and `Birthdays.py`.
- **Docs for the app's modules** (D42): `ui`, turtle in the app and the
  device modules have pages in the docs viewer next to the Python docs
  (sources in `docs/*.md`), found by its search, `help()`, Show Info and
  the agent's `docs_search`.
- **Home Screen icons** (D38): "Add to Home Screen…" (⋯ menu, or a `.py`
  file's context menu) explains how to make a shortcut with the app's "Run
  Python Program" action in the Shortcuts app and add it to the Home
  Screen; tapping it opens the app and runs the program (a ui app full
  screen). `pyslopnista://run?path=<path>` links do the same.
- **Title bar** (iPhone): the file name without ".py", cut in the middle
  when long; Run sits in one group with the agent and ⋯ buttons.
- **Tabs and split view**:
  - Every pane has tabs; opening a file adds a tab after the current one, up
    to 10 per pane (the least recently used one closes).
  - Long-press a tab for Close, Close Others and Open in Split View.
  - On iPad, split view shows two panes with a draggable divider. Each pane
    has its own tabs, and the same file in both panes stays in sync.
  - Tabs come back after a relaunch. On iPhone the tab strip appears once
    two files are open.
- **Go to definition** (ty): "Jump to Definition" in the text selection menu
  (next to Copy/Paste), in the ⋯ menu, on F12 or with ⌘-click. It works across
  the program's folder (sibling modules) and into the standard library and the
  `ui` module, which open as read-only tabs.
- **Getting around**:
  - Tap the file name in the nav bar for an outline of its classes and
    functions with a filter. Typing a number offers "Go to Line N".
  - Find in Folder searches the text files of the current folder.
  - Show Info shows ty's signature and docstring for a name. It's in the
    selection menu and the ⋯ menu, or ⌥-click.
- **Settings** (⌘, or the ⋯ menus): appearance (system, light, dark),
  editor font size, line wrapping, and the editor's color theme
  (Pyslopnista, drawn from the app icon, plus Xcode, GitHub, Solarized and
  One; each light and dark, D39). About shows the version, the privacy
  policy, support and the acknowledgements (D51).
- **Hardware keyboard**:

  | Action | Shortcut |
  |---|---|
  | Run | ⌘R or F5 |
  | Stop | ⌘. |
  | Markdown preview / source | ⌘⇧V |
  | Go to line | ⌘L |
  | Go to symbol | ⌘⇧O |
  | Find in folder | ⌘⇧F |
  | Settings | ⌘, |
  | Python Docs | ⌘⇧0 |
  | Close tab | ⌘W |
  | Split view | ⌘\ |
  | Previous / next tab | ⌘⇧[ / ⌘⇧] |
  | Toggle breakpoint | F9 |
  | Step over | F6 or F10 |
  | Step in | F7 or F11 |
  | Step out | F8 or ⇧F11 |
  | Continue | F5 or ⌃⌘Y |

- **Code fields** (editor, `>>>`, `input()`): no auto-capitalization,
  autocorrection or smart punctuation, enforced natively.
- **HTTP** (D25): `requests`, `urllib`, `httpx` and `pyfetch` work without
  CORS limits. Cross-origin requests from Python go through the host, which
  makes them with `URLSession`; a custom `User-Agent` works too. Blocking
  requests go through the fetch relay, not synchronous XHRs (D48). Example:
  `Web Requests.py`.
- **Run / Stop**: the file's folder is the program's working directory, used
  in place (D35): `open()`, `sqlite3` (with its journal, on the real
  database) and imports of sibling modules work, and what the program writes
  is on disk at once (at the latest when it idles or blocks, within a quarter
  second). Stop raises `KeyboardInterrupt` and kills the program after 1.5 s
  (D11).
- **Console**: Return in `>>>` or `input()` scrolls to the end; streaming output, `input()`, inline matplotlib plots (`plt.show()`), and a `>>>` prompt
  that runs in the program's globals after it finishes (last expression is
  shown, top-level `await` works).
- **Tracebacks** (D45), built for small screens and without Pyodide's
  frames:
  - Frames are rows (function, `file:line`). The innermost frame of your
    own code is open: its source, the failing line tinted and the failing
    span marked.
  - Library frames fold into one row, and recursion shows one frame with
    a count.
  - The exception and its message come last, in the regular font.
    Earlier exceptions of a chain are folded.
  - Tap `file:line` to open the line. A frame's menu has Show in Editor,
    Copy Line and Inspect Here (the debugger at that frame).
  - Notebook error outputs look the same, and their cell frames jump to
    the cell. Tracebacks a program prints itself stay text, with links.
- **Processes** (D47): `multiprocessing` and `subprocess` (Python programs)
  work, and each process is a Pyodide worker of its own, so a `Pool` uses
  several cores.
  - spawn only; pipes, queues, locks, `Value`/`Array`, `Pool` and
    `ProcessPoolExecutor` all work.
  - Children share the program's folder (a linked folder's copy too) and
    load its packages. Their output goes to the console.
  - Stop ends the whole tree. At most 10 processes, and `os.cpu_count()`
    is at most 4.
  - Example: `Processes.py`; docs: `docs/processes.md`.
- **Notebooks** (D44): Jupyter notebooks (`.ipynb`) and `.py` files with
  `# %%` cells.
  - A `.ipynb` shows as cells, with a toolbar (Run All, Restart, Clear,
    the kernel). The cell with the cursor has buttons to make it code or
    Markdown, move it, add a cell and delete it. Markdown renders until you
    tap it. "Show JSON Source" in the ⋯ menu shows the file itself.
  - In a `.py`, each `# %%` line gets ▶ and a count, and its output shows
    below it. Run still runs the whole script.
  - Cells run with ▶, Shift-Return (run and go on) or ⌘-Return in a kernel
    that keeps its variables: the session's interpreter, kept for the
    notebook. Run All (also ▶ in the bar, ⌘R) stops at an error. Restart
    ends the kernel, and so does running another program.
  - Outputs: values (`;` hides them), print, errors, figures without
    `plt.show()`, pandas tables, `display()` with Markdown, HTML and
    images, `clear_output`, display ids. HTML with scripts runs in a
    sandboxed frame. `input()` asks with an alert.
  - An `IPython` module of our own (`IPython.display`, `get_ipython()`)
    and magics: `%pip install`, `%time(it)`, `%run`, `%cd`, `%%html`,
    `%%writefile`, `obj?`, ...
  - A `.ipynb` keeps its outputs, metadata and cell ids, written as
    Jupyter writes it. ruff and ty check the code cells and leave out
    what doesn't apply to cells.
  - New File has a Notebook template; examples: `Notebook.ipynb`,
    `Cells.py`. Docs: `docs/notebooks.md`.
- **Markdown** (D46): a `.md` opens as a preview, or as its source when
  there is nothing to read yet (a new note).
  - The button where Run is (also the ⋯ menu and ⌘⇧V) switches views and
    keeps the place. On iPad, split view shows the source next to a live
    preview.
  - The source is highlighted (fenced Python as Python), wraps, and
    continues lists on Enter.
  - The preview shows images next to the file, Python code highlighted,
    tables and task lists. Find works in it, and Go to lists the headings.
  - Links open other files (`code.py#L12` at a line, `notes.md#heading` at
    a heading), folders in the browser, images and PDFs in Quick Look,
    `docs:` links in the Python docs, and web links outside.
- **Debugger** (D23):
  - Long-press a line number to set a breakpoint. Long-press it again to
    disable or remove it.
  - Run as usual: the program stops there and the editor turns read-only
    with the line highlighted.
  - Step over, in or out from the console header (iPhone) or the nav bar
    (iPad), and Continue from the Run button.
  - The console shows the stack and the variables. Tap a name in the editor
    for its value, and `>>>` runs in the paused function.
  - Pause (in the console header) stops a running program, e.g. an endless
    loop.
  - `breakpoint()` works too.
  - After an error, Inspect opens the same view on the failing line.
  - Breakpoints cost nothing while they are not hit.
- **Turtle graphics** (D29): `import turtle` is CPython's own module, drawn
  on a canvas inline in the console, animated at turtle's speeds. Taps
  (`onclick`, `onscreenclick`, drag and release), hardware keys (`onkey`),
  timers and `textinput`/`numinput` work. A program with handlers keeps
  running until Stop (or `bye()`), even without `done()`. Examples:
  `Turtle.py`, `Catch the Turtle.py`.
- **UI apps**: programs using `import ui` open full screen as native SwiftUI
  views (D30); the × button ends the program, touch and hold restarts it,
  and `ui.run(close_button=False)` with `ui.close()` lets an app own its exit (D43). The module is Solid-style (D26): components run once, and
  signals and lambdas update exactly what changed. It includes navigation,
  tabs, sheets, dialogs, lists, all common inputs and a canvas (see
  `uikit/README.md`). Files the app writes while it runs (e.g. saved data)
  reach the disk right away (D35). `Examples/Todo App.py` is a
  complete Reminders-style app that keeps its data in an SQLite database
  (`todos.db`).
- **Coding agent** (D34, D36): the ✨ button (in the editor and the file
  browser, or ⌘⇧A) opens a conversation about the current project (the
  top-level folder, or a linked folder).
  - **What it can do:** read, write and edit files; ls, find and grep;
    run Python (a fresh interpreter with the folder copied in; written
    files are saved back, plots come back as images); check with ruff and
    ty; format with ruff; search and read the Python docs (D37).
  - **In the IDE** (D36): `ide_*` tools open a file at some lines to show
    you something, close tabs, lint or format what is in the editor
    (undoable), and open the Python docs at a section. They act only for the conversation on screen and don't
    switch away from a file you are typing in. On iPhone the sheet drops
    to half height when the agent opens a file.
  - **Where you are:** your active file, cursor, selection, tabs and a
    failed run reach the agent when they change: with your message, or
    at its next step while it works ("Now in greet.py").
  - **What you see:** tool calls fold out to show their output or diff,
    with a link to the file. IDE tools are one line each. Its edits show
    up in open editors.
  - **Conversations:** several per project (tap the title for the list,
    ✎ for a new one), with running and unread marks; rename and archive.
    Other conversations keep running in the background.
  - **Durable:** conversations are pi-durable on native SQLite (D32), with
    the app's index next to it. A turn the engine was in the middle of
    continues after a crash or relaunch.
  - **Accounts (⋯ → Accounts):**
    - Radius first (sign-in or API key); its models are the default once
      you're signed in, and its model list is fetched from the gateway;
    - subscriptions: Claude Pro/Max, ChatGPT (Codex), Sign in with
      ChatGPT, GitHub Copilot, xAI, Kimi, Meta;
    - OpenRouter;
    - API keys for Anthropic, OpenAI, Google, Mistral, Groq and DeepSeek.
  - **Sign-in** runs pi-ai's own flows in a browser sheet. Credentials stay
    in the Keychain (D33).
  - **Consent:** before the first message to a provider, an alert asks to
    allow sending messages and project data to it, once per provider (D51).
  - Pick the model from ⋯ → Model.
- **Crashes**: a native stack overflow (deep recursion through C code) ends
  the run with a `RecursionError` traceback at the program's frames, and
  the next run gets a fresh interpreter (D16, D49). New interpreters warm up
  first, which makes such recursion 1.5-6 times deeper (`_pyslop_warmup.py`).
- **Memory** (D50): all Python heaps share a budget (0.12 of the device's
  memory, 680 MB on the iPhone 14 Pro); past it a program gets `MemoryError` and the console says
  how much there is. If iOS ends the engine's process anyway, the new page
  gets the console back and the running program is marked crashed.
- **Layouts**: on iPhone, Files → Code/Console; on iPad, a sidebar with the
  editor and console side by side (stacked in portrait).

## Layout

```
app/
  run.sh                  build + run (simulator or --device), --selftest, --reset
  runtimes.json           the bundled Pythons (D37): Pyodide versions, CDN folders, pinned docs archives
  docs/                   the app's own modules' docs (Markdown, D42), rendered into the docs by build-docs.py
  scripts/fetch-pyodide.sh   the Pyodide cores of runtimes.json into vendor/
  scripts/build-docs.py     the docs (uv script): pruned, patched HTML and docs.sqlite (FTS5) into vendor/docs-<python>/
  scripts/build-ty.sh       builds ty's wasm (not on npm) from a pinned ruff commit
  scripts/make-turtle.py    turtle.py from CPython's, with the Tk part swapped (D29)
  scripts/make-icon.py      the app icon: writes ios/icon/*.svg, renders the asset catalog (needs resvg)
  scripts/archive.sh        the App Store archive; --upload sends it to App Store Connect (D51)
  scripts/store-screenshots.sh   App Store screenshots from the 6.9" iPhone and 13" iPad simulators
  appstore/                 the App Store checklist, listing text and review notes (D51)
  vendor/                 Pyodide cores, docs, ty's wasm (gitignored)
  ios/                    the native app: Pyslopnista.xcodeproj (hand-written, D19)
    Sources/App.swift          entry point
    Sources/PrivacyInfo.xcprivacy   the privacy manifest (D51)
    Sources/Assets.xcassets    AppIcon (light, dark, tinted; generated by scripts/make-icon.py)
    Sources/Shell/             the IDE in SwiftUI (D31): AppModel (state and actions), WebHost (web views
                               and their bridge), SessionMirror (the engine's session), RootView,
                               FileBrowserView, EditorViews (panes, tabs, nav bar), ConsoleView,
                               DebugViews, Panels (find, go to, problems, settings), Turtle, SelfTest
    Sources/UIRenderer/        ui apps as SwiftUI views (D30): UIStore (op stream), views, canvas
    Sources/Agent/             the agent's host side (D32, D33): SQLite, Keychain, loopback listener for OAuth,
                               the sign-in browser and prompts (AgentHost)
    Sources/AppSchemeHandler.swift  app:// with COOP/COEP, package cache, streaming HTTP proxy, /__fs (D9, D12, D25, D35)
    Sources/Runtimes.swift     runtimes.json in the bundle (D37)
    Sources/Device/            the device modules' native side (D40): bridge, dialogs, media, sensors, audio, PIM
    Sources/Trash.swift        the Trash and moving files (D41)
    Sources/DocsIndex.swift    search and read the docs index (D37); Shell/DocsView.swift is the viewer
    Sources/FileStore.swift    file operations on Documents and linked folders (D28), staging copies
    Sources/HostFS.swift       programs' file operations on their folder; linked folders' sync back (D35)
    Sources/Locations.swift    linked folders: security-scoped bookmarks
    Sources/KeyboardAccessory.swift, CodeWebView.swift   key bar and selection menu for the editor
    copy-web.sh                build phase: web/dist, the Pyodide cores and the docs into the bundle
    ExportOptions.plist        App Store Connect export (scripts/archive.sh)
  web/                    two pages, Vite + TypeScript, no UI framework (D31)
    engine.html           Python and analysis, never shown (src/engine/: commands, state sync)
    editor.html           one CodeMirror pane (src/editor/; notebook.ts: cells, their widgets and
                          commands; outputs.ts: Markdown, HTML, images, D44; markdown.ts: .md previews, D46)
    public/runtime/       py-worker.js, hostfs.js (the project folder in Pyodide, D35), sab-polyfill.js,
                          fetch-relay.js and relay-client.js (blocking requests without synchronous XHRs, D48),
                          python/_pyslop_warmup.py (deeper recursion through C code, D49),
                          python/_pyslop.py, python/_pyslop_notebook.py (notebook kernels, the IPython
                          shim, magics, D44), python/ui.py (from uikit/), python/_device.py and the
                          device modules (clipboard.py, dialogs.py, photos.py, ..., D40),
                          python/_pyslop_debug.py (debugger), python/turtle.py (generated by
                          scripts/make-turtle.py) + python/_pyslop_turtle.py (its backend)
    public/examples/      seeded into Documents/Examples
    src/                  session (runs, console, debugger), python (worker pool), runtimes (which Python
                          a program runs on, D37), turtle (scenes and events), host (bridge), selftest
                          (runs in the engine, drives the app)
    src/notebook/         .ipynb reading and writing, cell markers, what ruff and ty see, kernel events (D44)
    src/analysis/         ruff + ty worker, client, CodeMirror lint/completions/fixes
    src/debug/            breakpoints, CodeMirror gutter/paused line/inspect
    src/agent/            the coding agent (D34, D36): service (Harness, conversations, state for the host),
                          conversations (the index), tools (project tools), ide (IDE tools and context),
                          docs (docs_search, docs_read, D37),
                          env (the project as an ExecutionEnv), sqlite (bridge adapter), credentials, login
                          (pi-ai's flows; shims/ for node:http and node:crypto), prompt, proxy (fetch via /__http)
```

## Running

From the repository root, `make iphone-sim`, `make ipad-sim`, `make device`
and `make selftest` pick (and boot) a simulator with `scripts/simulator.sh`
and call `run.sh`:

```sh
./run.sh                                  # booted simulator
./run.sh --selftest                       # end-to-end checks in the simulator (JSON)
./run.sh --device                         # on the paired iPhone (unlocked)
./run.sh --device --selftest
SIM=<udid> ./run.sh                       # a specific simulator (e.g. an iPad)
FRAGMENT="open=Examples/Plot.py&run" ./run.sh   # launch hooks: open, bp=<lines>, split=<path>, view=preview|source|notebook, run, cells (Run All Cells), pane, focus, agent[=accounts|conversations], docs=<version>/<ref>, settings, newfile=<dir>, move=<path>, trash
FRAGMENT="selftest&only=debugger" ./run.sh --selftest   # a subset of the checks
```

For the App Store, `make archive` and `make upload` (`scripts/archive.sh`)
build a Release archive without the self-test's private-API hooks
(`SELFTEST_SPI`, D51); `appstore/README.md` has the rest.

The pages can be inspected with Safari's Web Inspector (Develop → Simulator):
"Engine" and one "Editor" per pane.
```

## Status (2026-10-17)

Since D31 the app is native SwiftUI. `./run.sh --selftest` passes all 79
checks in the iPhone 18 Pro simulator, including `crash_recovery` with a
RecursionError traceback (D49), `memory_budget` and `engine_recovery`
(D50, the last check: it ends the engine's process and finishes in the new
page), in the simulator and on the iPhone 14 Pro (2026-10-17). On the
phone, `FRAGMENT="selftest&only=memory_full"` fills the real memory budget
(`&budget=<MB>` tries another). Before that, it passed all 71
checks in the iPhone 18 Pro Max simulator, including `markdown_preview`
and `markdown_links` (D46) (2026-10-16). Before that, it passed all 69
there, including `traceback_data` (D45) (2026-10-15). Before that, it passed all 68 there, including the
five notebook checks (D44) (2026-10-15). Before that, it passed all 62
checks in the iPhone 18 Pro simulator, including `app_docs` and
`device_example_apps` (D42) (2026-10-15). Before that, 59 passed in the
iPhone 18 Pro and iPad Pro 13" simulators, including the
device modules (`device_basics`, `device_dialogs`,
`device_stop_closes_dialog`, `device_pim`, D40) and `file_management`
(D41) (2026-10-15). For the device checks `run.sh` grants the simulator's
permissions and sets its location. Before that, 53 passed in the iPhone
18 Pro simulator, including `launch_shortcuts` (D38).
Before that, all 52 passed in the iPhone 18 Pro and iPad Pro 13" simulators, including the
Python versions and docs checks (`python_versions`, `docs_index`,
`docs_viewer`, `help_opens_docs`, `show_info_docs`, `agent-docs`, D37)
(2026-10-15). Before D37 it passed all 46 checks in the iPhone 18 Pro
simulator, including `agent` (D34),
`project_files_in_place` (D35), `agent-ide` and `agent-conversations` (D36)
(2026-10-15). In the iPhone 17 simulator `turtle_catch_example` fails (also
without D36); before D35, 43 passed there.

In the iPad Pro 13" simulator 43 pass and `keybar_only_with_software_keyboard`
fails (the bar stays after the keyboard's own hide key); it failed the same
way before the agent and D35. Before the agent, all
42 passed in the iPhone 18 Pro and iPad Pro 13" simulators (2026-10-15), and
40 in the iPhone 17 (2026-10-14). The new ones tap the key bar in the `>>>` field
and check that it shows only with the software keyboard. The
self-test runs in the engine page and drives the native views through hooks
(`Shell/SelfTest.swift`): ui apps through the renderer's tree, typing through
UIKit into the native console fields, turtle checks on the native drawing.
The app, with all of the features above, works on the iPhone 14 Pro (2026-10-17).

Before D31: `./run.sh --selftest` passed all 39 checks in the iPhone 17 simulator
(2026-10-13), including the four turtle checks, which also pass in the iPad
Pro 11 simulator. Of the 35 before turtle, 34 passed in the iPad Pro 11
simulator; `stop` failed only because that simulator's
`Examples/Countdown.py` was edited to raise. The 33 checks before D27/D28 passed in both. An earlier set of 19 also passed on the iPhone 14 Pro
(`--device`). The checks are: examples seeded, edit → autosave → run,
`input()`, traceback cleanup, `>>>` console, file write-back, sibling
imports, project files used in place (live writes, outside edits, renames,
no `__pycache__`), inline plot, Stop, UI app, todo app (navigation, typing, saving
into `todos.db` while the app runs, reading it back), linked folder (bookmark,
list, run, write-back, remove), crash recovery, ruff/ty startup,
diagnostics (F401, invalid-argument-type, unresolved-reference), completions,
formatting, Pyodide imports not flagged, add-dependency quick fix + install
from PyPI, cached rerun, requires-python, debugger (breakpoint → evaluate →
assignment → step → continue, Pause + Stop, breakpoint added while running,
Inspect after an error, `breakpoint()`), traceback links, go to definition
(project and stdlib), tabs, split view (iPad), turtle (drawing pixels, a tap
and a key reaching handlers, `bye()`, a timer program until Stop, both
examples, catching the turtle with a tap), HTTP (requests, urllib, httpx,
pyfetch, connection errors), plain keyboard traits in code fields, and typing
into the console fields through UIKit's text input.

On the iPhone 14 Pro: ruff/ty start in 120-140 ms, the first check of a file
takes about 400 ms, completions 44 ms, formatting 57 ms; installing a small
PyPI package and running takes 0.8 s (1.3 s when cached).

## Known gaps

- Processes (D47):
  - No shared memory, no managers, no threads (`ThreadPool`).
  - Functions from the console or a notebook cell can't go to a child.
  - The debugger doesn't follow child processes.

- Notebooks (D44): no interactive widgets (ipywidgets), no debugger,
  breakpoints or variable inspector in cells, no LaTeX math rendering;
  turtle graphics from a cell draw in the console. A `.py`'s cell outputs
  are gone after a relaunch. One kernel at a time (running anything else
  ends it). The agent edits a `.ipynb` as JSON and can't run cells. Not
  tried on an iPad.

- Markdown (D46): no tap-to-edit in the preview, no checkbox toggling, no
  math or diagrams.
- Device modules (D40): no `cb`, `scene`, Pythonista's `ui` API, `appex`,
  `keyboard` or `editor`; only synthesized built-in sound effects. 3.15 has
  no Pillow, so image functions need `raw_data=True` there.
- File management (D41): no multiple selection; SQLite files have no preview.
- Home Screen shortcuts (D38): the user builds the shortcut in the
  Shortcuts app (four steps); programs in linked folders aren't listed
  there.
- Python versions and docs (D37):
  - 3.15's Pyodide has 31 packages; matplotlib, pandas and Pillow are
    missing there.
  - The docs viewer is a sheet, not a tab next to the code on iPad.
  - The editor doesn't flag imports any bundled Python's packages provide,
    even when the file's version lacks the package.
  - The 3.14 docs are 3.14.8's (the runtime is 3.14.2); the 3.15 docs are
    a branch snapshot (the runtime is 3.15.0rc1).
- Agent (D34):
  - It is a sheet, not a panel on iPad.
  - IDE tools can't run a program in the app (`ide_run`, for turtle and
    ui apps, is not built).
  - No per-turn undo.
  - A write to a file you are typing in replaces the editor's text.
  - No teaching mode.

- Stack and memory (D49, D50):
  - Recursion through C code still crashes the interpreter after a few
    hundred levels (plain Python recursion is fine); a program can't catch
    that RecursionError. The fix is upstream.
  - The memory budget is calibrated on one device (the iPhone 14 Pro) and
    only counts the Python heaps, not the rest of the page.
  - When iOS ends the engine's process, a notebook's kernel (its
    variables) and a paused debugger are gone; the console comes back.

- The problem bar is still HTML inside the editor page.
- Turtle screens in the console fit the width but not the console's height.
- HTTP is request/response only: no WebSockets or raw sockets; responses are
  buffered, not streamed.
- No package UI beyond the script block (imports of Pyodide packages
  auto-load; `micropip` works from the console). No lock files yet.
- ty has no type information for installed third-party packages (it only
  knows the standard library); their imports are simply not flagged.
- Turtle: no on-screen keyboard for `onkey` games on a phone, no scrolling
  of canvases bigger than the window.
