import AuthenticationServices
import SwiftUI
import WebKit

@main
struct AgentSpikeApp: App {
    var body: some Scene {
        WindowGroup {
            WebView().ignoresSafeArea()
        }
    }
}

struct WebView: UIViewRepresentable {
    func makeCoordinator() -> Host { Host() }
    func makeUIView(context: Context) -> WKWebView { context.coordinator.makeWebView() }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

/// The host: bridge ops for SQLite (`sql`), the project folder (`fs.*`), a
/// key-value store that outlives page reloads (`kv.*`, for the step runner),
/// `reload` to simulate the engine page going away mid-turn, and for logins:
/// `keychain.*`, a loopback HTTP server (`loopback.*`), the system sign-in
/// browser (`auth.open` / `auth.close`) and `clipboard.set`.
@MainActor
final class Host: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate,
    ASWebAuthenticationPresentationContextProviding {
    typealias Reply = @MainActor @Sendable (Any?, String?) -> Void

    private let env = ProcessInfo.processInfo.environment
    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private lazy var scheme = SchemeHandler(root: Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true))
    private lazy var sql = SqlStore(directory: docs.appendingPathComponent("db", isDirectory: true))
    private lazy var files = ProjectFiles(root: docs.appendingPathComponent("project", isDirectory: true))
    private var kv: [String: String] = [:]
    private var loads = 0
    private var rolledBackOnNavigation: [String] = []
    private weak var webView: WKWebView?
    private let loopback = Loopback()
    private var authSession: ASWebAuthenticationSession?
    private var authSerial = 0

    func makeWebView() -> WKWebView {
        // Stand-ins for the Keychain: the mock server's key, and a real key only
        // when run.sh passes one (--real).
        if let mock = env["TERRARIUM_MOCK_URL"].flatMap(URL.init(string:)), let host = mock.host {
            let key = mock.port.map { "\(host):\($0)" } ?? host
            scheme.credentials[key] = .init(header: "x-api-key", value: env["TERRARIUM_MOCK_KEY"] ?? "mock-key")
        }
        if let real = env["ANTHROPIC_API_KEY"], !real.isEmpty {
            scheme.credentials["api.anthropic.com"] = .init(header: "x-api-key", value: real)
        }

        let config = WKWebViewConfiguration()
        config.preferences.inactiveSchedulingPolicy = .none // keep polling while the sign-in sheet covers us
        config.setURLSchemeHandler(scheme, forURLScheme: SchemeHandler.scheme)
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "bridge")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        webView.navigationDelegate = self
        self.webView = webView
        loopback.onRequest = { [weak self] server, connection, method, target in
            self?.webView?.callAsyncJavaScript(
                "window.__loopback?.(server, connection, method, target)",
                arguments: ["server": server, "connection": connection, "method": method, "target": target],
                in: nil, in: .page, completionHandler: nil)
        }
        let steps = env["TERRARIUM_STEPS"] ?? "all"
        webView.load(URLRequest(url: URL(string: "\(SchemeHandler.scheme)://app/index.html#\(steps)")!))
        return webView
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping Reply) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            return replyHandler(nil, "malformed bridge message")
        }
        switch op {
        case "sql":
            let store = sql
            Self.offMain(store.queue, body, replyHandler) { try store.perform($0) }
        case _ where op.hasPrefix("fs."):
            let store = files
            Self.offMain(store.queue, body, replyHandler) { try store.perform(op, $0) }
        case "keychain.get", "keychain.set", "keychain.delete", "keychain.list":
            let account = body["account"] as? String ?? ""
            do {
                switch op {
                case "keychain.get": replyHandler(try Keychain.get(account) ?? NSNull(), nil)
                case "keychain.set": try Keychain.set(account, body["value"] as? String ?? ""); replyHandler(NSNull(), nil)
                case "keychain.delete": try Keychain.delete(account); replyHandler(NSNull(), nil)
                default: replyHandler(try Keychain.list(), nil)
                }
            } catch {
                replyHandler(nil, "\(error)")
            }
        case "loopback.listen":
            let port = UInt16(clamping: (body["port"] as? NSNumber)?.intValue ?? 0)
            loopback.listen(port: port) { result in
                switch result {
                case .success(let bound): replyHandler(["id": bound.id, "port": Int(bound.port)], nil)
                case .failure(let error): replyHandler(nil, "\(error)")
                }
            }
        case "loopback.respond":
            loopback.respond((body["connection"] as? NSNumber)?.intValue ?? 0,
                             status: (body["status"] as? NSNumber)?.intValue ?? 200,
                             headers: body["headers"] as? [String: String] ?? [:],
                             body: body["body"] as? String ?? "")
            replyHandler(NSNull(), nil)
        case "loopback.close":
            loopback.close((body["id"] as? NSNumber)?.intValue ?? 0)
            replyHandler(NSNull(), nil)
        case "loopback.closeConnections":
            loopback.closeConnections((body["id"] as? NSNumber)?.intValue ?? 0)
            replyHandler(NSNull(), nil)
        case "auth.open":
            guard let url = (body["url"] as? String).flatMap(URL.init(string:)) else { return replyHandler(nil, "bad url") }
            replyHandler(openAuthSession(url, ephemeral: body["ephemeral"] as? Bool ?? false), nil)
        case "auth.close":
            closeAuthSession()
            replyHandler(NSNull(), nil)
        case "clipboard.set":
            UIPasteboard.general.string = body["value"] as? String ?? ""
            replyHandler(NSNull(), nil)
        case "config":
            replyHandler([
                "token": scheme.token,
                "mockUrl": env["TERRARIUM_MOCK_URL"] ?? "",
                "realKey": !(env["ANTHROPIC_API_KEY"] ?? "").isEmpty,
                "loads": loads,
                "rolledBackOnNavigation": rolledBackOnNavigation,
            ], nil)
        case "kv.get":
            replyHandler(kv[body["key"] as? String ?? ""] ?? NSNull(), nil)
        case "kv.set":
            kv[body["key"] as? String ?? ""] = body["value"] as? String
            replyHandler(NSNull(), nil)
        case "reload":
            replyHandler(NSNull(), nil)
            webView?.reload()
        case "log":
            let line = body["value"] as? String ?? ""
            print("[page] \(line)")
            Self.append("agent-log.txt", line + "\n")
            replyHandler(NSNull(), nil)
        case "result":
            Self.write("agent-result.json", body["value"] as? String ?? "null")
            replyHandler(NSNull(), nil)
        default:
            replyHandler(nil, "unknown op \(op)")
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loads += 1
        // A reload while a transaction is open: roll it back before the new page opens the database.
        let store = sql
        store.queue.async {
            let names = store.rollbackAll()
            DispatchQueue.main.async { self.rolledBackOnNavigation += names }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        print("[host] web content process terminated; reloading")
        webView.reload()
    }

    // MARK: sign-in browser

    /// The system browser sheet. Its callback scheme never matches: pi-ai's
    /// flows redirect to http://localhost, which the loopback server answers,
    /// and the page closes the sheet when its login has what it needs.
    private func openAuthSession(_ url: URL, ephemeral: Bool) -> Bool {
        closeAuthSession()
        authSerial += 1
        let serial = authSerial
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "terrarium-auth") { [weak self] _, error in
            let reason = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin ? "cancelled" : "\(error.map { "\($0)" } ?? "done")"
            DispatchQueue.main.async {
                guard let self, self.authSerial == serial, self.authSession != nil else { return }
                self.authSession = nil
                // The user closed the sheet; tell the page so a login does not wait forever.
                self.webView?.callAsyncJavaScript("window.__authClosed?.(reason)", arguments: ["reason": reason],
                                                  in: nil, in: .page, completionHandler: nil)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = ephemeral
        authSession = session
        return session.start()
    }

    private func closeAuthSession() {
        guard let session = authSession else { return }
        authSession = nil
        session.cancel()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            webView?.window ?? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first!
        }
    }

    /// Run a bridge op on a serial queue and reply on the main thread.
    private static func offMain(_ queue: DispatchQueue, _ body: [String: Any], _ reply: @escaping Reply,
                                _ work: @escaping @Sendable ([String: Any]) throws -> Any) {
        let request = UncheckedSendable(body)
        queue.async {
            let outcome: UncheckedSendable<(Any?, String?)>
            do {
                outcome = UncheckedSendable((try work(request.value), nil))
            } catch let failure {
                outcome = UncheckedSendable((nil, "\(failure)"))
            }
            DispatchQueue.main.async { reply(outcome.value.0, outcome.value.1) }
        }
    }

    private static func url(_ name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
    }

    private static func write(_ name: String, _ text: String) {
        try? text.write(to: url(name), atomically: true, encoding: .utf8)
    }

    private static func append(_ name: String, _ text: String) {
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: url(name)) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url(name))
        }
    }
}

struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
