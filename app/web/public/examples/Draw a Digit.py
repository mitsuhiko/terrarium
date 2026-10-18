# Draw a digit and a machine learning model guesses which one it is.
#
# The model (k-nearest neighbours, from scikit-learn) knows 1,797
# handwritten digits of 8 x 8 pixels. Your drawing is cropped and shrunk
# into the same 8 x 8 grid ("what it sees"); then the model finds the ten
# known digits most like it, and they vote. Everything runs on this
# device. Tap × to close it.
import asyncio

import numpy as np
import ui
from PIL import Image, ImageDraw

SIZE = 280  # the drawing area
LINE = 28  # pen width: the digits it knows were written with a thick pen
NEIGHBOURS = 10


def train():
    from sklearn.datasets import load_digits
    from sklearn.model_selection import cross_val_score
    from sklearn.neighbors import KNeighborsClassifier

    digits = load_digits()
    model = KNeighborsClassifier(NEIGHBOURS)
    # Hide a fifth of the digits, learn the rest, test on the hidden ones; five times.
    accuracy = cross_val_score(model, digits.data, digits.target, cv=5).mean()
    model.fit(digits.data, digits.target)
    return model, digits, accuracy


def to_grid(strokes):
    """The drawing like the digits it knows: the digit fills the height of a
    32 x 32 box, centered, and each of the 8 x 8 cells counts its dark
    pixels (0 to 16)."""
    points = [pt for stroke in strokes for pt in stroke]
    xs, ys = [x for x, _ in points], [y for _, y in points]
    left, top = min(xs) - LINE / 2, min(ys) - LINE / 2
    side = max(max(xs) - left, max(ys) - top) + LINE / 2
    # Draw big, centered in a square around the digit, then shrink.
    big = 256
    scale = big / side
    dx = (side - (max(xs) - min(xs) + LINE)) / 2 * scale
    dy = (side - (max(ys) - min(ys) + LINE)) / 2 * scale
    image = Image.new("L", (big, big), 0)
    pen = ImageDraw.Draw(image)
    width = max(1, round(LINE * scale))
    for stroke in strokes:
        pts = [((x - left) * scale + dx, (y - top) * scale + dy) for x, y in stroke]
        if len(pts) > 1:
            pen.line(pts, fill=255, width=width, joint="curve")
        for x, y in (pts[0], pts[-1]):
            pen.ellipse((x - width / 2, y - width / 2, x + width / 2, y + width / 2), fill=255)
    pixels = np.asarray(image.resize((32, 32), Image.Resampling.BOX)) > 96
    return pixels.reshape(8, 4, 8, 4).sum(axis=(1, 3)).astype(float)


def pixels(cells, size):
    """A drawing function for an 8 x 8 grid of 0-16 values."""
    cell = size / 8

    def draw(p):
        p.clear("#111")
        if cells is None:
            return
        for y in range(8):
            for x in range(8):
                if cells[y][x]:
                    level = int(cells[y][x] / 16 * 255)
                    p.fill_style = f"rgb({level}, {level}, {level})"
                    p.fill_rect(x * cell, y * cell, cell, cell)

    return draw


def DrawDigit():
    strokes = ui.store([])
    seen = ui.signal()  # the 8 x 8 grid of the drawing (None: nothing drawn)
    votes = ui.signal([])  # (digit, votes), most votes first
    nearest = ui.signal([])  # (8 x 8 grid, digit) of the closest known digits

    async def load():
        await asyncio.sleep(0.1)  # show the spinner first
        return train()

    model = ui.resource(load)

    def guess():
        trained = model()
        if not strokes or trained is None:
            return
        knn, digits, _ = trained
        cells = to_grid([list(s) for s in strokes])
        _, (indexes,) = knn.kneighbors(cells.reshape(1, -1))
        labels = digits.target[indexes]
        counts = np.bincount(labels, minlength=10)
        with ui.batch():
            seen.set(cells)
            votes.set([(int(d), int(counts[d])) for d in np.argsort(-counts, kind="stable") if counts[d]])
            nearest.set([(digits.images[i], int(digits.target[i])) for i in indexes[:5]])

    def clear():
        with ui.batch():
            strokes.clear()
            seen.set(None)
            votes.set([])
            nearest.set([])

    def draw(p):
        p.clear()
        p.begin_path()
        p.round_rect(0, 0, SIZE, SIZE, 16)
        p.fill_style = "#111"
        p.fill()
        p.line_cap = "round"
        p.line_join = "round"
        p.stroke_style = "white"
        p.line_width = LINE
        for s in strokes:
            p.begin_path()
            p.move_to(*s[0])
            for x, y in s[1:]:
                p.line_to(x, y)
            if len(s) == 1:
                p.line_to(s[0][0] + 0.1, s[0][1])
            p.stroke()
        if not strokes:
            p.text("Draw a digit here", SIZE / 2, SIZE / 2 + 6, color="#666", font="18px system-ui", align="center")

    def result():
        if model.loading():
            return ui.HStack(ui.ProgressView(), ui.Text("Loading 1,797 digits…", color="secondary"))
        if model.error():
            return ui.Text(f"Couldn't load the model: {model.error()}", color="red")
        trained = model()
        if trained is None:
            return ui.Text("")
        if not votes():
            return ui.Text(f"Ready. It recognizes {trained[2]:.0%} of the digits it knows when they're hidden "
                           "from it. Draw one big digit, then lift your finger.", color="secondary")
        (top, count), *others = votes()
        return ui.VStack(
            ui.HStack(
                ui.Text(str(top), font_size=72, font_weight="bold", width=64, text_align="center"),
                ui.VStack(
                    ui.Text(f"{count} of {NEIGHBOURS} votes", font="headline"),
                    ui.Text(", ".join(f"{d}: {c}" for d, c in others) or "unanimous", color="secondary"),
                    flex=1,
                ),
                ui.VStack(
                    ui.Canvas(pixels(seen(), 64), width=64, height=64, corner_radius=6),
                    ui.Text("what it sees", font="caption", color="secondary"),
                    spacing=4,
                    width=80,
                ),
                spacing=12,
            ),
            ui.Text("The closest digits it knows", font="subheadline", color="secondary"),
            ui.HStack(*[
                ui.VStack(ui.Canvas(pixels(image, 48), width=48, height=48, corner_radius=4),
                          ui.Text(str(digit), font="caption", text_align="center"), spacing=2)
                for image, digit in nearest()
            ], spacing=10),
        )

    return ui.Screen(
        "Draw a Digit",
        ui.Canvas(
            draw, width=SIZE, height=SIZE,
            on_pointer_down=lambda e: strokes.append([(e.x, e.y)]),
            on_pointer_move=lambda e: e.buttons and strokes and strokes[-1].append((e.x, e.y)),
            on_pointer_up=lambda e: guess(),
        ),
        ui.Card(lambda: result()),
        trailing=ui.Button("Clear", on_click=clear, disabled=lambda: len(strokes) == 0),
    )


ui.run(DrawDigit)
