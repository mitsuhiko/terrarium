import SafariServices
import UIKit

/// The device modules' native side (D40): clipboard, dialogs, console
/// services, keychain, notifications, photos, location, motion, sound,
/// speech, contacts and reminders. Python (web/public/runtime/python/*.py)
/// makes one blocking call per function; it arrives here as a `device.*`
/// bridge op from the engine page.
///
/// Values are JSON-ish. Files are references: `{"project": <path>}` in the
/// program's mounted folder (`_mount` is its token) or `{"data": <base64>,
/// "name": ...}`. Errors start with a Python exception name
/// ("PermissionError: ...") that `_device.py` raises as such.
///
/// Anything a program left on screen (a dialog it was waiting for when it was
/// stopped, the activity spinner) goes when the program ends; sensors,
/// sounds, speech and recordings stop when the next program starts.
@MainActor
final class DeviceBridge {
    struct Failure: LocalizedError {
        let kind: String
        let message: String
        var errorDescription: String? { "\(kind): \(message)" }

        static func permission(_ what: String) -> Failure {
            Failure(kind: "PermissionError", message: "\(what) is not allowed. You can change this in the Settings app under Terrarium.")
        }
        static func value(_ message: String) -> Failure { Failure(kind: "ValueError", message: message) }
        static func io(_ message: String) -> Failure { Failure(kind: "IOError", message: message) }
    }

    weak var model: AppModel?
    let hostFS: HostFS
    lazy var media = DeviceMedia(bridge: self)
    lazy var sensors = DeviceSensors()
    lazy var audio = DeviceAudio(bridge: self)
    lazy var pim = DevicePIM(bridge: self)
    lazy var dialogs = DeviceDialogs(bridge: self)

    /// Modal UI a program waits for: how to end it (as cancelled) when the program ends.
    private var active: [UUID: () -> Void] = [:]
    /// The newest modal first, for the self-test's answers.
    private var answerers: [(UUID, (Any?) -> Void)] = []

    init(hostFS: HostFS) {
        self.hostFS = hostFS
    }

    func handle(_ op: String, _ value: [String: Any], reply: @escaping WebHost.Reply) {
        Task {
            do {
                let result = try await perform(String(op.dropFirst("device.".count)), value)
                reply(result ?? NSNull(), nil)
            } catch {
                reply(nil, (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    private func perform(_ op: String, _ v: [String: Any]) async throws -> Any? {
        // From the engine: a program starts, or one ended.
        if op == "reset" { reset(); return nil }
        if op == "ended" { programEnded(); return nil }
        let area = op.split(separator: ".").first.map(String.init) ?? op
        switch area {
        case "clipboard", "photos": return try await media.perform(op, v)
        case "location", "motion", "haptics": return try await sensors.perform(op, v)
        case "sound", "speech": return try await audio.perform(op, v)
        case "keychain", "notification", "contacts", "reminders": return try await pim.perform(op, v)
        default: return try await dialogs.perform(op, v)
        }
    }

    // MARK: lifecycle

    /// The program ended (or was stopped): nothing it showed stays.
    func programEnded() {
        for (_, cancel) in active { cancel() }
        active = [:]
        answerers = []
        dialogs.programEnded()
    }

    /// A new program starts: what the last one started stops.
    func reset() {
        programEnded()
        sensors.reset()
        audio.reset()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: presenting

    var presenter: UIViewController? { model?.host.presenter() }

    /// Present a view controller the program waits for. `make` gets the
    /// function that ends the wait; dismissing (or the program ending) ends it
    /// with nil.
    func modal(_ make: (@escaping (Any?) -> Void) -> UIViewController) async -> Any? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Unchecked, Never>) in
            let id = UUID()
            var done = false
            var controller: UIViewController?
            let finish: (Any?) -> Void = { [weak self] value in
                guard !done else { return }
                done = true
                self?.active[id] = nil
                self?.answerers.removeAll { $0.0 == id }
                // Also when it is still coming up, or not up yet (Modal).
                if let controller { Modal.dismiss(controller) }
                continuation.resume(returning: Unchecked(value: value))
            }
            let vc = make(finish)
            controller = vc
            // Swiping a sheet away cancels (alerts can't be swiped, and refuse a delegate).
            if !(vc is UIAlertController) {
                let observer = DismissObserver { finish(nil) }
                vc.presentationController?.delegate = observer
                objc_setAssociatedObject(vc, &DismissObserver.key, observer, .OBJC_ASSOCIATION_RETAIN)
            }
            active[id] = { finish(nil) }
            answerers.insert((id, finish), at: 0)
            Modal.present(vc, from: { [weak self] in self?.presenter }, failed: { finish(nil) })
        }.value
    }

    /// The self-test answers the newest dialog (as if the user had).
    func testAnswer(_ value: Any?) -> Bool {
        guard let (_, finish) = answerers.first else { return false }
        finish(value)
        return true
    }

    var testHasDialog: Bool { !answerers.isEmpty }

    // MARK: files

    func fileURL(_ ref: Any?, mount: String?) throws -> URL {
        guard let ref = ref as? [String: Any] else { throw Failure.value("no file") }
        if let rel = ref["project"] as? String {
            guard let mount, let url = hostFS.url(token: mount, relative: rel) else { throw Failure.io("\(rel) is not in the program's folder") }
            guard FileManager.default.fileExists(atPath: url.path) else { throw Failure(kind: "FileNotFoundError", message: rel) }
            return url
        }
        guard let b64 = ref["data"] as? String, let data = Data(base64Encoded: b64) else { throw Failure.value("no file data") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("device-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent((ref["name"] as? String).flatMap { $0.isEmpty ? nil : ($0 as NSString).lastPathComponent } ?? "file")
        try data.write(to: url)
        return url
    }

    func fileData(_ ref: Any?, mount: String?) throws -> Data {
        try Data(contentsOf: fileURL(ref, mount: mount))
    }

    /// Where to write a file for the program, and how to tell it afterwards.
    func target(_ ref: Any?, mount: String?) throws -> (url: URL, done: () -> Void) {
        guard let ref = ref as? [String: Any], let rel = ref["project"] as? String, let mount,
              let url = hostFS.url(token: mount, relative: rel) else { throw Failure.io("the file must be in the program's folder") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let hostFS = hostFS
        return (url, { hostFS.wroteNatively(token: mount, relative: rel) })
    }

    // MARK: links

    func openURL(_ string: String) async -> Bool {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "http" || scheme == "https" {
            let safari = SFSafariViewController(url: url)
            Modal.present(safari, from: { [weak self] in self?.presenter })
            return true
        }
        if let action = LaunchAction(url: url) {
            LaunchRouter.send(action)
            return true
        }
        return await UIApplication.shared.open(url)
    }
}

/// Ends a modal's wait when the user swipes its sheet away.
final class DismissObserver: NSObject, UIAdaptivePresentationControllerDelegate {
    nonisolated(unsafe) static var key: UInt8 = 0
    let onDismiss: () -> Void
    init(_ onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { onDismiss() }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func double(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
    func int(_ key: String) -> Int? { (self[key] as? NSNumber)?.intValue }
    func bool(_ key: String) -> Bool? { (self[key] as? NSNumber)?.boolValue }
    var mount: String? { self["_mount"] as? String }
}

enum ISODate {
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Python's isoformat() (naive: local time; with an offset: that one).
    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = withFraction.date(from: s) ?? ISO8601DateFormatter().date(from: s) { return d }
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    /// Local time without an offset, which Python reads as a naive datetime.
    static func format(_ d: Date?) -> Any {
        guard let d else { return NSNull() }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: d)
    }
}
