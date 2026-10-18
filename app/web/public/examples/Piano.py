# A piano with two octaves. Play with several fingers at once, and pick
# another instrument at the bottom.
#
# Every note is made right here: numpy adds up sine waves (a tone and its
# overtones), shapes how loud it is over time, and the wave module
# writes the sound into a .wav file that sound.play_effect plays. Tap × to
# close it.
import math
import os
import tempfile
import wave
from typing import NamedTuple

import haptics
import numpy as np
import sound
import ui

RATE = 22050  # samples per second
LOW = 60  # MIDI number of the lowest key: middle C
WHITE = [0, 2, 4, 5, 7, 9, 11]  # the white keys of an octave, in semitones from C
NAMES = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
W, H = 360, 220
WHITES = 15  # two octaves and the top C
KEY_W = W / WHITES



class Instrument(NamedTuple):
    overtones: list[float]  # how loud the tone is at 1x, 2x, 3x ... its frequency
    decay: float  # how fast the sound fades
    seconds: float  # how long a note lasts
    square: bool = False  # a square wave instead of overtones (the sound of old video games)


INSTRUMENTS = {
    "Piano": Instrument([1, 0.5, 0.25, 0.12, 0.06], decay=3.0, seconds=1.4),
    "Organ": Instrument([1, 0.8, 0.6, 0.0, 0.3, 0.0, 0.0, 0.2], decay=0.3, seconds=1.0),
    "Bell": Instrument([1, 0, 0.6, 0, 0, 0.4, 0, 0, 0.25], decay=1.6, seconds=2.0),
    "Chiptune": Instrument([1], decay=2.0, seconds=0.8, square=True),
}


def frequency(note):
    return 440 * 2 ** ((note - 69) / 12)  # A above middle C is 440 Hz


def synthesize(note, instrument):
    spec = INSTRUMENTS[instrument]
    t = np.arange(int(RATE * spec.seconds)) / RATE
    f = frequency(note)
    if spec.square:
        signal = np.sign(np.sin(2 * math.pi * f * t)) * 0.35
    else:
        signal = sum(a * np.sin(2 * math.pi * f * (k + 1) * t) for k, a in enumerate(spec.overtones) if a)
        signal = signal / sum(spec.overtones)
    envelope = np.minimum(t / 0.005, 1) * np.exp(-spec.decay * t)  # a quick start, then fade
    envelope[-200:] *= np.linspace(1, 0, 200)  # no click at the end
    return (signal * envelope * 0.9 * 32767).astype(np.int16)


def write_wav(path, samples):
    with wave.open(path, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(samples.tobytes())


FOLDER = tempfile.mkdtemp()
_made = {}


def note_file(note, instrument):
    """The note's .wav file, made the first time it's needed."""
    key = (note, instrument)
    if key not in _made:
        path = os.path.join(FOLDER, f"{instrument}-{note}.wav")
        write_wav(path, synthesize(note, instrument))
        _made[key] = path
    return _made[key]


def keys():
    """Every key: its note and rectangle. Black keys come last, since they
    lie on top (and get the touches first)."""
    whites, blacks = [], []
    for i in range(WHITES):
        note = LOW + 12 * (i // 7) + WHITE[i % 7]
        whites.append({"note": note, "x": i * KEY_W, "w": KEY_W, "h": H, "black": False})
        if i % 7 not in (2, 6) and i < WHITES - 1:  # no black key after E and B
            blacks.append({"note": note + 1, "x": (i + 0.68) * KEY_W, "w": KEY_W * 0.64, "h": H * 0.62,
                           "black": True})
    return whites + blacks


KEYS = keys()


def key_at(x, y):
    for key in reversed(KEYS):
        if key["x"] <= x < key["x"] + key["w"] and y < key["h"]:
            return key
    return None


def Piano():
    instrument = ui.signal("Piano")
    down = ui.signal({})  # touch id -> the note it holds
    last = ui.signal("")

    def play(touch, key):
        held = down.peek()
        if held.get(touch) == key["note"]:
            return
        sound.play_effect(note_file(key["note"], instrument.peek()))
        haptics.selection()
        down.set({**held, touch: key["note"]})
        note = key["note"]
        last.set(f"{NAMES[note % 12]}{note // 12 - 1} · {frequency(note):.1f} Hz")

    def pointer_down(e):
        key = key_at(e.x, e.y)
        if key:
            play(e.id, key)

    def pointer_move(e):
        key = key_at(e.x, e.y)
        if key and e.id in down.peek():  # sliding along the keys plays them
            play(e.id, key)

    def pointer_up(e):
        held = dict(down.peek())
        held.pop(e.id, None)
        down.set(held)

    def draw(p):
        pressed = set(down().values())
        p.clear("#1c1c1e")
        for key in KEYS:
            on = key["note"] in pressed
            p.begin_path()
            p.round_rect(key["x"] + 1, 0, key["w"] - 2, key["h"], 5)
            if key["black"]:
                p.fill_style = "#5e5ce6" if on else "#111"
            else:
                p.fill_style = "#c7c7ff" if on else "#fafafa"
            p.fill()
            if not key["black"] and key["note"] % 12 == 0:
                p.text(f"C{key['note'] // 12 - 1}", key["x"] + key["w"] / 2, H - 12, color="#8e8e93",
                       font="11px system-ui", align="center")

    def prepare(name):
        instrument.set(name)
        for key in KEYS:  # make all the notes now, so the first touches play at once
            note_file(key["note"], name)

    prepare("Piano")

    return ui.Screen(
        "Piano",
        ui.Canvas(draw, width=W, height=H, on_pointer_down=pointer_down, on_pointer_move=pointer_move,
                  on_pointer_up=pointer_up, corner_radius=8),
        ui.Text(lambda: last() or "Touch the keys", font="headline", mono=True, text_align="center"),
        ui.Section(ui.Picker(list(INSTRUMENTS), instrument, kind="segmented", on_change=prepare),
                   header="Instrument"),
        large_title=False,
    )


ui.run(Piano)
