# Fractals from a few rewriting rules (L-systems). Tap the drawing for the
# next one; tap ■ to stop.
#
# An L-system starts with a short string and rewrites every letter by its
# rule, again and again. Then a turtle reads the result: F means "draw a
# step forward", + and - mean "turn", [ and ] save and restore where the
# turtle is (for branches). Change a rule, an angle or the depth and run
# it again!
import colorsys
import math
import turtle

FRACTALS = [
    {"name": "Fern", "axiom": "X", "rules": {"X": "F+[[X]-X]-F[-FX]+X", "F": "FF"}, "angle": 25, "depth": 5,
     "heading": 65},
    {"name": "Koch snowflake", "axiom": "F--F--F", "rules": {"F": "F+F--F+F"}, "angle": 60, "depth": 4},
    {"name": "Dragon curve", "axiom": "FX", "rules": {"X": "X+YF+", "Y": "-FX-Y"}, "angle": 90, "depth": 11},
    {"name": "Sierpinski triangle", "axiom": "F-G-G", "rules": {"F": "F-G+F+G-F", "G": "GG"}, "angle": 120,
     "depth": 5},
    {"name": "Hilbert curve", "axiom": "A", "rules": {"A": "+BF-AFA-FB+", "B": "-AF+BFB+FA-"}, "angle": 90,
     "depth": 5},
    {"name": "Bush", "axiom": "F", "rules": {"F": "FF+[+F-F-F]-[-F+F+F]"}, "angle": 22.5, "depth": 4,
     "heading": 90},
]


def expand(axiom, rules, depth):
    s = axiom
    for _ in range(depth):
        s = "".join(rules.get(ch, ch) for ch in s)
    return s


def trace(commands, angle, heading=0):
    """Walk the commands without drawing: a list of lines, each a list of
    points (a "]" lifts the pen and starts a new line)."""
    x = y = 0.0
    stack = []
    lines = [[(x, y)]]
    for ch in commands:
        if ch in "FG":
            x += math.cos(math.radians(heading))
            y += math.sin(math.radians(heading))
            lines[-1].append((x, y))
        elif ch == "+":
            heading += angle
        elif ch == "-":
            heading -= angle
        elif ch == "[":
            stack.append((x, y, heading))
        elif ch == "]":
            x, y, heading = stack.pop()
            lines.append([(x, y)])
    return [line for line in lines if len(line) > 1]


screen = turtle.Screen()
screen.setup(560, 620)
screen.bgcolor("#10131a")
screen.title("Fractals")
pen = turtle.Turtle(visible=False)
label = turtle.Turtle(visible=False)
label.penup()
label.color("white")
state = {"index": 0, "drawing": False}


def draw(fractal):
    lines = trace(expand(fractal["axiom"], fractal["rules"], fractal["depth"]), fractal["angle"],
                  fractal.get("heading", 0))
    xs = [x for line in lines for x, _ in line]
    ys = [y for line in lines for _, y in line]
    scale = min(480 / (max(xs) - min(xs) or 1), 480 / (max(ys) - min(ys) or 1))
    cx, cy = (max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2
    pen.clear()
    label.clear()
    label.goto(0, -300)
    label.write(f"{fractal['name']} · tap for the next one", align="center", font=("Arial", 18, "bold"))
    pen.width(2)
    steps = sum(len(line) - 1 for line in lines)
    screen.tracer(max(1, steps // 200))  # about 200 frames per drawing, however big it is
    done = 0
    for line in lines:
        pen.penup()
        x, y = line[0]
        pen.goto((x - cx) * scale, (y - cy) * scale + 20)
        pen.pendown()
        for x, y in line[1:]:
            done += 1
            r, g, b = colorsys.hsv_to_rgb(done / steps * 0.8, 0.75, 1.0)  # the hue moves along the drawing
            pen.pencolor(r, g, b)
            pen.goto((x - cx) * scale, (y - cy) * scale + 20)
    screen.update()


def next_fractal(x=None, y=None):
    if state["drawing"]:
        return
    state["drawing"] = True
    try:
        draw(FRACTALS[state["index"] % len(FRACTALS)])
        state["index"] += 1
    finally:
        state["drawing"] = False


next_fractal()
screen.onscreenclick(next_fractal)
turtle.done()
