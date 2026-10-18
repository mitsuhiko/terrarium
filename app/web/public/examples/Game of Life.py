# Conway's Game of Life: cells live, die and are born by three rules.
#
#   A live cell with two or three live neighbours lives on.
#   A dead cell with exactly three live neighbours comes alive.
#   Every other cell dies, or stays dead.
#
# Tap or drag on the grid to draw cells, pick a pattern, and press Play.
# The rules run on the whole grid at once with numpy. Tap × to close it.
import numpy as np
import ui

N = 48  # cells per side; the edges wrap around
SIZE = 360
CELL = SIZE / N

PATTERNS = {
    "Glider": [".O.", "..O", "OOO"],
    "Glider gun": [
        "........................O...........",
        "......................O.O...........",
        "............OO......OO............OO",
        "...........O...O....OO............OO",
        "OO........O.....O...OO..............",
        "OO........O...O.OO....O.O...........",
        "..........O.....O.......O...........",
        "...........O...O....................",
        "............OO......................",
    ],
    "Pulsar": [
        "..OOO...OOO..",
        ".............",
        "O....O.O....O",
        "O....O.O....O",
        "O....O.O....O",
        "..OOO...OOO..",
        ".............",
        "..OOO...OOO..",
        "O....O.O....O",
        "O....O.O....O",
        "O....O.O....O",
        ".............",
        "..OOO...OOO..",
    ],
    "R-pentomino": [".OO", "OO.", ".O."],
    "Spaceships": [".O..O", "O....", "O...O", "OOOO.", ".....", ".....", ".O..O", "O....", "O...O", "OOOO."],
}


def place(pattern):
    """A grid with the pattern in the middle (left, for the gun)."""
    grid = np.zeros((N, N), dtype=bool)
    rows = PATTERNS[pattern]
    top = (N - len(rows)) // 2
    left = 2 if pattern == "Glider gun" else (N - len(rows[0])) // 2
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            grid[top + y, left + x] = ch == "O"
    return grid


def step(grid):
    """One generation: count the eight neighbours of every cell at once."""
    neighbours = sum(
        np.roll(np.roll(grid, dy, axis=0), dx, axis=1)
        for dy in (-1, 0, 1)
        for dx in (-1, 0, 1)
        if (dy, dx) != (0, 0)
    )
    return (neighbours == 3) | (grid & (neighbours == 2))


def Life():
    grid = ui.signal(place("Glider gun"))
    born = ui.signal(np.zeros((N, N), dtype=bool))  # new this generation: drawn brighter
    generation = ui.signal(0)
    running = ui.signal(False)
    speed = ui.signal(12.0)  # generations per second
    pattern = ui.signal("Glider gun")
    painting = {"value": True}

    def advance():
        old = grid.peek()
        new = step(old)
        with ui.batch():
            grid.set(new)
            born.set(new & ~old)
            generation.update(lambda n: n + 1)
        if not new.any():
            running.set(False)

    # While running, step at the chosen speed. The interval belongs to this
    # effect: it is cancelled when running or speed change.
    @ui.effect
    def _():
        if running():
            ui.interval(1 / speed(), advance)

    def reset(cells):
        with ui.batch():
            grid.set(cells)
            born.set(np.zeros((N, N), dtype=bool))
            generation.set(0)

    def cell_at(e):
        x, y = int(e.x // CELL), int(e.y // CELL)
        return (y, x) if 0 <= x < N and 0 <= y < N else None

    def paint(e, first):
        cell = cell_at(e)
        if cell is None:
            return
        cells = grid.peek().copy()
        if first:  # a tap on a live cell erases while dragging
            painting["value"] = not cells[cell]
        cells[cell] = painting["value"]
        grid.set(cells)

    def draw(p):
        cells, new = grid(), born()
        p.clear("#0b1020")
        p.stroke_style = "#151c30"
        p.line_width = 1
        p.begin_path()
        for i in range(1, N):
            p.move_to(i * CELL, 0)
            p.line_to(i * CELL, SIZE)
            p.move_to(0, i * CELL)
            p.line_to(SIZE, i * CELL)
        p.stroke()
        for mask, color in ((cells & ~new, "#30d158"), (new, "#ffd60a")):
            ys, xs = np.nonzero(mask)
            if len(xs):
                p.begin_path()
                for x, y in zip(xs.tolist(), ys.tolist(), strict=True):
                    p.rect(x * CELL + 0.5, y * CELL + 0.5, CELL - 1, CELL - 1)
                p.fill_style = color
                p.fill()

    def choose(name):
        pattern.set(name)
        running.set(False)
        reset(place(name))

    return ui.Screen(
        "Life",
        ui.Canvas(draw, width=SIZE, height=SIZE, corner_radius=12,
                  on_pointer_down=lambda e: paint(e, True), on_pointer_move=lambda e: paint(e, False)),
        ui.HStack(
            ui.Text(lambda: f"Generation {generation()}", font="headline"),
            ui.Spacer(),
            ui.Text(lambda: f"{int(grid().sum())} alive", color="secondary"),
        ),
        ui.HStack(
            ui.Button(lambda: "Pause" if running() else "Play", on_click=lambda: running.set(not running()),
                      icon=lambda: "pause.fill" if running() else "play.fill", flex=1),
            ui.Button("Step", on_click=advance, icon="forward.frame", kind="gray", disabled=running, flex=1),
        ),
        ui.Section(
            ui.Picker(list(PATTERNS), pattern, kind="menu", label="Pattern", on_change=choose),
            ui.Slider(speed, min=1, max=30, step=1, label="Speed"),
            ui.Button("Random", on_click=lambda: reset(np.random.random((N, N)) < 0.25), kind="plain"),
            ui.Button("Clear", on_click=lambda: (running.set(False), reset(np.zeros((N, N), dtype=bool))),
                      kind="plain"),
        ),
        large_title=False,
    )


ui.run(Life)
