import asyncio
import random

import pytest

import ui


def test_counter_updates_one_prop(h):
    def App():
        count = ui.signal(0)
        return ui.Screen(
            "Counter",
            ui.Text(lambda: f"{count()} taps", font="largeTitle"),
            ui.Button("+1", on_click=lambda: count.update(lambda n: n + 1)),
        )

    dom = h.run(App)
    text = dom.find("Text")
    assert text["p"]["text"] == "0 taps"
    n = len(dom.ops)
    h.fire(dom.find("Button"), "click")
    assert h.ops_since(n) == [["set", text["i"], {"text": "1 taps"}]]


def test_initial_render_is_one_message(h):
    dom = h.run(lambda: ui.VStack(*(ui.Text(str(i)) for i in range(50))))
    assert len(dom.messages) == 1
    assert [op[0] for op in dom.ops] == ["config", "mount"]


def test_live_child_text_fast_path(h):
    n = ui.signal(1)
    dom = h.run(lambda: ui.VStack("Count: ", n))
    texts = dom.find_all("#text")
    assert [t["p"]["text"] for t in texts] == ["Count: ", "1"]
    before = len(dom.ops)
    n.set(2)
    h.flush()
    assert h.ops_since(before) == [["set", texts[1]["i"], {"text": "2"}]]


def test_live_child_swaps_elements(h):
    mode = ui.signal("a")
    dom = h.run(lambda: ui.VStack(ui.Text("top"), lambda: ui.Text("A") if mode() == "a" else ui.Button("B"),
                                  ui.Text("bottom")))
    assert dom.text() == "topAbottom"
    mode.set("b")
    h.flush()
    assert dom.text() == "topBbottom"
    assert [k["t"] for k in dom.find("VStack")["kids"]] == ["Text", "Button", "Text"]


def test_show_static_children_are_reused(h):
    on = ui.signal(True)
    keep = ui.Text("kept")
    dom = h.run(lambda: ui.VStack(ui.Show(on, keep, ui.Text("second"), fallback=ui.Text("off")), "end"))
    assert dom.text() == "keptsecondend"
    on.set(False)
    h.flush()
    assert dom.text() == "offend"
    on.set(True)
    h.flush()
    assert dom.text() == "keptsecondend"
    assert dom.find("Text", text="kept")["i"] == keep.id


def test_show_lazy_child_gets_value(h):
    user = ui.signal(None)
    built = []

    def Welcome(name):
        built.append(name)
        return ui.Text(f"hi {name}")

    dom = h.run(lambda: ui.VStack(ui.Show(user, Welcome, fallback="nobody")))
    assert built == [] and dom.text() == "nobody"
    user.set("ann")
    h.flush()
    assert dom.text() == "hi ann" and built == ["ann"]
    user.set("bob")  # still truthy: not rebuilt
    h.flush()
    assert built == ["ann"]


def _dom_texts(dom, parent_type="VStack"):
    return [dom.text(k) for k in dom.find(parent_type)["kids"]]


def test_for_keyed(h):
    items = ui.store(["a", "b", "c"])
    renders = []

    def Item(x):
        renders.append(x)
        return ui.Text(x)

    dom = h.run(lambda: ui.VStack("head", ui.For(items, Item), "tail"))
    assert _dom_texts(dom) == ["head", "a", "b", "c", "tail"]
    ids = {dom.text(k): k["i"] for k in dom.find("VStack")["kids"]}
    items.reverse()
    h.flush()
    assert _dom_texts(dom) == ["head", "c", "b", "a", "tail"]
    assert {dom.text(k): k["i"] for k in dom.find("VStack")["kids"]} == ids  # nodes kept
    assert renders == ["a", "b", "c"]
    with ui.batch():
        items.insert(1, "x")
        items.remove("a")
    h.flush()
    assert _dom_texts(dom) == ["head", "c", "x", "b", "tail"]
    assert renders == ["a", "b", "c", "x"]


def test_for_minimal_moves(h):
    items = ui.store(list(range(100)))
    dom = h.run(lambda: ui.VStack(ui.For(items, lambda i: ui.Text(str(i)))))
    n = len(dom.ops)
    with ui.batch():
        x = items.pop(10)
        items.insert(90, x)
    h.flush()
    ops = h.ops_since(n)
    assert [op[0] for op in ops] == ["move"]
    assert _dom_texts(dom) == [str(i) for i in items]


def test_for_index_and_fallback(h):
    items = ui.store(["a", "b"])
    dom = h.run(lambda: ui.VStack(ui.For(items, lambda x, i: ui.Text(lambda: f"{i()}:{x}"), fallback="empty")))
    assert _dom_texts(dom) == ["0:a", "1:b"]
    items.reverse()
    h.flush()
    assert _dom_texts(dom) == ["0:b", "1:a"]
    items.clear()
    h.flush()
    assert _dom_texts(dom) == ["empty"]
    items.append("z")
    h.flush()
    assert _dom_texts(dom) == ["0:z"]


def test_for_disposes_removed_rows(h):
    items = ui.store(["a", "b"])
    cleaned = []

    def Item(x):
        ui.on_cleanup(lambda: cleaned.append(x))
        return ui.Text(x)

    h.run(lambda: ui.VStack(ui.For(items, Item)))
    items.remove("a")
    h.flush()
    assert cleaned == ["a"]


def test_for_with_key_rerenders_changed_data(h):
    rows = ui.signal([{"id": 1, "name": "a"}, {"id": 2, "name": "b"}])
    dom = h.run(lambda: ui.VStack(ui.For(rows, lambda r: ui.Text(r["name"]), key=lambda r: r["id"])))
    first = dom.find("Text", text="b")["i"]
    rows.set([{"id": 1, "name": "A"}, rows.peek()[1]])
    h.flush()
    assert _dom_texts(dom) == ["A", "b"]
    assert dom.find("Text", text="b")["i"] == first


def test_for_multi_element_rows_and_nesting(h):
    groups = ui.store([{"name": "g1", "items": ["a"]}, {"name": "g2", "items": []}])
    dom = h.run(lambda: ui.VStack(ui.For(groups, lambda g: [ui.Text(g.name), ui.For(g["items"], lambda x: ui.Text(x))])))
    assert _dom_texts(dom) == ["g1", "a", "g2"]
    groups[1]["items"].append("b")
    groups[0]["items"].append("c")
    h.flush()
    assert _dom_texts(dom) == ["g1", "a", "c", "g2", "b"]
    groups.reverse()
    h.flush()
    assert _dom_texts(dom) == ["g2", "b", "g1", "a", "c"]


@pytest.mark.parametrize("seed", range(40))
def test_for_fuzz(h, seed):
    rnd = random.Random(seed)
    items = ui.store([f"i{n}" for n in range(rnd.randint(0, 12))])
    counter = [100]
    show = ui.signal(True)
    dom = h.run(lambda: ui.VStack("<", ui.Show(show, ui.For(items, lambda x: [ui.Text(x), ui.Text(x + "!")])), ">"))
    for _ in range(30):
        op = rnd.random()
        if op < 0.25:
            counter[0] += 1
            items.insert(rnd.randint(0, len(items)), f"i{counter[0]}")
        elif op < 0.45 and len(items):
            items.pop(rnd.randrange(len(items)))
        elif op < 0.6:
            snapshot = list(items)
            rnd.shuffle(snapshot)
            items.set(snapshot)
        elif op < 0.7:
            show.set(not show.peek())
        elif op < 0.8:
            items.reverse()
        else:
            with ui.batch():
                for _ in range(rnd.randint(1, 3)):
                    counter[0] += 1
                    items.append(f"i{counter[0]}")
                if len(items) > 2:
                    items.pop(0)
        h.flush()
        expected = ["<", *([t for x in items for t in (x, x + "!")] if show.peek() else []), ">"]
        assert _dom_texts(dom) == expected


def test_two_way_binding_does_not_echo(h):
    name = ui.signal("")
    dom = h.run(lambda: ui.VStack(ui.TextField(name), ui.Text(lambda: f"Hi {name()}")))
    field = dom.find("TextField")
    n = len(dom.ops)
    h.fire(field, "change", "Ann")
    assert name.peek() == "Ann"
    ops = h.ops_since(n)
    assert ops == [["set", dom.find("Text")["i"], {"text": "Hi Ann"}]]  # nothing sent back to the field


def test_on_change_overrides_binding(h):
    name = ui.signal("")
    dom = h.run(lambda: ui.TextField(name, on_change=lambda v: name.set(v.upper())))
    h.fire(dom.find("TextField"), "change", "abc")
    assert dom.find("TextField")["p"]["value"] == "ABC"


def test_toggle_slider_picker_stepper(h):
    on, level, color, qty = ui.signal(False), ui.signal(0.5), ui.signal("green"), ui.signal(1)
    dom = h.run(lambda: ui.Section(
        ui.Toggle("On", on),
        ui.Slider(level),
        ui.Picker(["red", "green", "blue"], color),
        ui.Stepper("Qty", qty, min=0, max=2),
    ))
    assert dom.find("Picker")["p"]["value"] == 1
    h.fire(dom.find("Toggle"), "change", True)
    h.fire(dom.find("Slider"), "change", 0.75)
    h.fire(dom.find("Picker"), "change", 2)
    h.fire(dom.find("Stepper"), "change", 1)
    h.fire(dom.find("Stepper"), "change", 1)
    assert (on.peek(), level.peek(), color.peek(), qty.peek()) == (True, 0.75, "blue", 2)
    assert dom.find("Stepper")["p"]["value"] == 2
    color.set("red")
    h.flush()
    assert dom.find("Picker")["p"]["value"] == 0


def test_date_picker_round_trips_dates(h):
    import datetime

    d = ui.signal(datetime.date(2026, 1, 2))
    dom = h.run(lambda: ui.DatePicker(d))
    assert dom.find("DatePicker")["p"]["value"] == "2026-01-02"
    h.fire(dom.find("DatePicker"), "change", "2026-03-04")
    assert d.peek() == datetime.date(2026, 3, 4)


def test_modifiers_and_reactive_style(h):
    wide = ui.signal(False)
    dom = h.run(lambda: ui.Text("x", padding=(4, 8), width=lambda: 200 if wide() else 100, opacity=0.5,
                                font_weight="semibold", border=lambda: (2, "red") if wide() else "separator",
                                shadow=True, text_align="right", accessibility_label="Ex"))
    p = dom.find("Text")["p"]
    assert p["padding"] == [4, 8]
    assert p["width"] == 100
    assert p["opacity"] == 0.5 and p["font_weight"] == 600 and p["shadow"] == 12
    assert p["border"] == [1, "separator"] and p["text_align"] == "trailing" and p["a11y"] == "Ex"
    wide.set(True)
    h.flush()
    p = dom.find("Text")["p"]
    assert p["width"] == 200 and p["border"] == [2, "red"]


def test_color_none_clears(h):
    fav = ui.signal(True)
    dom = h.run(lambda: ui.Icon("star", color=lambda: "orange" if fav() else None))
    assert dom.find("Icon")["p"]["color"] == "orange"
    fav.set(False)
    h.flush()
    assert dom.find("Icon")["p"]["color"] is None


def test_navigation_stack(h):
    log = []

    def Detail(n):
        ui.on_cleanup(lambda: log.append(f"bye {n}"))
        return ui.Screen(f"Item {n}", ui.Button("deeper", on_click=lambda: ui.navigation().push(Detail, n + 1)))

    def Home():
        return ui.Screen("Home", ui.Button("open", on_click=lambda: ui.navigation().push(Detail, 1)))

    dom = h.run(lambda: ui.NavigationStack(Home))
    h.fire(dom.find("Button", label="open"), "click")
    screens = dom.find_all("Screen")
    assert [s["p"]["title"] for s in screens] == ["Home", "Item 1"]
    assert screens[1]["p"]["back"] == "Home"
    h.fire(dom.find_all("Button")[-1], "click")
    assert [s["p"]["title"] for s in dom.find_all("Screen")] == ["Home", "Item 1", "Item 2"]
    h.fire(dom.find_all("Screen")[-1], "back")
    assert [s["p"]["title"] for s in dom.find_all("Screen")] == ["Home", "Item 1"]
    assert log == ["bye 2"]


def test_sheet_dismiss_updates_signal(h):
    open_ = ui.signal(False)
    dom = h.run(lambda: ui.VStack(ui.Button("show", on_click=lambda: open_.set(True)),
                                  ui.Sheet(ui.Text("inside"), open=open_, title="S")))
    assert dom.find("Sheet")["p"]["open"] is False
    h.fire(dom.find("Button"), "click")
    assert dom.find("Sheet")["p"]["open"] is True
    n = len(dom.ops)
    h.fire(dom.find("Sheet"), "dismiss")
    assert open_.peek() is False
    assert h.ops_since(n) == []  # the page already closed it


def test_tabs(h):
    sel = ui.signal(0)
    dom = h.run(lambda: ui.TabView(ui.Tab("A", "a"), ui.Tab("B", "b"), selected=sel))
    h.fire(dom.find("TabView"), "change", 1)
    assert sel.peek() == 1
    sel.set(0)
    h.flush()
    assert dom.find("TabView")["p"]["selected"] == 0


def test_canvas_records_and_redraws(h):
    x = ui.signal(10)

    def draw(p):
        p.clear("white")
        p.fill_style = "red"
        p.fill_rect(x(), 0, 5, 5)

    dom = h.run(lambda: ui.Canvas(draw, width=100, height=50))
    c = dom.find("Canvas")
    assert c["p"]["cmds"] == [["$clear", "white"], ["=", "fillStyle", "red"], ["fillRect", 10, 0, 5, 5]]
    x.set(20)
    h.flush()
    assert c["p"]["cmds"][-1] == ["fillRect", 20, 0, 5, 5]


def test_canvas_frames_are_acked(h):
    t = ui.signal(0.0)
    dom = h.run(lambda: ui.Canvas(lambda p: p.fill_rect(t(), 0, 1, 1), on_frame=lambda dt: t.update(lambda v: v + dt)))
    h.fire(dom.find("Canvas"), "frame", 16)
    assert ("frame", dom.find("Canvas")["i"]) in dom.calls
    assert dom.find("Canvas")["p"]["cmds"] == [["fillRect", 16, 0, 1, 1]]


def test_untracked_read_hint(h, capsys):
    n = ui.signal(1)
    h.run(lambda: ui.Text(f"{n()}"))
    err = capsys.readouterr().err
    assert "ui hint" in err and "test_tree.py" in err
    # Reads in handlers and in lambdas are fine.
    h.run(lambda: ui.Button(lambda: f"{n()}", on_click=lambda: n.set(n() + 1)))
    h.fire(ui._app.root.parts[0], "click")
    assert capsys.readouterr().err == ""


def test_handler_errors_keep_the_app_alive(h, capsys):
    n = ui.signal(0)

    def boom():
        n.set(1)
        raise ValueError("nope")

    dom = h.run(lambda: ui.VStack(ui.Button("x", on_click=boom), ui.Text(n)))
    h.fire(dom.find("Button"), "click")
    err = capsys.readouterr().err
    assert "ValueError: nope" in err and "ui.py" not in err
    assert dom.text().endswith("1")


def test_element_cannot_be_used_twice(h):
    t = ui.Text("x")
    ui.VStack(t)
    with pytest.raises(ValueError):
        ui.VStack(t)


def test_run_again_replaces_the_app(h):
    cleaned = []

    def App():
        ui.on_cleanup(lambda: cleaned.append(1))
        return ui.Text("one")

    dom = h.run(App)
    h.run(lambda: ui.Text("two"))
    assert dom.text() == "two" and cleaned == [1]


def test_close_button_config_and_close(h):
    dom = h.run(lambda: ui.Text("x"))
    assert dom.config["close_button"] is True
    assert dom.config["full_screen"] is False
    assert h.run(lambda: ui.Text("x"), full_screen=True).config["full_screen"] is True
    dom = h.run(lambda: ui.Button("Quit", on_click=ui.close), close_button=False)
    assert dom.config["close_button"] is False
    n = len(dom.ops)
    h.fire(dom.find("Button"), "click")
    assert h.ops_since(n) == [["close"]]
    n = len(dom.ops)
    ui.close()
    assert h.ops_since(n) == [["close"]]


def test_on_mount_runs_after_first_flush(h):
    seen = []

    def App():
        ui.on_mount(lambda: seen.append(len(h.dom.messages)))
        return ui.Text("x")

    h.run(App)
    assert seen == [1]


def test_dialogs_resolve():
    async def main():
        from conftest import Harness

        ui._rt = ui._Runtime()
        ui._app = ui._App()
        hh = Harness()
        result = {}

        async def ask():
            result["ok"] = await ui.confirm("Sure?")

        dom = hh.run(lambda: ui.Button("go", on_click=ask))
        hh.fire(dom.find("Button"), "click")
        await asyncio.sleep(0)
        hh.flush()
        kind, i, spec = dom.calls[-1]
        assert kind == "dialog" and spec["title"] == "Sure?"
        hh.fire(0, "dialog", i, True)
        await asyncio.sleep(0)
        assert result == {"ok": True}

    asyncio.run(main())


def test_image_sources(h, tmp_path):
    png = b"\x89PNG\r\n\x1a\n" + b"0" * 10
    path = tmp_path / "pic.png"
    path.write_bytes(png)
    dom = h.run(lambda: ui.VStack(ui.Image(str(path)), ui.Image("https://x/y.png"), ui.Image(png)))
    srcs = [n["p"]["src"] for n in dom.find_all("Image")]
    assert srcs[0].startswith("data:image/png;base64,")
    assert srcs[1] == "https://x/y.png"
    assert srcs[2] == srcs[0]


def test_resync_sends_a_full_snapshot(h):
    items = ui.store(["a", "b"])
    dom = h.run(lambda: ui.VStack(ui.For(items, ui.Text), ui.Text(lambda: str(len(items)))))
    items.append("c")
    h.flush()
    before = dom.text()
    fresh = type(dom)()
    ui._app.host = fresh
    h.dom = fresh
    h.fire(0, "resync")
    assert fresh.ops[0] == ["reset"] and fresh.text() == before == "abc3"
    items.remove("a")  # and it keeps working incrementally afterwards
    h.flush()
    assert fresh.text() == "bc2"
