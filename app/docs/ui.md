# ui — Native apps

The `ui` module builds apps that look and feel like iOS: screens with
navigation bars, lists, buttons, text fields, tabs, sheets and a drawing
canvas. Inside Terrarium they are real SwiftUI views; a program that calls
`ui.run()` opens full screen, and the **×** button on its first screen ends
it (touch and hold it to restart the program).

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

## The model

Components are plain functions that run **once** and return elements.
State lives in **signals**: `count = ui.signal(0)` makes one, `count()` reads
it and `count.set(1)` writes it. Any **function** passed as a property or a
child (a `lambda`, or a signal itself) becomes a live binding: it runs
again when the signals it read change, and updates exactly that spot on
screen. Nothing else is rebuilt, so text fields keep their focus and lists
keep their scroll position.

If you read a signal while building the UI without a lambda, `ui` prints a
hint with the file and line: that spot would never update. `.peek()` reads
a signal on purpose without the hint.

Event handlers (`on_click`, `on_change`, ...) take the event's value or
nothing, can be `async`, and run batched: several changes in one handler
update the screen once.

## State

### ui.signal(value=None)

A value that the UI follows. Call it to read (`count()`), `.set(value)` to
write, `.update(fn)` to change it from its current value, `.peek()` to read
without subscribing.

```python
name = ui.signal("")
ui.TextField(name, placeholder="Name")          # kept in sync both ways
ui.Text(lambda: f"Hello, {name() or 'stranger'}!")
```

### ui.computed(fn)

A value derived from signals, recomputed when they change:
`total = ui.computed(lambda: price() * quantity())`. Read it like a signal.
Also works as a decorator.

### ui.effect(fn)

Run `fn` now and again whenever a signal it read changes, e.g. to save data.
`.dispose()` stops it; it also stops with the component that made it.

### ui.batch(fn=None)

Apply several changes and update once: `with ui.batch(): ...` or
`ui.batch(fn)`. Event handlers are batched already.

### ui.untrack(fn)

Call `fn` without subscribing to the signals it reads.

### ui.store(value=None, **kwargs)

Reactive data: `ui.store([...])` is a reactive list, `ui.store({...})` (or
`ui.store(name="x")`) a reactive dict. Nested dicts and lists become
reactive too, and keys also work as attributes, so `todos[0].done = True`
updates only what shows it.

```python
todos = ui.store([{"title": "Milk", "done": False}])
todos.append({"title": "Eggs", "done": False})
todos[0].done = True
```

### ui.bind(obj, key)

A signal-like view of `obj[key]` for two-way inputs:
`ui.Toggle("Done", value=ui.bind(todo, "done"))`.

### ui.unwrap(value)

Turn store data back into plain dicts and lists, e.g. for `json.dumps`:
`ui.effect(lambda: save(ui.unwrap(todos)))`.

### ui.resource(fetcher, source=None)

Load data asynchronously. `fetcher` may be `async`. With a `source` (a
signal or lambda), it is called with the source's value and runs again when
that changes. Call the resource to read the data; `.loading()` and
`.error()` tell the state, `.refetch()` loads again.

```python
weather = ui.resource(fetch_weather, city)       # fetch_weather(city()) runs when city changes
ui.Show(weather.loading, ui.ProgressView(), fallback=lambda: ui.Text(lambda: weather()))
```

## Lifecycle and timers

### ui.on_mount(fn)

Run `fn` once the current component is on screen.

### ui.on_cleanup(fn)

Run `fn` when the current component (or effect run) goes away.

### ui.interval(seconds, fn)

Call `fn` every `seconds`. It stops with the component that started it, or
with `.cancel()`.

### ui.timeout(seconds, fn)

Call `fn` once after `seconds`; `.cancel()` stops it.

## Control flow

### ui.Show(when, *children, fallback=None)

Show `children` while `when` (a signal or lambda) is true, else `fallback`.
A single function child is built lazily each time the condition becomes
true (and gets the value of `when` if it takes an argument).

### class ui.For(each, render, *, key=None, fallback=None)

Render `render(item)` (or `render(item, index)`, where `index` is a signal)
for each item of `each`: a store list, a signal or a lambda returning a
list. Rows are matched by identity (or `key(item)`), so changes only build
new rows and move the others. `fallback` shows while the list is empty.

```python
ui.Section(ui.For(todos, lambda t: ui.Row(t.title, checked=ui.bind(t, "done"))))
```

## The app

### ui.run(app, *, title=None, theme='auto', tint=None, close_button=True)

Show `app` (a component function or an element) full screen. `theme` is
`"auto"`, `"light"` or `"dark"`; `tint` is the accent color. Running again
replaces the app.

The app's first screen gets a close button (×) on the leading side: a tap
ends the program, touch and hold offers Restart. `close_button=False`
leaves it out, for an app that ends itself with `ui.close()`; a two-finger
swipe down still closes it.

### ui.close()

End the app, like its close button: the program stops. Published web apps
clear the view instead.

```python
ui.run(lambda: ui.Screen("Game", ui.Button("Quit", on_click=ui.close)), close_button=False)
```

### ui.navigation()

The `NavigationStack` around the current component or event handler, to
push screens: `ui.navigation().push(Detail, item)`.

### ui.alert(title, message=None, *, button='OK')

Show an alert; `await` it in an `async` handler.

### ui.confirm(title, message=None, *, ok='OK', cancel='Cancel', destructive=False)

Ask yes or no: `if await ui.confirm("Delete?", destructive=True): ...`.

### ui.prompt(title, message=None, *, value='', placeholder='', ok='OK', cancel='Cancel')

Ask for text; resolves to the text, or None when cancelled.

### ui.choose(title, options, *, message=None, cancel='Cancel')

An action sheet; resolves to the chosen option, or None.

### ui.toast(text, *, seconds=2.0)

A short message that goes away by itself.

## Layout

### ui.VStack(*children, spacing=8, align='stretch', justify=None, **mods)

Children top to bottom. `align`: stretch, leading, center, trailing.

### ui.HStack(*children, spacing=8, align='center', justify=None, wrap=False, **mods)

Children left to right. `align`: top, center, bottom, baseline, stretch.

### ui.ZStack(*children, align='center', **mods)

Children on top of each other, the last one in front.

### ui.Grid(*children, columns=2, min_width=None, spacing=8, **mods)

A grid with a fixed number of `columns`, or as many as fit `min_width`.

### ui.ScrollView(*children, axis='vertical', spacing=8, **mods)

A scrolling area, vertical or horizontal.

### ui.Spacer(size=None, **mods)

Flexible empty space in a stack, or a fixed `size`.

### ui.Divider(**mods)

A thin line.

### ui.Card(*children, spacing=8, **mods)

A rounded box, like a list section without rows.

## Navigation

### ui.Screen(title=None, *children, leading=None, trailing=None, large_title=True, **mods)

A full screen with a navigation bar and scrolling content. `leading` and
`trailing` go into the bar, usually buttons.

### class ui.NavigationStack(root, **mods)

Screens that slide in from the right, with a back button and the edge
swipe. `root` is the first screen (a component function or an element).

#### ui.NavigationStack.push(screen, *args, **kwargs)

Show a new screen: `screen(*args, **kwargs)` for a component function, or an
element.

#### ui.NavigationStack.pop(count=1)

Go back `count` screens (never past the first).

#### ui.NavigationStack.pop_to_root()

Go back to the first screen.

### ui.TabView(*tabs, selected=None, on_change=None, **mods)

Tabs with a tab bar at the bottom. `selected` is the tab index; pass a
signal to keep it in sync.

### ui.Tab(title, *children, icon=None, badge=None, **mods)

One tab of a `TabView`, with an SF Symbol `icon` and an optional `badge`.

### ui.Sheet(*children, open=False, title=None, on_dismiss=None, size='large', **mods)

A card that slides up while `open` is true. Pass a signal: swiping down or
tapping Done sets it to False. `size`: large, medium.

## Lists

### ui.Section(*children, header=None, footer=None, **mods)

A rounded group of rows, like in the Settings app.

### ui.Row(title=None, *children, subtitle=None, detail=None, icon=None, accessory=None, checked=None, on_click=None, on_check=None, on_delete=None, **mods)

A list row for a `Section`. `accessory`: chevron, check, info. `checked`
shows a round check box (tapping it calls `on_check`, or `on_click`).
`on_delete` turns on swipe to delete.

## Content

### ui.Text(text='', *, font='body', bold=False, italic=False, mono=False, lines=None, selectable=False, **mods)

Text. `font`: largeTitle, title, title2, title3, headline, body, callout,
subheadline, footnote, caption. `lines` cuts it off after that many lines.

### ui.Label(text, icon=None, **mods)

An icon followed by text.

### ui.Icon(name, *, size=None, **mods)

An SF Symbol by name (`"star.fill"`, `"trash"`, ...) or an emoji.

### ui.Image(src, *, fit='contain', alt='', **mods)

An image from a URL, a file in the program's folder, bytes, a PIL image or
a matplotlib figure. `fit`: contain, cover, fill.

### ui.ProgressView(value=None, *, label=None, **mods)

A progress bar for `value` between 0 and 1, or a spinner without one.

### ui.Link(text, url, **mods)

A link that opens `url`.

## Inputs

Pass a signal as `value` and an input keeps it in sync both ways; or pass a
plain value and handle `on_change`.

### ui.Button(label=None, on_click=None, *, kind='filled', icon=None, size=None, disabled=False, **mods)

A button. `kind`: filled, tinted, gray, plain, destructive. `size`: small,
large. `on_click` may be `async`.

### ui.TextField(value='', *, placeholder='', label=None, kind='text', on_change=None, on_submit=None, autofocus=False, disabled=False, **mods)

A one-line text input. `kind`: text, password, email, number, decimal,
search, url, tel.

### ui.TextArea(value='', *, placeholder='', rows=4, on_change=None, disabled=False, **mods)

A multi-line text input.

### ui.Toggle(label, value=False, *, on_change=None, disabled=False, **mods)

An on/off switch with a label.

### ui.Slider(value=0.0, *, min=0.0, max=1.0, step=None, label=None, on_change=None, disabled=False, **mods)

A slider from `min` to `max`.

### ui.Stepper(label, value=0, *, min=None, max=None, step=1, on_change=None, **mods)

A label with − and + buttons.

### ui.Picker(options, value=None, *, kind='segmented', label=None, on_change=None, disabled=False, **mods)

Pick one of `options`: a list, a list of `(value, label)` pairs or a dict of
value to label. `kind`: segmented, menu.

### ui.DatePicker(value=None, *, kind='date', label=None, on_change=None, disabled=False, **mods)

Pick a date (`datetime.date`), a time or a datetime. `kind`: date, time,
datetime.

### ui.ColorPicker(value='#007aff', *, label=None, on_change=None, **mods)

Pick a color, as a `"#rrggbb"` string.

## Drawing

### ui.Canvas(draw=None, *, width=300, height=300, on_frame=None, **mods)

A drawing surface of `width` × `height` units, scaled to fit.

`draw(p)` paints with the browser's canvas API in snake_case
(`p.fill_style = "red"`, `p.fill_rect(0, 0, 10, 10)`, `begin_path`,
`move_to`, `line_to`, `arc`, `fill`, `stroke`, `save`, `restore`,
transforms, text) plus shortcuts: `p.clear(color)`,
`p.circle(x, y, r, fill=, stroke=, width=)`, `p.line(x1, y1, x2, y2, color=, width=)`
and `p.text(s, x, y, color=, font=, align=)`. It runs again when the signals
it reads change.

`on_frame(dt)` is called every frame, for animations and games;
`on_pointer_down`, `on_pointer_move` and `on_pointer_up` get an event with
`e.x` and `e.y` in canvas units.

```python
x = ui.signal(150)
ui.Canvas(lambda p: (p.clear("black"), p.circle(x(), 150, 20, fill="gold")),
          on_pointer_move=lambda e: x.set(e.x))
```

## Style

Every element takes layout and style keywords, static or live (a lambda or
a signal):

| Keyword | Value |
|---|---|
| `padding`, `margin` | points, `(vertical, horizontal)` or `(top, right, bottom, left)` |
| `width`, `height`, `min_width`, `max_width`, `min_height`, `max_height` | points, or `"fill"` |
| `flex` | a number: grow along the parent stack |
| `background`, `color`, `tint` | `"#rrggbb"`, a CSS color name, a system color (`red`, `orange`, ..., `gray`) or `primary`, `secondary`, `tint`, `background`, `separator`, `fill` |
| `font_size`, `font_weight` | points; a weight name (`"semibold"`) or number |
| `text_align` | `leading`, `center`, `trailing` |
| `corner_radius`, `opacity`, `shadow` | numbers (`shadow=True` for a default) |
| `border` | a color, or `(width, color)` |
| `hidden`, `disabled`, `accessibility_label` | |

Every element also takes `on_click`, e.g. to make a `Card` tappable.
