import ObjectiveC
import XCTest

// Helpers for driving Terrarium from outside (it is installed by app/run.sh;
// these tests only attach to it by bundle ID).

let bundleID = "eu.ronacher.Terrarium"
let env = ProcessInfo.processInfo.environment

/// One element of a hierarchy snapshot: read once, no live queries (which
/// race with the app and fail the test when an element goes away).
struct Snap {
    let type: XCUIElement.ElementType
    let label: String
    let identifier: String
    let frame: CGRect
}

extension XCUIApplication {
    /// The whole hierarchy, flattened (empty if the app does not answer).
    func snaps() -> [Snap] {
        guard let root = try? snapshot() else { return [] }
        var out: [Snap] = []
        func walk(_ s: XCUIElementSnapshot) {
            out.append(Snap(type: s.elementType, label: s.label, identifier: s.identifier, frame: s.frame))
            s.children.forEach(walk)
        }
        walk(root)
        return out
    }

    /// Taps a point in the app's coordinates (whatever is there takes it).
    func tap(at p: CGPoint) {
        coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p.x, dy: p.y)).tap()
    }

    func tap(_ s: Snap) { tap(at: CGPoint(x: s.frame.midX, y: s.frame.midY)) }
}

extension Array where Element == Snap {
    /// On screen and big enough to tap.
    func visible(in bounds: CGRect) -> [Snap] {
        filter { !$0.frame.isEmpty && $0.frame.width > 2 && bounds.insetBy(dx: -1, dy: -1).contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
    }

    func buttons(_ labels: [String], in bounds: CGRect) -> [Snap] {
        filter { $0.type == .button && labels.contains($0.label) }.visible(in: bounds)
    }

    /// Editor tabs are on screen (a tab's close button in the tab strip).
    func editorTabsShown(in bounds: CGRect) -> Bool {
        let ext = [".py", ".md", ".txt", ".ipynb", ".toml", ".json", ".csv"]
        return contains { s in
            s.type == .button && s.identifier == "xmark" && s.label.hasPrefix("Close ") && ext.contains { s.label.hasSuffix($0) }
                && s.frame.midX > 0 && s.frame.midX < bounds.maxX && s.frame.minY >= 0 && s.frame.maxY < bounds.maxY
        }
    }

    /// Web views big enough to be an editor (the engine's is 1x1).
    var editorWebViews: [Snap] { filter { $0.type == .webView && $0.frame.width > 50 && $0.frame.height > 50 } }
}

/// Seeded random numbers: a run is reproducible from its seed.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func pick<T>(_ xs: [T]) -> T { xs[Int(next() % UInt64(xs.count))] }
    mutating func unit() -> Double { Double(next() % 10_000) / 10_000 }
}

/// Run log and screenshots. Screenshots are taken by run.sh on the host
/// (XCUIScreen's come out black on the iPhone Duo's inner screen): the test
/// drops a request file and waits a moment.
final class Report {
    let out: String
    private let file: FileHandle?
    var step = 0
    var anomalies: [String] = []
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    init() {
        out = env["OUT"] ?? NSTemporaryDirectory()
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(out)/log.txt", contents: nil)
        file = FileHandle(forWritingAtPath: "\(out)/log.txt")
    }

    func note(_ s: String) {
        let line = String(format: "%@ %04d %@\n", Report.time.string(from: Date()), step, s)
        print("UITEST " + line, terminator: "")
        file?.write(line.data(using: .utf8)!)
    }

    func shot(_ name: String) {
        FileManager.default.createFile(atPath: "\(out)/req-\(String(format: "%04d", step))-\(name)", contents: nil)
        Thread.sleep(forTimeInterval: 1.2)
    }

    func anomaly(_ s: String) {
        anomalies.append(String(format: "%04d %@", step, s))
        note("ANOMALY " + s)
        shot("anomaly")
    }

    func finish() {
        note("DONE anomalies=\(anomalies.count)")
        try? anomalies.joined(separator: "\n").write(toFile: "\(out)/anomalies.txt", atomically: true, encoding: .utf8)
    }
}

/// Taps without waiting for the app to settle (animations, idle), like a
/// quick finger: FAST=1. Swaps out XCTest's private quiescence waits.
func disableQuiescence() {
    for name in ["XCUIApplicationProcess", "XCUIApplicationImpl"] {
        guard let cls = NSClassFromString(name) else { continue }
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { continue }
        for i in 0..<Int(count) {
            let m = methods[i]
            let sel = NSStringFromSelector(method_getName(m))
            guard sel.hasPrefix("waitForQuiescence") else { continue }
            let imp: IMP
            switch sel.filter({ $0 == ":" }).count {
            case 0: imp = imp_implementationWithBlock({ (_: AnyObject) in } as @convention(block) (AnyObject) -> Void)
            case 1: imp = imp_implementationWithBlock({ (_: AnyObject, _: Bool) in } as @convention(block) (AnyObject, Bool) -> Void)
            default: imp = imp_implementationWithBlock({ (_: AnyObject, _: Bool, _: Bool) in } as @convention(block) (AnyObject, Bool, Bool) -> Void)
            }
            method_setImplementation(m, imp)
        }
        free(methods)
    }
}
