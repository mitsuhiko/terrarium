# A Pomodoro timer: 25 minutes of focus, then a short break; a long break
# after every fourth. Change the lengths under Settings.
#
# A notification is scheduled for the end of each phase, so it reaches you
# even when you switch to another app. Uses notification, sound, haptics,
# console (to keep the screen on) and a JSON file next to this one for the
# settings (pomodoro.json). Tap × to close it.
import json
import math
import os
import time

import console
import haptics
import notification
import sound
import ui

SETTINGS = "pomodoro.json"
DEFAULTS = {"focus": 25, "short": 5, "long": 15, "keep_awake": True}
PHASES = {
    "focus": ("Focus", "#ff453a", "brain.head.profile"),
    "short": ("Short break", "#30d158", "cup.and.saucer.fill"),
    "long": ("Long break", "#0a84ff", "figure.walk"),
}
NOTE_ID = "pomodoro"


def load_settings():
    if os.path.exists(SETTINGS):
        with open(SETTINGS) as f:
            return {**DEFAULTS, **json.load(f)}
    return dict(DEFAULTS)


def Pomodoro():
    settings = ui.store(load_settings())
    phase = ui.signal("focus")
    ends_at = ui.signal()  # the time.time() the phase ends while running, else None
    left = ui.signal(settings["focus"] * 60.0)  # seconds left
    done = ui.signal(0)  # focus sessions finished
    now = ui.signal(time.time())

    @ui.effect
    def save():
        data = ui.unwrap(settings)  # reads every setting: runs again when one changes
        if data != load_settings():
            with open(SETTINGS, "w") as f:
                json.dump(data, f, indent=2)

    ui.interval(0.25, lambda: now.set(time.time()))

    def _length(name):
        return settings[name] * 60.0

    def remaining():
        return max(0.0, ends_at() - now()) if ends_at() else left()

    def start():
        ends_at.set(time.time() + left.peek())
        title, _, _ = PHASES[phase.peek()]
        try:
            notification.schedule(f"{title} is over.", delay=left.peek(), title="Pomodoro", sound_name="default",
                                  identifier=NOTE_ID)
        except PermissionError:
            ui.toast("Notifications are off: the timer only rings in here")
        console.set_idle_timer_disabled(settings["keep_awake"])
        haptics.impact("medium")

    def pause():
        left.set(remaining())
        ends_at.set(None)
        notification.cancel(NOTE_ID)
        console.set_idle_timer_disabled(False)

    def go_to(name):
        with ui.batch():
            phase.set(name)
            ends_at.set(None)
            left.set(_length(name))
        notification.cancel(NOTE_ID)
        console.set_idle_timer_disabled(False)

    def next_phase():
        if phase.peek() == "focus":
            done.update(lambda n: n + 1)
            go_to("long" if done.peek() % 4 == 0 else "short")
        else:
            go_to("focus")

    # When the time is up: a sound, a buzz, and on to the next phase.
    @ui.effect
    def time_is_up():
        if ends_at() and remaining() <= 0:
            sound.play_effect("ding")
            haptics.notification("success")
            ui.untrack(next_phase)

    ui.on_cleanup(lambda: (notification.cancel(NOTE_ID), console.set_idle_timer_disabled(False)))

    def ring(p):
        name = phase()
        title, color, _ = PHASES[name]
        total = _length(name)
        fraction = remaining() / total if total else 0
        p.clear()
        p.line_cap = "round"
        p.begin_path()
        p.arc(150, 150, 120, 0, 2 * math.pi)
        p.stroke_style = "rgba(142, 142, 147, 0.25)"
        p.line_width = 18
        p.stroke()
        if fraction > 0:
            p.begin_path()
            p.arc(150, 150, 120, -math.pi / 2, -math.pi / 2 + 2 * math.pi * fraction)
            p.stroke_style = color
            p.stroke()
        seconds = math.ceil(remaining())
        p.text(f"{seconds // 60:02d}:{seconds % 60:02d}", 150, 165, color=color, font="bold 52px system-ui",
               align="center")
        p.text(title, 150, 200, color="#8e8e93", font="17px system-ui", align="center")

    def Settings():
        return ui.Screen(
            "Settings",
            ui.Section(
                ui.Stepper(lambda: f"Focus: {settings.focus} min", ui.bind(settings, "focus"), min=1, max=90),
                ui.Stepper(lambda: f"Short break: {settings.short} min", ui.bind(settings, "short"), min=1, max=30),
                ui.Stepper(lambda: f"Long break: {settings.long} min", ui.bind(settings, "long"), min=1, max=60),
                footer="New lengths count from the next phase.",
            ),
            ui.Section(ui.Toggle("Keep the screen on", ui.bind(settings, "keep_awake"))),
            large_title=False,
        )

    return ui.Screen(
        "Pomodoro",
        ui.Canvas(ring, width=300, height=300),
        ui.Text(lambda: "🍅" * done() or "Finish a focus session for a 🍅", text_align="center", font="title3"),
        ui.HStack(
            ui.Button(lambda: "Pause" if ends_at() else "Start", on_click=lambda: pause() if ends_at() else start(),
                      icon=lambda: "pause.fill" if ends_at() else "play.fill", size="large", flex=1),
            ui.Button("Skip", on_click=next_phase, icon="forward.end.fill", kind="gray", size="large", flex=1),
        ),
        ui.Section(
            ui.Picker({k: v[0] for k, v in PHASES.items()}, phase, on_change=go_to),
            ui.Button("Reset", on_click=lambda: go_to(phase.peek()), kind="plain"),
        ),
        trailing=ui.Button(icon="gearshape", kind="plain", on_click=lambda: ui.navigation().push(Settings),
                           accessibility_label="Settings"),
    )


ui.run(ui.NavigationStack(Pomodoro))
