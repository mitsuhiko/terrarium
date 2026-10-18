# A tab bar with its own navigation stack per tab, a badge and a stopwatch.
import ui

inbox = ui.store([f"Message {i}" for i in range(1, 6)])


def Stopwatch():
    elapsed = ui.signal(0.0)
    running = ui.signal(False)
    laps = ui.store([])

    # While running, tick. The interval belongs to this effect, so it is
    # cancelled automatically when `running` changes (or the tab goes away).
    @ui.effect
    def _():
        if running():
            ui.interval(0.05, lambda: elapsed.update(lambda t: t + 0.05))

    return ui.Screen(
        "Stopwatch",
        ui.Text(lambda: f"{elapsed():6.2f}", font="largeTitle", mono=True, text_align="center", font_size=64),
        ui.HStack(
            ui.Button(lambda: "Stop" if running() else "Start", on_click=lambda: running.set(not running()),
                      flex=1, kind=lambda: "destructive" if running() else "filled"),
            ui.Button("Lap", on_click=lambda: laps.insert(0, elapsed()), kind="gray", flex=1,
                      disabled=lambda: not running()),
        ),
        ui.Section(ui.For(laps, lambda t, i: ui.Row(lambda: f"Lap {len(laps) - i()}", detail=f"{t:.2f}"))),
    )


def Inbox():
    def Message(text):
        return ui.Screen(text, ui.Text(f"This is {text.lower()}."), large_title=False)

    return ui.NavigationStack(lambda: ui.Screen(
        "Inbox",
        ui.Section(ui.For(inbox, lambda m: ui.Row(
            m, accessory="chevron", on_click=lambda: ui.navigation().push(Message, m),
            on_delete=lambda: inbox.remove(m)))),
    ))


def App():
    tab = ui.signal(0)
    return ui.TabView(
        ui.Tab("Inbox", Inbox(), icon="envelope", badge=lambda: len(inbox) or None),
        ui.Tab("Stopwatch", Stopwatch(), icon="clock"),
        ui.Tab("About", ui.Text("Tabs keep their state.", font="title2"),
               ui.Text(lambda: f"You are on tab {tab() + 1}."), icon="info"),
        selected=tab,
    )


ui.run(App)
