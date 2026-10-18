# Finger painting on a canvas: pointer events update a store of strokes,
# and the draw function re-runs when they change.
import ui

strokes = ui.store([])
color = ui.signal("#007aff")
width = ui.signal(6)


def draw(p):
    p.clear("white")
    p.line_cap = "round"
    p.line_join = "round"
    for s in strokes:
        pts = s["points"]
        p.stroke_style = s["color"]
        p.line_width = s["width"]
        p.begin_path()
        p.move_to(*pts[0])
        for x, y in pts[1:]:
            p.line_to(x, y)
        p.stroke()


def down(e):
    strokes.append({"color": color(), "width": width(), "points": [(e.x, e.y)]})


def move(e):
    if e.buttons and strokes:
        strokes[-1]["points"].append((e.x, e.y))


def App():
    return ui.Screen(
        "Paint",
        ui.Canvas(draw, width=360, height=360, on_pointer_down=down, on_pointer_move=move, shadow=True),
        ui.Section(
            ui.Picker({"#007aff": "Blue", "#ff3b30": "Red", "#34c759": "Green", "#000000": "Black"}, color),
            ui.Slider(width, min=1, max=30, step=1, label="Width"),
        ),
        trailing=ui.Button("Clear", on_click=strokes.clear, disabled=lambda: len(strokes) == 0),
    )


ui.run(App)
