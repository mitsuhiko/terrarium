# Every input, bound two-way to signals, with a live summary.
import datetime

import ui


def Settings():
    name = ui.signal("Ada")
    notify = ui.signal(True)
    volume = ui.signal(0.6)
    size = ui.signal(14)
    theme = ui.signal("Auto")
    lang = ui.signal("py")
    birthday = ui.signal(datetime.date(1815, 12, 10))
    color = ui.signal("#ff9500")
    bio = ui.signal("")

    return ui.Screen(
        "Settings",
        ui.Section(
            ui.TextField(name, label="Name", placeholder="Your name"),
            ui.DatePicker(birthday, label="Birthday"),
            header="Profile",
        ),
        ui.Section(
            ui.Toggle("Notifications", notify),
            ui.Slider(volume, label="Volume", disabled=lambda: not notify()),
            ui.Stepper("Font size", size, min=10, max=24),
            ui.Picker({"py": "Python", "js": "JavaScript", "rs": "Rust"}, lang, kind="menu", label="Language"),
            ui.ColorPicker(color, label="Accent"),
            header="Preferences",
        ),
        ui.Section(ui.Picker(["Light", "Auto", "Dark"], theme), header="Appearance"),
        ui.Section(ui.TextArea(bio, placeholder="About you"), header="Bio"),
        ui.Card(
            ui.Label("Summary", icon="info", font_weight="semibold"),
            ui.Text(lambda: f"{name()} · born {birthday():%d %b %Y} · likes {lang()}", font="subheadline"),
            ui.Text(lambda: f"notify={notify()} volume={volume():.0%} size={size()} theme={theme()}",
                    font="footnote", mono=True),
            ui.Text(lambda: bio() or "(no bio)", font="footnote", lines=2),
            ui.HStack(ui.Text("Accent"), ui.Spacer(),
                      ui.Text("", width=24, height=24, corner_radius=12, background=color)),
            border=lambda: (2, color()),
            font_size=lambda: size() + 3,
        ),
    )


ui.run(Settings)
