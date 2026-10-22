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

    func segment(_ role: String) -> String? {
        refresh()
        guard let seg = snaps.filter({ $0.type == .button && $0.label == role && $0.frame.width < 60 })
            .first(where: { s in snaps.contains { $0.type == .segmentedControl && $0.frame.contains(CGPoint(x: s.frame.midX, y: s.frame.midY)) } })
        else { return nil }
        app.tap(seg)
        return role
    }

    var editorOK: Bool {
        refresh()
        if !snaps.editorTabsShown(in: bounds) || !snaps.editorWebViews.isEmpty { return true }
        Thread.sleep(forTimeInterval: 2)
        refresh()
        return !snaps.editorTabsShown(in: bounds) || !snaps.editorWebViews.isEmpty
    }

    let halves = ["Console", "Agent", "App", "Docs"]

    /// The half shown with the console, after the editor, no split, files shown.
    func reset() {
        if split() == "Close Split View" { Thread.sleep(forTimeInterval: 0.5) }
        _ = tap(halves.map { "Show \($0)" })
        _ = tap(["Show the code in the main half", "Show Code"])
        _ = segment("Console")
        _ = tap(["Move to the right", "Move to the bottom"])
        _ = tap(["Show Files"])
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
        let toggles = halves.flatMap { ["Hide \($0)", "Show \($0)"] }
        let moves = ["Move to the left", "Move to the right", "Move to the top", "Move to the bottom"]
        let swaps = ["Show the app in the main half", "Show the code in the main half", "Show Code"]

        scenario("swapApp", n) { i in
            if i == 0 { _ = segment("App") }
            return tap(swaps)
        }
        scenario("split", n) { _ in split() }
        scenario("splitSwap", n) { i in
            if i % 2 == 0 { return split() }
            _ = segment("App")
            return tap(swaps)
        }
        scenario("files", n) { _ in tap(["Hide Files", "Show Files"]) }
        scenario("half", n) { _ in tap(toggles) }
        scenario("move", n) { _ in tap(moves) }
        scenario("moveSplit", n) { i in i % 2 == 0 ? split() : tap(moves) }
        scenario("roles", n * 2) { i in segment(halves[i % 4]) }
        scenario("tabs", n) { i in
            refresh()
            let tabs = snaps.filter { $0.type == .staticText && $0.frame.minY < 80 && $0.label.contains(".") }.visible(in: bounds)
            guard tabs.count > 1 else { return nil }
            let t = tabs[i % tabs.count]
            app.tap(t)
            return t.label
        }
        scenario("filesSplit", n) { i in i % 2 == 0 ? tap(["Hide Files", "Show Files"]) : split() }
        scenario("halfSplit", n) { i in i % 2 == 0 ? tap(toggles) : split() }
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
