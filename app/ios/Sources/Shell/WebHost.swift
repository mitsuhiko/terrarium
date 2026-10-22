import UIKit
import WebKit

/// The web views the app uses (D31): the engine page (Python and code
/// analysis, no UI) and one editor page per pane (CodeMirror). They all talk
/// to the host through the same bridge (`bridge`, with replies); the common
/// operations (files, linked folders, logging) are handled here and the rest
/// goes to the app model, with the role of the sender.
@MainActor
final class WebHost: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate {
    enum Role: Equatable {
        case engine
        case editor(Int)
    }

    typealias Reply = @MainActor @Sendable (Any?, String?) -> Void

    let schemeHandler = AppSchemeHandler(root: Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true))
    let files: FileStore
    /// File operations run here, off the main thread: reading a file in iCloud
    /// Drive may have to download it first. One queue keeps them in order.
    let fileQueue = DispatchQueue(label: "eu.ronacher.Terrarium.files", qos: .userInitiated)
    private var roles: [ObjectIdentifier: Role] = [:]
    /// Ops the common bridge does not know: (op, value, sender) -> reply.
    var handler: (String, [String: Any], Role, @escaping Reply) -> Void = { _, _, _, reply in reply(nil, "no handler") }
    /// Where native dialogs for JavaScript's alert/confirm/prompt are shown.
    var presenter: () -> UIViewController? = { nil }

    /// Python programs' files (D35), served to the workers through `/__fs`.
    let hostFS: HostFS

    init(files: FileStore) {
        self.files = files
        hostFS = HostFS(queue: fileQueue)
        super.init()
        schemeHandler.hostFS = hostFS
        hostFS.coordinator = { [files] source, target, isDirectory in
            try files.writeBack(source, to: target, isDirectory: isDirectory)
        }
    }

    func makeWebView(role: Role, page: String) -> WKWebView {
        let config = WKWebViewConfiguration()
        // The engine is never on screen: it must keep running anyway.
        config.preferences.inactiveSchedulingPolicy = .none
        config.setURLSchemeHandler(schemeHandler, forURLScheme: AppSchemeHandler.scheme)
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "bridge")
        let webView = CodeWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        roles[ObjectIdentifier(webView)] = role
        if case .editor = role { KeyboardAccessory.shared.install(on: webView) }
        webView.load(URLRequest(url: URL(string: "\(AppSchemeHandler.scheme)://app/\(page)")!))
        return webView
    }

    // MARK: bridge

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping Reply) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            replyHandler(nil, "malformed bridge message")
            return
        }
        guard let webView = message.webView, let role = roles[ObjectIdentifier(webView)] else {
            replyHandler(nil, "unknown web view")
            return
        }
        // Only the pages themselves: a notebook's HTML outputs with scripts run in
        // sandboxed frames, which must not reach the host (D44).
        guard message.frameInfo.isMainFrame else {
            replyHandler(nil, "not available in frames")
            return
        }
        let value = body["value"] as? [String: Any] ?? [:]
        if op.hasPrefix("hostfs.") {
            hostFSOperation(op, value, reply: replyHandler)
            return
        }
        if op.hasPrefix("fs.") {
            fileOperation(op, value.compactMapValues { $0 as? String }, reply: replyHandler)
            return
        }
        switch op {
        case "locations.list": replyHandler(files.locations.list(), nil)
        case "locations.remove":
            files.locations.remove(named: String((value["path"] as? String ?? "").dropFirst()))
            replyHandler(nil, nil)
        case "keyboard.mode":
            KeyboardAccessory.shared.webView = webView
            KeyboardAccessory.shared.setMode(KeyboardAccessory.Mode(rawValue: value["mode"] as? String ?? "") ?? .plain)
            replyHandler(nil, nil)
        case "keyboard.take":
            // The page is about to focus a field without a tap (D56).
            KeyboardAccessory.shared.webView = webView
            KeyboardAccessory.shared.takeKeyboard()
            replyHandler(nil, nil)
        case "echo": replyHandler(body["value"], nil)
        case "haptic":
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            replyHandler(nil, nil)
        case "log":
            Self.appendDocument(".probe-log.txt", "\(body["value"] ?? "")\n")
            replyHandler(nil, nil)
        case "result":
            try? (body["value"] as? String ?? "null").write(to: Self.documentURL(".probe-result.json"), atomically: true, encoding: .utf8)
            replyHandler(nil, nil)
        default:
            handler(op, value, role, replyHandler)
        }
    }

    private struct Result: @unchecked Sendable {
        let value: Any?
        let error: String?
    }

    /// Mounting a program's folder (staging a linked one can take a while),
    /// syncing it back, unmounting.
    private func hostFSOperation(_ op: String, _ value: [String: Any], reply: @escaping Reply) {
        let files = files, hostFS = hostFS
        fileQueue.async {
            let result: Result
            do {
                guard let coordinator = hostFS.coordinator else { throw FileStore.StoreError(description: "no coordinator") }
                switch op {
                case "hostfs.mount":
                    let path = value["path"] as? String ?? ""
                    let (url, linked) = try files.locate(path)
                    let mount = try hostFS.mount(appPath: path, url: url, linked: linked, share: value["share"] as? String) { try files.snapshot($0, into: $1) }
                    result = Result(value: mount, error: nil)
                case "hostfs.sync":
                    result = Result(value: hostFS.sync(value["token"] as? String ?? "", coordinate: coordinator), error: nil)
                case "hostfs.unmount":
                    result = Result(value: hostFS.unmount(value["token"] as? String ?? "", coordinate: coordinator), error: nil)
                default:
                    throw FileStore.StoreError(description: "unknown op \(op)")
                }
            } catch {
                result = Result(value: nil, error: "\(error)")
            }
            Task { @MainActor in reply(result.value, result.error) }
        }
    }

    /// Unmount every program's folder (the engine page went away).
    func unmountAll() {
        let hostFS = hostFS
        fileQueue.async {
            if let coordinator = hostFS.coordinator { hostFS.unmountAll(coordinate: coordinator) }
        }
    }

    /// Write staged changes back now (the app goes to the background).
    func syncMounts() {
        let hostFS = hostFS
        fileQueue.async {
            if let coordinator = hostFS.coordinator { hostFS.syncAll(coordinate: coordinator) }
        }
    }

    private func fileOperation(_ op: String, _ args: [String: String], reply: @escaping Reply) {
        let files = files
        // Programs' interpreters cache file contents: tell them about changes.
        if ["fs.write", "fs.mkdir", "fs.rename", "fs.delete"].contains(op) { hostFS.externalChange() }
        fileQueue.async {
            let result: Result
            do {
                result = Result(value: try Self.perform(files, op, args), error: nil)
            } catch {
                result = Result(value: nil, error: "\(error)")
            }
            Task { @MainActor in reply(result.value, result.error) }
        }
    }

    nonisolated private static func perform(_ files: FileStore, _ op: String, _ args: [String: String]) throws -> Any? {
        let str = { (key: String) in args[key] ?? "" }
        switch op {
        case "fs.list": return try files.list(str("path"))
        case "fs.read": return try files.read(str("path"), encoding: str("encoding"))
        case "fs.write": try files.write(str("path"), data: str("data"), encoding: str("encoding"))
        case "fs.mkdir": try files.mkdir(str("path"))
        case "fs.rename": try files.rename(from: str("from"), to: str("to"))
        case "fs.delete": try files.delete(str("path"))
        case "fs.exists": return try files.exists(str("path"))
        case "fs.stat": return try files.stat(str("path")) ?? NSNull()
        case "fs.tree": return try files.tree(str("path"))
        default: throw FileStore.StoreError(description: "unknown op \(op)")
        }
        return nil
    }

    /// Runs a file operation off the main thread.
    func onFileQueue<T: Sendable>(_ body: @escaping @Sendable (FileStore) throws -> T) async throws -> T {
        let files = files
        return try await withCheckedThrowingContinuation { continuation in
            fileQueue.async {
                continuation.resume(with: Swift.Result { try body(files) })
            }
        }
    }

    // MARK: lifecycle

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if case .editor = roles[ObjectIdentifier(webView)] { KeyboardAccessory.shared.install(on: webView) }
    }

    var onTerminate: (Role) -> Void = { _ in }
    /// The self-test ends the engine's process on purpose (`killWebContent`).
    private var expectedTermination: ObjectIdentifier?

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Usually memory pressure (D16, D50). Reload; files are on disk, and the
        // app model hands the console to the new page.
        guard let role = roles[ObjectIdentifier(webView)] else { return }
        Self.appendDocument(".probe-log.txt", "[host] web content process terminated (\(role))\n")
        if CommandLine.arguments.contains("--selftest"), expectedTermination != ObjectIdentifier(webView) {
            try? #"{"webContentTerminated": true}"#.write(to: Self.documentURL(".probe-result.json"), atomically: true, encoding: .utf8)
            return
        }
        expectedTermination = nil
        onTerminate(role)
        webView.reload()
    }

    /// Ends the page's web content process, as iOS does under memory pressure
    /// (self-test only; WKWebViewPrivate's `_killWebContentProcess`). Not in
    /// App Store builds, which don't set SELFTEST_SPI (D51).
    func killWebContent(_ webView: WKWebView) -> Bool {
        #if SELFTEST_SPI
        let selector = NSSelectorFromString("_killWebContentProcess")
        guard webView.responds(to: selector) else { return false }
        expectedTermination = ObjectIdentifier(webView)
        webView.perform(selector)
        return true
        #else
        return false
        #endif
    }

    // MARK: native dialogs for alert/confirm/prompt (turtle's textinput, ...)

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        Modal.present(alert, from: { [weak self] in self?.presenter() }, failed: { completionHandler() })
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        Modal.present(alert, from: { [weak self] in self?.presenter() }, failed: { completionHandler(false) })
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        let alert = UIAlertController(title: prompt, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = defaultText
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
        Modal.present(alert, from: { [weak self] in self?.presenter() }, failed: { completionHandler(nil) })
    }

    // MARK: helpers

    nonisolated static func documentURL(_ name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
    }

    nonisolated static func appendDocument(_ name: String, _ text: String) {
        let url = documentURL(name)
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// Calls into a page: `window.<object>.<function>(name, args)`, awaiting promises.
@MainActor
final class PageController {
    let webView: WKWebView
    private var ready = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let script: String

    init(webView: WKWebView, script: String) {
        self.webView = webView
        self.script = script
    }

    func markReady() {
        ready = true
        for c in waiting { c.resume() }
        waiting = []
    }

    func markNotReady() {
        ready = false
    }

    func whenReady() async {
        if ready { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Runs `script` with `name` and `args`; returns what the page's promise resolves to.
    func call(_ name: String, _ args: Any) async throws -> Any? {
        await whenReady()
        let box = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Unchecked, Error>) in
            webView.callAsyncJavaScript(script, arguments: ["name": name, "args": args], in: nil, in: .page) { result in
                switch result {
                case .success(let value): c.resume(returning: Unchecked(value: value))
                case .failure(let error): c.resume(throwing: error)
                }
            }
        }
        return box.value is NSNull ? nil : box.value
    }
}

/// A value from WebKit (property-list types) carried across a continuation.
struct Unchecked: @unchecked Sendable {
    let value: Any?
}
