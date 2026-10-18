# Voice memos: record, listen, and turn speech into text.
#
# Recordings are .m4a files in the Recordings folder next to this file
# (they show up in the file browser too). While recording, a meter shows
# how loud it is. Tap a memo to play it; its menu transcribes it with
# speech recognition, or shares it. Uses sound (Recorder, Player), speech,
# console (sharing) and haptics. Tap × to close it.
import datetime as dt
import os

import console
import haptics
import sound
import speech
import ui

FOLDER = "Recordings"
os.makedirs(FOLDER, exist_ok=True)


def memos():
    files = sorted((f for f in os.listdir(FOLDER) if f.endswith(".m4a")), reverse=True)
    return [os.path.join(FOLDER, f) for f in files]


def title(path):
    """memo-2026-10-18-143005.m4a -> "18 October, 14:30"."""
    try:
        when = dt.datetime.strptime(os.path.basename(path), "memo-%Y-%m-%d-%H%M%S.m4a")
    except ValueError:
        return os.path.basename(path)
    return f"{when.day} {when:%B}, {when:%H:%M}"


_lengths = {}


def length(path):
    """How long a memo is, as "m:ss"."""
    if path not in _lengths:
        try:
            seconds = sound.Player(path).duration
        except Exception:
            return ""
        _lengths[path] = f"{int(seconds) // 60}:{int(seconds) % 60:02d}"
    return _lengths[path]


def VoiceMemos():
    files = ui.signal(memos())
    recorder = ui.signal()  # a sound.Recorder while recording
    elapsed = ui.signal(0.0)
    levels = ui.signal([0.0] * 60)  # the last 60 loudness readings, 0 to 1
    playing = ui.signal()  # (path, sound.Player) while one plays
    texts = ui.signal({})  # path -> transcript

    def start():
        stop_playing()
        name = f"memo-{dt.datetime.now():%Y-%m-%d-%H%M%S}.m4a"
        rec = sound.Recorder(os.path.join(FOLDER, name))
        rec.record()
        haptics.impact("medium")
        recorder.set(rec)

    def stop():
        rec = recorder.peek()
        rec.stop()
        haptics.impact("light")
        with ui.batch():
            recorder.set(None)
            elapsed.set(0.0)
            levels.set([0.0] * 60)
            files.set(memos())

    def frame(dt_):
        rec = recorder.peek()
        if rec is None:
            return
        db = rec.meters["average"][0]  # -160 (silence) to 0 (loudest)
        level = max(0.0, min(1.0, (db + 50) / 50))
        with ui.batch():
            levels.set(levels.peek()[1:] + [level])
            elapsed.set(rec.current_time)

    def meter(p):
        p.clear()
        values = levels()
        step = 340 / len(values)
        for i, v in enumerate(values):
            h = 4 + v * 70
            p.begin_path()
            p.round_rect(i * step + 1, 40 - h / 2, step - 2, h, 2)
            p.fill_style = "#ff453a" if recorder() else "#8e8e93"
            p.fill()

    def stop_playing():
        current = playing.peek()
        if current:
            current[1].stop()
            playing.set(None)

    def play(path):
        current = playing.peek()
        stop_playing()
        if current and current[0] == path:
            return  # a second tap stops it
        player = sound.Player(path)
        player.finished_handler = lambda: playing.set(None)
        player.play()
        playing.set((path, player))

    async def options(path):
        choice = await ui.choose(title(path), ["Transcribe", "Share…", "Delete"])
        if choice == "Transcribe":
            try:
                alternatives = speech.recognize(path)
                text = alternatives[0][0] if alternatives else "(no speech found)"
            except RuntimeError as e:
                text = f"Couldn't transcribe it: {e}"
            texts.set({**texts.peek(), path: text})
        elif choice == "Share…":
            console.open_in(path)
        elif choice == "Delete" and await ui.confirm("Delete this memo?", destructive=True, ok="Delete"):
            stop_playing()
            os.remove(path)
            files.set(memos())

    def row(path):
        return ui.Row(
            title(path),
            ui.Spacer(),
            ui.Button(icon="ellipsis.circle", kind="plain", on_click=lambda: options(path),
                      accessibility_label="More"),
            subtitle=lambda: texts().get(path) or length(path),
            icon=lambda: "stop.circle.fill" if playing() and playing()[0] == path else "play.circle.fill",
            on_click=lambda: play(path),
            on_delete=lambda: (stop_playing(), os.remove(path), files.set(memos())),
        )

    def record_button():
        return ui.Button(
            lambda: "Stop" if recorder() else "Record",
            on_click=lambda: stop() if recorder.peek() else start(),
            icon=lambda: "stop.fill" if recorder() else "mic.fill",
            kind=lambda: "destructive" if recorder() else "filled",
            size="large",
        )

    return ui.Screen(
        "Voice Memos",
        ui.Card(
            ui.Canvas(meter, width=340, height=80, on_frame=frame),
            ui.Text(lambda: f"{int(elapsed()) // 60}:{elapsed() % 60:04.1f}" if recorder() else "Ready",
                    font="title", mono=True, text_align="center"),
            record_button(),
        ),
        ui.Section(
            ui.For(files, row, fallback=ui.Text("No memos yet. Tap Record.", color="secondary")),
            header="Recordings",
            footer="Tap a memo to play it, ⋯ to transcribe or share it. Swipe left to delete.",
        ),
    )


ui.run(VoiceMemos)
