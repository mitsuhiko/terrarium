# uikit: the `ui` module, Solid-style

2026-10-13. The standard library for building UI apps in Python: fine-grained
reactivity in the style of SolidJS, replacing D14's re-render model (D26).
Inside the app the elements are native SwiftUI views (D30,
`app/ios/Sources/UIRenderer/`); published web apps draw the same tree with the
HTML renderer in `web/`. This folder is the source of truth;
`scripts/install.sh` copies `ui.py` and the shipped examples into the app.

```python
import ui

def Counter():
    count = ui.signal(0)
    return ui.Screen(
        "Counter",
        ui.Text(lambda: f"{count()} taps", font="largeTitle"),
        ui.Button("Tap me", on_click=lambda: count.update(lambda n: n + 1)),
    )

ui.run(Counter)
```

## The model (one paragraph to learn)

Components are plain functions that run **once** and return elements. State
lives in **signals** (`count = ui.signal(0)`, read with `count()`, write with
`count.set(1)`). Any **function** you pass as a prop or child (a `lambda`, or a
signal itself) becomes a live binding. It re-runs when the signals it read
change, and it updates exactly that one spot on screen. Nothing is
re-rendered or diffed, so text fields keep their focus, scroll positions stay
put, and toggling one row of 1,000 sends one tiny update.

If you read a signal while building the UI without a lambda, `ui` prints a hint
with your file and line. That spot would never update. `.peek()` reads on
purpose without the hint.

## API

| Area | Names |
|---|---|
| State | `signal`, `computed`, `effect`, `batch`, `untrack`, `store` (deep reactive dicts and lists, `todo.done = True`), `bind(store, key)` (two-way), `unwrap` |
| Lifecycle | `on_cleanup`, `on_mount`, `interval`, `timeout` (cancelled with their component), `resource(fetcher, source)` (async data with `.loading()` and `.error()`) |
| Control flow | `Show(when, *children, fallback=)`, `For(each, render, key=, fallback=)` (keyed, minimal moves, `render(item, index)`), any `lambda` child |
| App | `run(app, theme=, tint=, close_button=, full_screen=)`, `close()`, `navigation()`, `await alert/confirm/prompt/choose(...)`, `toast(...)` |
| Layout | `VStack`, `HStack`, `ZStack`, `Grid`, `ScrollView`, `Spacer`, `Divider`, `Card` |
| Navigation | `NavigationStack(root)` with `.push(Screen, *args)` / `.pop()` (and edge swipe), `Screen(title, ..., leading=, trailing=)`, `TabView`/`Tab`, `Sheet(open=signal)` |
| Lists | `Section(header=, footer=)`, `Row(title, subtitle=, detail=, icon=, accessory=, checked=, on_click=, on_delete=)` (swipe to delete) |
| Content | `Text(font=)`, `Label`, `Icon` (SF Symbol names in the app, a built-in set on the web, or emoji), `Image` (URL, project file, bytes, PIL image, matplotlib figure), `ProgressView`, `Link` |
| Inputs | `Button(kind=)`, `TextField`, `TextArea`, `Toggle`, `Slider`, `Stepper`, `Picker` (segmented or menu), `DatePicker` (`datetime.date`), `ColorPicker`. Pass a signal as `value` and it is kept in sync both ways |
| Drawing | `Canvas(draw, width=, height=, on_frame=, on_pointer_down/move/up=)`: the browser's canvas 2D API in snake_case (drawn with Core Graphics in the app), redrawn when signals change. `on_frame(dt)` is a game loop |

Every element accepts `on_click` (e.g. on a `Card`) and `Element.focus()`.
Every element also takes layout and style keywords, static or live. They are
plain values that each renderer translates (SwiftUI modifiers in the app, CSS
on the web):

| Keyword | Value |
|---|---|
| `padding`, `margin` | points, `(vertical, horizontal)` or `(top, right, bottom, left)` |
| `width`, `height`, `min_*`, `max_*` | points, or `"fill"` |
| `flex` | a number: grow along the parent stack |
| `background`, `color`, `tint` | `"#rrggbb"`, `"rgb(...)"`, a CSS name, a system color (`red`, `orange`, ..., `gray`) or a semantic one (`primary`, `secondary`, `tertiary`, `tint`, `background`, `separator`, `fill`) |
| `font_size`, `font_weight` | points; a weight name (`"semibold"`) or number |
| `text_align` | `leading`, `center`, `trailing` |
| `corner_radius`, `opacity`, `shadow` | numbers (`shadow=True` for a default) |
| `border` | a color, or `(width, color)` |
| `hidden`, `disabled`, `accessibility_label` | |

There are no web-only escape hatches (`h()`, `Html`, `css()` were removed,
D30): an app looks the same in the app and on the web.

Event handlers can take the event value or nothing (`lambda: ...` or
`def f(value)`), and can be `async` (dialogs are awaited). Handlers run batched,
inside the component that created them, so `ui.navigation()` works there.

See `examples/`: Counter, Todos (store, For, filters, swipe to delete,
confirm), Todo App (the complete Reminders-style app shipped in the app:
smart lists, search, sorting, due dates, priorities, notes, autosave to
an SQLite database, `todos.db`), Navigation (push, sheet, prompt, toast, `bind`), Settings (every
input), Tabs (tabs, a stack per tab, badge, a stopwatch whose interval belongs
to an effect), Paint (pointer events), Bounce (game loop),
Async Data (`resource`, a spinner, modifiers), Plot (live matplotlib).

## How it works

- `python/ui.py` (one file, so it drops in as the app's `ui.py` and ty can
  still read it as a stub):
  - **Reactive core.** A push-pull graph: a write marks observers dirty, then
    effects pull, so updates are glitch-free and a computed that doesn't
    change stops propagation. Computations own what they create (bindings,
    nested effects, timers, cleanups) and dispose it before re-running.
  - **Element tree.** Elements get ids and are created detached. Once their
    parent is on screen, every change becomes an op. Regions (`Show`, `For`,
    lambda children) own a run of siblings. `For` reconciles by key and moves
    only rows that are off the longest increasing run (LIS).
  - **Flushing.** Ops are batched per event handler, or per event-loop tick
    for timers and async tasks, and go to the page as one message.
- **Renderers.** In the app, `app/ios/Sources/UIRenderer/` mirrors the tree
  as observable SwiftUI nodes (D30). For published apps:
- `web/renderer.js`: `new UIRenderer(root, sendEvent)`, `.render(json)`,
  `.clear()`.
  - It keeps an id → DOM node map and one builder per element type.
  - Animations live here: push/pop, sheets, swipe gestures, segmented control.
  - Inputs echo nothing: Python records the value the page reported, so
    two-way bindings never fight the caret.
  - A new renderer sends `0:resync`, and Python answers with `reset` plus a
    full snapshot. A view can therefore attach late or be re-created, e.g.
    when D23 hides the app view at a breakpoint.
- `web/ui.css`: iOS styling, light and dark mode, safe areas. Same class names
  as before for the app selftest (`.ui-button`, `.ui-text-largeTitle`).

Protocol: Python calls `_uihost.render('{"seq": n, "ops": [...]}')`. The
renderer calls the dispatcher with `("<id>:<event>", json_args)`. Ops are
`mount`, `move`, `unmount`, `set`, `call`, `config`, `dialog`, `toast`,
`frame`, `reset` and `close` (documented at the top of `renderer.js` and of
`UIStore.swift`). Only the worker's existing two `_uihost` functions are used.
A protocol change needs both renderers.

## Running

```sh
./run.sh               # playground: http://127.0.0.1:18770/playground/ (examples, editor, phone frame)
./run.sh --test        # 88 Python tests on the host (fake DOM applies the op stream like renderer.js)
./run.sh --selftest    # tests + 12 browser checks in headless Chrome, JSON (ONLY=<step>, OFFLINE=1)
uv run scripts/selftest_webkit.py "http://127.0.0.1:18770/playground/#selftest"   # same checks in Playwright WebKit
```

The playground uses Pyodide 314.0.7 from `app/vendor/` with a minimal worker
(`playground/worker.js`) that exposes the same `_uihost` module as the app's
`py-worker.js`. Packages such as matplotlib come from the jsDelivr CDN.

## Results (2026-10-13)

Tested in headless Chrome 155 and Playwright WebKit (Safari 26.6 engine), both
on macOS. In the app, the `ui_app` and `ui_todo` selftests pass in WKWebView
(iPhone 17 simulator, iOS 27). The timings below are not from iOS, and
nothing was run on a device.

| Check | Chrome | WebKit (macOS) |
|---|---|---|
| Tap round trip (Counter, 30 taps) | 0.1 ms avg, p95 0.4 ms | 0.23 ms avg, p95 1 ms |
| Python: build and serialize 1,000 rows | not measured | 10-11 ms |
| 1,000 rows: first DOM build (60 KB message) | 4 ms | 7 ms |
| Toggle one row of 1,000 | 1 op, 0.2 ms | 1 op, 1 ms (median of 7) |
| Reverse 1,000 rows (999 moves, nodes reused) | 3 ms | 31-34 ms |
| Canvas game loop (`on_frame`, 8+ balls) | 60 fps | 60 fps |
| Todo App walkthrough (lists, add, check off, detail edit, move, search, delete list, saved JSON) | pass | pass |
| Todos, navigation/sheet/dialogs/edge swipe, every input, tabs/badge/stopwatch, paint, resource (then `h()`/SVG, now Async Data), resync of a second renderer, handler errors + hint, live matplotlib | pass | pass |

Earlier D14 numbers for comparison: 0.24 ms per tap and 23-26 ms for
re-rendering 1,000 rows, since the whole tree was resent and diffed on every
change.

## In the app

`scripts/install.sh` copies `python/ui.py` and the examples the app ships
(Todo App, Paint, Bounce, Navigation, Tabs, Settings, Async Data) into
`app/web`. The app's copies are generated: edit them here. The app side:
- The engine page forwards the op stream to the host, which applies it to the
  native renderer (D30). Events go back through the engine to the worker.
- The app view is shown while a ui app runs, except while the debugger is
  paused. Each time it appears it asks for a full snapshot (`resync`).
- Files the app writes are written back while it idles (within about a
  second, D27), and on close and when the app goes to the background.
- The app's first screen has a close button (×; touch and hold to
  restart). `run(close_button=False)` hides it: the program ends itself
  with `close()`, and a two-finger swipe down still closes it (D43).
- On a wide screen a half of the workspace can show the app next to the
  code (D59); `run(full_screen=True)` asks for the whole screen anyway, and
  the close button's menu (touch and hold) switches between the two.
- App selftests (iPhone 17 simulator, native views): `ui_app` (Counter App),
  `ui_todo` (Todo App: open the Inbox, add a to-do, go back, find it in
  `todos.db` while the app still runs, read it back in a second run) and
  `ui_navigation` (push, prompt dialog, back, sheet with a text field).

## Not covered yet

- On a device: touch gestures (edge swipe, swipe to delete), the software
  keyboard with text fields, IME composition (handled on `compositionend`,
  not tried), safe areas.
- Long lists are not virtualized on the web (1,000 rows are fine; 10,000 not
  measured). The app's lists are lazy SwiftUI `List`s.
- Canvas resends the whole command list on each redraw. Transferring an
  OffscreenCanvas to the worker is the upgrade path for heavy drawing.
- Images from files are sent inline as data URLs; big photos inflate messages.
- Missing components: search bar, pull to refresh, context menus, swipe
  actions other than delete, maps, video (all have native counterparts the
  app could use now). A transition/animation API. Accessibility beyond
  native controls.
- The native renderer has no tests of its own beyond the app's selftests;
  the layout of free content (stacks, `flex`, cards) differs from the web in
  details. `Element.scroll_into_view()` does nothing in the app yet.
- Published apps (D15): the export needs these three files instead of the
  spike's.
