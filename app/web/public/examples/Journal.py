# A journal: write how your day went, with a mood. Entries go into an SQLite
# database (journal.db, next to this file), which the app asks with SQL:
# the list, the search, the moods of the last two weeks and your streak.
#
# Lock it with a passcode from the ⋯ menu: the passcode is kept in the
# iOS Keychain (the keychain module), not in a file. Forgot it? Run
# `import keychain; keychain.delete_password("Journal", "passcode")`
# at the >>> prompt. Tap × to close it.
import datetime as dt
import sqlite3

import haptics
import keychain
import ui

MOODS = {1: "😞", 2: "😕", 3: "😐", 4: "🙂", 5: "😄"}
MOOD_COLORS = {1: "#ff453a", 2: "#ff9f0a", 3: "#ffd60a", 4: "#64d2ff", 5: "#30d158"}
SERVICE, ACCOUNT = "Journal", "passcode"

db = sqlite3.connect("journal.db")
db.row_factory = sqlite3.Row
db.execute("""
    CREATE TABLE IF NOT EXISTS entries (
        id INTEGER PRIMARY KEY,
        day TEXT NOT NULL,      -- YYYY-MM-DD
        time TEXT NOT NULL,     -- HH:MM
        mood INTEGER NOT NULL,  -- 1 to 5
        text TEXT NOT NULL
    )
""")
if db.execute("SELECT COUNT(*) FROM entries").fetchone()[0] == 0:
    yesterday = (dt.date.today() - dt.timedelta(days=1)).isoformat()
    db.execute("INSERT INTO entries (day, time, mood, text) VALUES (?, ?, ?, ?)",
               (yesterday, "21:30", 4, "Started a journal in Terrarium. Tap + to write today's entry."))
    db.commit()


# -- queries ----------------------------------------------------------------------

def entries(search=""):
    rows = db.execute(
        "SELECT * FROM entries WHERE text LIKE ? ORDER BY day DESC, time DESC",
        (f"%{search}%",),
    )
    return [dict(row) for row in rows]


def add(mood, text):
    now = dt.datetime.now()
    db.execute("INSERT INTO entries (day, time, mood, text) VALUES (?, ?, ?, ?)",
               (now.date().isoformat(), f"{now:%H:%M}", mood, text.strip()))
    db.commit()


def update(entry_id, mood, text):
    db.execute("UPDATE entries SET mood = ?, text = ? WHERE id = ?", (mood, text.strip(), entry_id))
    db.commit()


def delete(entry_id):
    db.execute("DELETE FROM entries WHERE id = ?", (entry_id,))
    db.commit()


def moods_by_day(days=14):
    """The average mood of each of the last `days` days (None: no entry)."""
    first = dt.date.today() - dt.timedelta(days=days - 1)
    rows = db.execute("SELECT day, AVG(mood) FROM entries WHERE day >= ? GROUP BY day", (first.isoformat(),))
    averages = dict(rows.fetchall())
    return [(first + dt.timedelta(days=i), averages.get((first + dt.timedelta(days=i)).isoformat()))
            for i in range(days)]


def streak():
    """Days in a row with an entry, up to today (or yesterday)."""
    days = {row[0] for row in db.execute("SELECT DISTINCT day FROM entries")}
    day = dt.date.today()
    if day.isoformat() not in days:
        day -= dt.timedelta(days=1)
    count = 0
    while day.isoformat() in days:
        count += 1
        day -= dt.timedelta(days=1)
    return count


# -- screens ----------------------------------------------------------------------

def when(entry):
    day = dt.date.fromisoformat(entry["day"])
    ago = (dt.date.today() - day).days
    name = {0: "Today", 1: "Yesterday"}.get(ago, f"{day:%A}, {day.day} {day:%B %Y}" if ago > 6 else f"{day:%A}")
    return f"{name}, {entry['time']}"


def plural(n, one, many):
    return f"{n} {one if n == 1 else many}"


def MoodPicker(mood):
    return ui.Picker(MOODS, mood)


def mood_chart(data):
    W, H = 340, 90

    def draw(p):
        p.clear()
        step = W / len(data)
        for i, (day, mood) in enumerate(data):
            x = i * step + step / 2
            if mood is None:
                p.circle(x, H - 24, 2, fill="#8e8e93")
            else:
                height = mood / 5 * (H - 30)
                p.begin_path()
                p.round_rect(x - step * 0.3, H - 20 - height, step * 0.6, height, 4)
                p.fill_style = MOOD_COLORS[round(mood)]
                p.fill()
            if (len(data) - 1 - i) % 2 == 0:  # every other day, ending today
                p.text(str(day.day), x, H - 4, color="#8e8e93", font="10px system-ui", align="center")

    return ui.Canvas(draw, width=W, height=H)


def Editor(entry, refresh):
    """The sheet for a new entry (entry None) or for editing one."""
    mood = ui.signal(entry["mood"] if entry else 4)
    text = ui.signal(entry["text"] if entry else "")

    def save():
        if entry:
            update(entry["id"], mood(), text())
        else:
            add(mood(), text())
            haptics.notification("success")
        refresh()
        ui.navigation().pop()

    return ui.Screen(
        "Edit" if entry else "New Entry",
        ui.Section(MoodPicker(mood), header="How was it?"),
        ui.Section(ui.TextArea(text, placeholder="What happened today?", rows=10)),
        trailing=ui.Button("Save", on_click=save, disabled=lambda: not text().strip(), kind="plain"),
        large_title=False,
    )


def Entry(entry, refresh):
    nav = ui.navigation()

    async def remove():
        if await ui.confirm("Delete this entry?", destructive=True, ok="Delete"):
            delete(entry["id"])
            refresh()
            nav.pop()

    return ui.Screen(
        when(entry),
        ui.Text(MOODS[entry["mood"]], font_size=48),
        ui.Text(entry["text"], selectable=True),
        ui.Button("Delete", on_click=remove, kind="destructive", icon="trash"),
        trailing=ui.Button("Edit", kind="plain",
                           on_click=lambda: nav.push(Editor, entry, lambda: (refresh(), nav.pop()))),
        large_title=False,
    )


def Journal():
    locked = ui.signal(keychain.get_password(SERVICE, ACCOUNT) is not None)
    search = ui.signal("")
    version = ui.signal(0)  # bumped after every change: the queries run again
    found = ui.computed(lambda: (version(), entries(search()))[1])
    stats = ui.computed(lambda: (version(), (moods_by_day(), streak()))[1])
    nav = ui.navigation()

    def refresh():
        version.update(lambda n: n + 1)

    async def menu():
        has_code = keychain.get_password(SERVICE, ACCOUNT) is not None
        options = ["Lock now", "Change passcode", "Remove the passcode"] if has_code else ["Lock with a passcode"]
        choice = await ui.choose("Journal", options)
        if choice in ("Lock with a passcode", "Change passcode"):
            code = await ui.prompt("New passcode", "You'll need it to open the journal.", placeholder="Passcode")
            if code:
                keychain.set_password(SERVICE, ACCOUNT, code)
                ui.toast("The passcode is in the Keychain")
        elif choice == "Lock now":
            locked.set(True)
        elif choice == "Remove the passcode":
            keychain.delete_password(SERVICE, ACCOUNT)
            ui.toast("No passcode")

    def row(entry):
        return ui.Row(
            entry["text"].splitlines()[0][:60] if entry["text"] else "(empty)",
            subtitle=when(entry),
            icon=MOODS[entry["mood"]],
            accessory="chevron",
            on_click=lambda: nav.push(Entry, entry, refresh),
            on_delete=lambda: (delete(entry["id"]), refresh()),
        )

    def unlocked():
        return ui.VStack(
            ui.Card(
                ui.HStack(
                    ui.Icon("flame.fill", color="orange"),
                    ui.Text(lambda: f"{stats()[1]} day streak", font_weight="semibold"),
                    ui.Spacer(),
                    ui.Text(lambda: plural(len(found()), "entry", "entries") + (" found" if search() else ""),
                            color="secondary"),
                ),
                lambda: mood_chart(stats()[0]),
            ),
            ui.TextField(search, placeholder="Search", kind="search"),
            ui.Section(
                ui.For(found, row, key=lambda e: (e["id"], e["mood"], e["text"]),
                       fallback=ui.Text("Nothing here yet.", color="secondary")),
            ),
            spacing=16,
        )

    return ui.Screen(
        "Journal",
        ui.Show(locked, lambda: Lock(lambda: locked.set(False)), fallback=unlocked),
        trailing=ui.HStack(
            ui.Button(icon="ellipsis.circle", kind="plain", on_click=menu, accessibility_label="Menu"),
            ui.Button(icon="square.and.pencil", kind="plain", on_click=lambda: nav.push(Editor, None, refresh),
                      accessibility_label="New entry"),
            hidden=locked,
        ),
    )


def Lock(unlock):
    code = ui.signal("")

    def check(value=None):
        if code() == keychain.get_password(SERVICE, ACCOUNT):
            unlock()
        else:
            haptics.notification("error")
            code.set("")
            ui.toast("Wrong passcode")

    return ui.Card(
        ui.HStack(ui.Spacer(), ui.Icon("lock.fill", size=40, color="secondary"), ui.Spacer()),
        ui.Text("This journal is locked.", text_align="center", color="secondary"),
        ui.TextField(code, kind="password", placeholder="Passcode", on_submit=check, autofocus=True),
        ui.Button("Open", on_click=check),
        padding=24,
    )


ui.run(ui.NavigationStack(Journal))
