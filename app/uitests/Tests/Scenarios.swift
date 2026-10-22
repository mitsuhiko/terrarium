import XCTest

/// The wide layout's transitions, each repeated TIMES times (ONLY=a,b picks
/// some): after each, editor tabs on screen come with an editor. With FAST=1
/// the taps come during the animations.
final class Scenarios: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: bundleID)
    let report = Report()
    var snaps: [Snap] = []
    var bounds = CGRect.zero

    func refresh() {
        snaps = app.snaps()
        bounds = snaps.first?.frame ?? app.frame
    }

    func tap(_ labels: [String]) -> String? {
        refresh()
        guard let b = snaps.buttons(labels, in: bounds).first else { return nil }
        app.tap(b)
        return b.label
    }

    func split() -> String? {
        refresh()
        guard let b = snaps.filter({ $0.type == .button && ($0.identifier == "rectangle.split.2x1" || ($0.identifier == "xmark" && $0.label == "Close Split View")) })
            .visible(in: bounds).first else { return nil }
        app.tap(b)
        return b.label
    }

    /// The other half's icon for `role` (D61): shows it there, or hides the half if it shows it.
    func icon(_ role: String) -> String? {
        refresh()
        guard let icon = snaps.halfIcons(in: bounds).first(where: { $0.label == role }) else { return nil }
        app.tap(icon)
        return "\(role)\(icon.value == "shown" ? " (hide)" : "")"
    }

    /// The half shown on `role` (a tap only if it isn't).
    func show(_ role: String) {
        refresh()
        if let icon = snaps.halfIcons(in: bounds).first(where: { $0.label == role }), icon.value != "shown" { app.tap(icon) }
    }

    /// An item of the half's icons' long-press menu (Layout).
    func layout(_ items: [String]) -> String? {
        refresh()
        guard let icon = snaps.halfIcons(in: bounds).first else { return nil }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: icon.frame.midX, dy: icon.frame.midY)).press(forDuration: 1)
        Thread.sleep(forTimeInterval: 0.6)
        return tap(items) ?? { _ = tap(["Cancel"]); app.tap(at: CGPoint(x: bounds.midX, y: bounds.maxY - 20)); return nil }()
    }

    var editorOK: Bool {
        refresh()
        if !snaps.editorTabsShown(in: bounds) || !snaps.editorWebViews.isEmpty { return true }
        Thread.sleep(forTimeInterval: 2)
        refresh()
        return !snaps.editorTabsShown(in: bounds) || !snaps.editorWebViews.isEmpty
    }

    let halves = ["Console", "Agent", "App", "Docs"]

    /// The half shown with the console, after the editor, no split, the code in the main half.
    func reset() {
        if split() == "Close Split View" { Thread.sleep(forTimeInterval: 0.5) }
        _ = tap(["Show Code"])
        show("Console")
        refresh()
        if snaps.buttons(["Move to the Right", "Move to the Bottom"], in: bounds).isEmpty {
            _ = layout(["Move to the Right", "Move to the Bottom"])
        }
        _ = tap(["Close the sidebar"])
        Thread.sleep(forTimeInterval: 0.5)
    }

    func scenario(_ name: String, _ times: Int, _ body: (Int) -> String?) {
        if let only = env["ONLY"], !only.split(separator: ",").contains(Substring(name)) { return }
        report.step += 1
        reset()
        guard editorOK else { report.anomaly("\(name): no editor before it started"); return }
        for i in 0..<times {
            guard let what = body(i) else { continue }
            if env["FAST"] != nil && i % 4 != 3 && i != times - 1 { continue }
            if env["FAST"] != nil { Thread.sleep(forTimeInterval: 1.5) }
            if !editorOK { report.anomaly("EDITOR GONE in \(name) #\(i) after \(what)"); reset(); return }
        }
        report.note("\(name) ok")
    }

    func testScenarios() throws {
        app.activate()
        if env["FAST"] != nil { disableQuiescence() }
        let n = Int(env["TIMES"] ?? "8") ?? 8
        let moves = ["Move to the Left", "Move to the Right", "Move to the Top", "Move to the Bottom"]
        let swaps = ["Show the App in the Main Half", "Show the Code in the Main Half"]

        scenario("swapApp", n) { i in
            if i == 0 { show("App") }
            return layout(swaps) ?? tap(["Show Code"])
        }
        scenario("split", n) { _ in split() }
        scenario("splitSwap", n) { i in
            if i % 2 == 0 { return split() }
            show("App")
            return layout(swaps) ?? tap(["Show Code"])
        }
        scenario("files", n) { _ in tap(["Hide Files", "Show Files", "Close the sidebar"]) }
        scenario("half", n) { i in icon(halves[i % 4]) ?? icon(halves[0]) }
        scenario("hideHalf", n) { _ in icon("Console") }
        scenario("move", n) { _ in layout(moves) }
        scenario("moveSplit", n) { i in i % 2 == 0 ? split() : layout(moves) }
        scenario("tabs", n) { i in
            refresh()
            let tabs = snaps.filter { $0.type == .staticText && $0.frame.minY < 80 && $0.label.contains(".") }.visible(in: bounds)
            guard tabs.count > 1 else { return nil }
            let t = tabs[i % tabs.count]
            app.tap(t)
            return t.label
        }
        scenario("filesSplit", n) { i in i % 2 == 0 ? tap(["Hide Files", "Show Files", "Close the sidebar"]) : split() }
        scenario("halfSplit", n) { i in i % 2 == 0 ? icon("Console") : split() }
        scenario("navigator", n) { i in
            _ = tap(["Show Files"])
            return tap([["Files", "Outline", "Find", "Problems"][i % 4]])
        }
        scenario("background", n / 2) { i in
            if i % 2 == 0 { _ = split() }
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 1.5)
            app.activate()
            Thread.sleep(forTimeInterval: 1)
            return "home and back"
        }
        reset()
        report.finish()
    }
}
