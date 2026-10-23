import XCTest

/// Steps from SCRIPT, separated by ";": tap:<label>, tapid:<identifier>,
/// rotate:<portrait|landscapeLeft|landscapeRight>, wait:<seconds>,
/// shot:<name>. For screenshots of a state (run.sh script "...").
final class Script: XCTestCase {
    func testScript() throws {
        let app = XCUIApplication(bundleIdentifier: bundleID)
        let report = Report()
        app.activate()
        for (i, step) in (env["SCRIPT"] ?? "").split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }).enumerated() {
            report.step = i
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let (op, arg) = (parts[0], parts[1])
            switch op {
            case "tap", "tapid":
                var found: Snap?
                for _ in 0..<20 {
                    let snaps = app.snaps()
                    let bounds = snaps.first { $0.type == .window }?.frame ?? snaps.first?.frame ?? app.frame
                    found = snaps.filter { op == "tap" ? $0.label == arg : $0.identifier == arg }.visible(in: bounds).first
                    if found != nil { break }
                    Thread.sleep(forTimeInterval: 0.25)
                }
                if let found {
                    // By the element where XCTest can (its coordinates are off on an open Duo's inner screen).
                    let el = app.descendants(matching: .any).matching(NSPredicate(format: op == "tap" ? "label == %@" : "identifier == %@", arg)).firstMatch
                    if el.exists, el.isHittable { el.tap() } else { app.tap(found) }
                    report.note("tapped \(arg)")
                } else { report.anomaly("no \(arg) to tap") }
            case "rotate":
                let o: [String: UIDeviceOrientation] = ["portrait": .portrait, "landscapeLeft": .landscapeLeft, "landscapeRight": .landscapeRight]
                XCUIDevice.shared.orientation = o[arg] ?? .portrait
            case "wait":
                Thread.sleep(forTimeInterval: Double(arg) ?? 1)
            case "shot":
                report.shot(arg)
            default:
                report.anomaly("unknown step \(step)")
            }
        }
        report.finish()
    }
}
