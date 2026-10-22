import XCTest

/// Random taps on what the app shows, seeded (SEED, STEPS; FAST=1 taps
/// without waiting for animations). After every step: the app answers within
/// a few seconds, and editor tabs on screen come with an editor (its web
/// view); every 15 steps a round trip through the ⋯ menu and Settings shows
/// that taps still land. Works in the narrow and the wide layout.
final class Monkey: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: bundleID)
    let report = Report()
    var rng = SplitMix(seed: 1)
    var bounds = CGRect.zero
    var snaps: [Snap] = []
    var editorGone = false

    /// Example programs that end or idle on their own, ask nothing and need no permission.
    let programs = ["Counter App.py", "Navigation.py", "Tabs.py", "Todo App.py", "Game of Life.py", "Bounce.py",
                    "Hello.py", "Countdown.py", "Turtle.py", "Settings.py", "Mandelbrot.py", "Async.py", "Start Here.md", "Plot.py"]

    override func setUp() {
        continueAfterFailure = true
        rng = SplitMix(seed: UInt64(env["SEED"] ?? "1") ?? 1)
    }

    func refresh() -> TimeInterval {
        let t = Date()
        snaps = app.snaps()
        bounds = snaps.first?.frame ?? app.frame
        return Date().timeIntervalSince(t)
    }

    func buttons(_ labels: String...) -> [Snap] { snaps.buttons(labels, in: bounds) }

    @discardableResult
    func tapFirst(_ labels: [String]) -> String? {
        guard let b = snaps.buttons(labels, in: bounds).first else { return nil }
        app.tap(b)
        return b.label
    }

    // MARK: actions

    typealias Action = (name: String, weight: Int, run: () -> String?)

    lazy var actions: [Action] = [
        ("panelRole", 8, { [unowned self] in
            let role = rng.pick(["Console", "Agent", "App", "Docs"])
            guard let seg = snaps.filter({ $0.type == .button && $0.label == role && $0.frame.width > 36 && $0.frame.width < 60 && $0.identifier != "" })
                .visible(in: bounds).first(where: { s in snaps.contains { $0.type == .segmentedControl && $0.frame.contains(CGPoint(x: s.frame.midX, y: s.frame.midY)) } })
            else { return nil }
            app.tap(seg); return role
        }),
        ("toggleHalf", 7, { [unowned self] in
            tapFirst(["Console", "Agent", "App", "Docs"].flatMap { ["Hide \($0)", "Show \($0)"] })
        }),
        ("toggleFiles", 5, { [unowned self] in tapFirst(["Hide Files", "Show Files", "Hide Sidebar", "Show Sidebar"]) }),
        ("moveHalf", 5, { [unowned self] in tapFirst(["Move to the left", "Move to the right", "Move to the top", "Move to the bottom"]) }),
        ("swapApp", 3, { [unowned self] in tapFirst(["Show the app in the main half", "Show the code in the main half", "Show Code"]) }),
        ("split", 4, { [unowned self] in
            guard let b = snaps.filter({ $0.type == .button && ($0.identifier == "rectangle.split.2x1" || ($0.identifier == "xmark" && $0.label == "Close Split View")) })
                .visible(in: bounds).first else { return nil }
            app.tap(b); return b.label
        }),
        ("openFile", 9, { [unowned self] in
            let name = rng.pick(programs)
            let rows = snaps.filter { $0.type == .button && ($0.label.hasPrefix(name + ",") || $0.label.hasPrefix("Examples,")) }.visible(in: bounds)
            guard let row = rows.first(where: { $0.label.hasPrefix(name + ",") }) ?? rows.first else { return nil }
            app.tap(row); return String(row.label.prefix(while: { $0 != "," }))
        }),
        ("back", 4, { [unowned self] in
            guard let b = snaps.filter({ $0.type == .button && $0.identifier == "BackButton" }).visible(in: bounds).first else { return nil }
            app.tap(b); return "back"
        }),
        ("tab", 5, { [unowned self] in
            let tabs = snaps.filter { $0.type == .staticText && $0.frame.minY < 80 && $0.label.contains(".") && $0.frame.height < 30 }.visible(in: bounds)
            guard !tabs.isEmpty else { return nil }
            let t = rng.pick(tabs); app.tap(t); return t.label
        }),
        ("closeTab", 1, { [unowned self] in
            let xs = snaps.filter { $0.type == .button && $0.identifier == "xmark" && $0.label.hasPrefix("Close ") && $0.label.contains(".") }.visible(in: bounds)
            guard !xs.isEmpty else { return nil }
            let x = rng.pick(xs); app.tap(x); return x.label
        }),
        ("run", 6, { [unowned self] in
            guard let b = snaps.filter({ $0.type == .button && $0.identifier == "play.fill" }).visible(in: bounds).first else { return nil }
            app.tap(b); return "run"
        }),
        ("stop", 2, { [unowned self] in tapFirst(["Stop", "Pause"]) }),
        ("appSize", 3, { [unowned self] in tapFirst(["Show the app full screen", "Show Next to the Code", "Full Screen"]) }),
        ("closeApp", 3, { [unowned self] in tapFirst(["Close"]) }),
        ("agent", 3, { [unowned self] in
            guard let b = snaps.filter({ $0.type == .button && $0.identifier == "sparkles" && $0.label == "Agent" && $0.frame.width < 40 }).visible(in: bounds).last else { return nil }
            app.tap(b); return "agent"
        }),
        ("dragDivider", 2, { [unowned self] in
            guard let d = snaps.filter({ $0.label == "Resize split view" }).visible(in: bounds).first else { return nil }
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: d.frame.midX, dy: d.frame.midY))
            let dx = CGFloat(Int(rng.next() % 400)) - 200
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: dx, dy: 0)))
            return "drag \(Int(dx))"
        }),
        ("console", 2, { [unowned self] in
            guard let f = snaps.filter({ $0.type == .textField }).visible(in: bounds).first else { return nil }
            app.tap(f)
            // Typing needs the keyboard focus, which a tap during an animation may not give.
            let field = app.textFields.firstMatch
            for _ in 0..<10 where (field.value(forKey: "hasKeyboardFocus") as? Bool) != true { Thread.sleep(forTimeInterval: 0.2) }
            guard (field.value(forKey: "hasKeyboardFocus") as? Bool) == true else { return "no focus" }
            field.typeText("1+\(report.step)\n")
            return "typed"
        }),
        ("menu", 4, { [unowned self] in
            guard let more = buttons("More").first else { return nil }
            app.tap(more)
            Thread.sleep(forTimeInterval: 0.6)
            _ = refresh()
            let item = rng.pick(["Go to…", "Python Docs", "Split View", "Close Split View", "Settings…", "Show Info", "Find", "Format Code"])
            if let e = buttons(item).first { app.tap(e); return item }
            dismissAll()
            return "menu without \(item)"
        }),
        ("tapEditor", 2, { [unowned self] in
            guard let e = snaps.first(where: { $0.type == .textView && $0.label == "Code editor" && bounds.intersects($0.frame) }) else { return nil }
            let r = e.frame.intersection(bounds)
            app.tap(at: CGPoint(x: r.midX, y: r.minY + min(r.height / 2, 120)))
            return "editor"
        }),
        ("dismiss", 4, { [unowned self] in dismissAll() }),
        ("randomTap", 3, { [unowned self] in
            let p = CGPoint(x: bounds.width * (0.05 + 0.9 * rng.unit()), y: bounds.height * (0.08 + 0.84 * rng.unit()))
            app.tap(at: p)
            return "tap \(Int(p.x)),\(Int(p.y))"
        }),
        ("background", 1, { [unowned self] in
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 1.5)
            app.activate()
            return "home and back"
        }),
        ("rotate", env["ROTATE"] == nil ? 0 : 3, {
            let o: [UIDeviceOrientation] = [.portrait, .landscapeLeft, .landscapeRight, .portraitUpsideDown]
            let next = o[Int.random(in: 0..<o.count)]
            XCUIDevice.shared.orientation = next
            return "orientation \(next.rawValue)"
        }),
    ]

    /// Closes sheets, alerts and menus (Done, Cancel, a tap outside a popover).
    @discardableResult
    func dismissAll() -> String {
        var did: [String] = []
        for _ in 0..<4 {
            _ = refresh()
            if let b = buttons("Done", "Cancel", "OK").first { app.tap(b); did.append(b.label); Thread.sleep(forTimeInterval: 0.4); continue }
            if let region = snaps.first(where: { $0.identifier == "PopoverDismissRegion" }) {
                app.tap(region); did.append("popover"); Thread.sleep(forTimeInterval: 0.4); continue
            }
            break
        }
        return did.isEmpty ? "nothing" : did.joined(separator: ",")
    }

    // MARK: checks

    func checkAfter(_ what: String) {
        let dt = refresh()
        if dt > 4 { report.anomaly("slow: \(String(format: "%.1f", dt)) s for a snapshot after \(what)") }
        if snaps.editorTabsShown(in: bounds) && snaps.editorWebViews.isEmpty {
            Thread.sleep(forTimeInterval: 2) // a transition
            _ = refresh()
            if snaps.editorTabsShown(in: bounds) && snaps.editorWebViews.isEmpty {
                if !editorGone { report.anomaly("EDITOR GONE after \(what)") }
                editorGone = true
                return
            }
        }
        if editorGone { report.note("editor back after \(what)") }
        editorGone = false
    }

    /// Taps still land: ⋯, Settings…, Done (where there is a ⋯ to tap).
    func roundTrip() {
        dismissAll()
        _ = refresh()
        if !buttons("Close").isEmpty { report.note("check: an app over everything"); return }
        guard let more = buttons("More").first else {
            // The editor always has one (the file browser's folders may not).
            if snaps.contains(where: { $0.type == .button && $0.identifier == "play.fill" }) { report.anomaly("no ⋯ next to Run") }
            return
        }
        app.tap(more)
        var ok = false
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.3)
            _ = refresh()
            if let s = buttons("Settings…").first { app.tap(s); ok = true; break }
        }
        guard ok else { report.anomaly("⋯ did not open its menu"); dismissAll(); return }
        for _ in 0..<15 {
            Thread.sleep(forTimeInterval: 0.3)
            _ = refresh()
            if let done = buttons("Done").first { app.tap(done); report.note("check ok"); return }
        }
        report.anomaly("Settings did not open")
    }

    func testMonkey() throws {
        let steps = Int(env["STEPS"] ?? "200") ?? 200
        app.activate()
        if env["FAST"] != nil { disableQuiescence() }
        let usable = actions.filter { $0.weight > 0 }
        let total = usable.reduce(0) { $0 + $1.weight }
        _ = refresh()
        report.shot("start")
        for i in 0..<steps {
            report.step = i
            if app.state != .runningForeground {
                report.anomaly("app not in the foreground (state \(app.state.rawValue))")
                app.activate()
            }
            var r = Int(rng.next() % UInt64(total))
            var chosen = usable[0]
            for a in usable { if r < a.weight { chosen = a; break }; r -= a.weight }
            let t = Date()
            let result = chosen.run()
            report.note(String(format: "%@: %@ (%.2f s)", chosen.name, result ?? "skip", Date().timeIntervalSince(t)))
            if result != nil { checkAfter("\(chosen.name): \(result!)") } else { _ = refresh() }
            if i % 15 == 14 { roundTrip(); report.shot("periodic") }
        }
        report.finish()
    }
}

/// The hierarchy as XCTest sees it, into OUT/tree.txt.
final class Dump: XCTestCase {
    func testTree() throws {
        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.activate()
        let out = env["OUT"] ?? NSTemporaryDirectory()
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try app.debugDescription.write(toFile: "\(out)/tree.txt", atomically: true, encoding: .utf8)
    }
}
