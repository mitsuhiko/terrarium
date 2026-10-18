# A drum machine: 16 steps, four drums. Tap the grid to place beats, press
# Play, and change the tempo while it plays.
#
# The drums are made with numpy: a kick is a sine wave that drops in pitch,
# a snare and a hi-hat are filtered noise, a clap is noise in short bursts.
# The wave module writes them as .wav files for sound.play_effect, and
# ui.interval plays the steps. Tap × to close it.
import math
import os
import tempfile
import wave

import numpy as np
import sound
import ui

RATE = 22050
STEPS = 16
DRUMS = ["Kick", "Snare", "Clap", "Hi-hat"]
COLORS = {"Kick": "#ff375f", "Snare": "#ff9f0a", "Clap": "#30d158", "Hi-hat": "#64d2ff"}
PATTERNS = {
    "Rock": {"Kick": [0, 8, 10], "Snare": [4, 12], "Hi-hat": [0, 2, 4, 6, 8, 10, 12, 14]},
    "Four on the floor": {"Kick": [0, 4, 8, 12], "Clap": [4, 12], "Hi-hat": [2, 6, 10, 14]},
    "Hip hop": {"Kick": [0, 3, 8, 10], "Snare": [4, 12], "Hi-hat": [0, 2, 4, 6, 8, 10, 11, 12, 14]},
    "Bossa nova": {"Kick": [0, 3, 4, 8, 11, 12], "Clap": [0, 3, 6, 10, 13], "Hi-hat": list(range(16))},
}
W, LABEL = 360, 52
CELL = (W - LABEL) / STEPS
ROW = 44


def drum(name):
    t = np.arange(int(RATE * 0.5)) / RATE
    noise = np.random.default_rng(1).uniform(-1, 1, t.size)
    if name == "Kick":
        pitch = 50 + 120 * np.exp(-t * 30)  # starts high, drops fast
        signal = np.sin(2 * math.pi * np.cumsum(pitch) / RATE) * np.exp(-t * 7)
    elif name == "Snare":
        tone = np.sin(2 * math.pi * 185 * t) * np.exp(-t * 25)
        rattle = np.diff(noise, prepend=0) * 0.5 * np.exp(-t * 18)  # differences: the high part of the noise
        signal = 0.5 * tone + rattle
    elif name == "Clap":
        bursts = sum(np.exp(-np.maximum(t - d, 0) * 120) * (t >= d) for d in (0, 0.011, 0.022))
        signal = noise * (0.6 * bursts + 0.4 * np.exp(-t * 14) * (t >= 0.022))
    else:  # Hi-hat
        signal = np.diff(np.diff(noise, prepend=0), prepend=0) * 0.25 * np.exp(-t * 60)
    signal = signal / np.max(np.abs(signal)) * 0.9
    return (signal * 32767).astype(np.int16)


FOLDER = tempfile.mkdtemp()
FILES = {}
for _name in DRUMS:
    FILES[_name] = os.path.join(FOLDER, f"{_name}.wav")
    with wave.open(FILES[_name], "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(drum(_name).tobytes())


def grid_of(pattern):
    return {d: [s in PATTERNS[pattern].get(d, []) for s in range(STEPS)] for d in DRUMS}


def DrumMachine():
    grid = ui.signal(grid_of("Rock"))
    playing = ui.signal(False)
    position = ui.signal(-1)  # the step that is playing
    tempo = ui.signal(100)  # beats per minute; a beat is four steps
    pattern = ui.signal("Rock")

    def tick():
        step = (position.peek() + 1) % STEPS
        position.set(step)
        for name in DRUMS:
            if grid.peek()[name][step]:
                sound.play_effect(FILES[name], volume={"Hi-hat": 0.4}.get(name, 0.8))

    @ui.effect
    def _():
        if playing():
            ui.interval(60 / tempo() / 4, tick)
        else:
            position.set(-1)

    def toggle(e):
        row, step = int(e.y // ROW), int((e.x - LABEL) // CELL)
        if 0 <= row < len(DRUMS) and 0 <= step < STEPS:
            name = DRUMS[row]
            cells = {d: list(v) for d, v in grid.peek().items()}
            cells[name][step] = not cells[name][step]
            grid.set(cells)
            if cells[name][step] and not playing.peek():
                sound.play_effect(FILES[name])

    def draw(p):
        cells, now = grid(), position()
        p.clear("#1c1c1e")
        for row, name in enumerate(DRUMS):
            y = row * ROW
            p.text(name, 4, y + ROW / 2 + 4, color="#aeaeb2", font="12px system-ui")
            for step in range(STEPS):
                x = LABEL + step * CELL
                on = cells[name][step]
                if on:
                    color = COLORS[name]
                elif step == now:
                    color = "#48484a"
                else:
                    color = "#3a3a3c" if step // 4 % 2 else "#2c2c2e"  # beats in groups of four
                p.begin_path()
                p.round_rect(x + 1.5, y + 4, CELL - 3, ROW - 8, 3)
                p.fill_style = color
                p.fill()
                if on and step == now:
                    p.circle(x + CELL / 2, y + ROW / 2, 4, fill="white")

    def load(name):
        pattern.set(name)
        grid.set(grid_of(name))

    return ui.Screen(
        "Drum Machine",
        ui.Canvas(draw, width=W, height=ROW * len(DRUMS), on_pointer_down=toggle, corner_radius=10),
        ui.HStack(
            ui.Button(lambda: "Stop" if playing() else "Play", on_click=lambda: playing.set(not playing()),
                      icon=lambda: "stop.fill" if playing() else "play.fill", flex=1,
                      kind=lambda: "destructive" if playing() else "filled"),
            ui.Button("Clear", on_click=lambda: grid.set({d: [False] * STEPS for d in DRUMS}), icon="trash",
                      kind="gray", flex=1),
        ),
        ui.Section(
            ui.Slider(tempo, min=60, max=180, step=1, label="Tempo"),
            ui.Text(lambda: f"{tempo():.0f} beats per minute", color="secondary", font="footnote"),
            ui.Picker(list(PATTERNS), pattern, kind="menu", label="Pattern", on_change=load),
        ),
        large_title=False,
    )


ui.run(DrumMachine, theme="dark")
