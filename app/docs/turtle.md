# turtle — Turtle graphics in the app

`import turtle` is CPython's own turtle module (see the
[turtle reference](../library/turtle.html)); only the window it draws in is
different. Instead of a Tk window, each screen is drawn in the console,
animated at the turtle's speeds.

```python
import turtle

t = turtle.Turtle()
t.speed(0)
for i in range(36):
    t.forward(100)
    t.left(170)

turtle.done()
```

## What works

- **Drawing:** pens, colors, fills, shapes, stamps, text with `write()`,
  `tracer()` and `update()` for fast drawing, `bgcolor()` and `title()`.
- **Taps:** `onclick()`, `onscreenclick()`, `ondrag()` and `onrelease()`
  get the tap's position in turtle coordinates.
- **Keys:** `onkey()` and `onkeypress()` work with a hardware keyboard
  (call `listen()` first).
- **Timers:** `ontimer()` for animations and games.
- **Dialogs:** `textinput()` and `numinput()` ask with a native alert.

## Programs that keep running

A program that sets event handlers or timers keeps running after its last
line, until you tap Stop or it calls `turtle.bye()`, even without
`turtle.done()` or `mainloop()`, so games and drawing apps stay interactive.

## Differences from desktop Python

- There is no on-screen keyboard for `onkey()` on a phone.
- A screen fits the console's width; bigger drawings are scaled down.
- `turtle.Screen().setup()` sizes the drawing area, not a window.
- Saving the canvas as PostScript (`getcanvas().postscript()`) isn't
  available.

Examples: `Turtle.py`, `Turtle Fractals.py` and `Catch the Turtle.py`.
