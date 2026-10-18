import AuthenticationServices
import Observation
import UIKit
import WebKit

/// The native side of the coding agent (D32-D34), for the engine page only:
/// - `agent.sql`: SQLite for pi-durable's storage
/// - `agent.keychain.*`: credentials at rest
/// - `agent.loopback.*`: the localhost server OAuth redirects come back to
/// - `agent.auth.open/close`: the system sign-in browser
/// - `agent.login.*`: prompts and progress of a sign-in, shown natively
/// - `agent.clipboard`: device codes
@MainActor @Observable
final class AgentHost: NSObject, ASWebAuthenticationPresentationContextProviding {
    struct Option: Identifiable, Hashable {
        let id: String
        let label: String
        let detail: String?
    }

    /// What a sign-in flow asks for: a method (select), a key (secret), a pasted code (manual_code), text.
    struct Prompt: Identifiable, Equatable {
        let id: Int
        let type: String
        let message: String
        let placeholder: String?
        let options: [Option]
    }

    struct DeviceCode: Equatable {
        let code: String
        let uri: String
    }

    // The sign-in in progress (LoginFlowView draws it).
    var loginProvider: String?
    var prompt: Prompt?
    var deviceCode: DeviceCode?
    var progress: [String] = []

    @ObservationIgnored weak var engineView: WKWebView?
    @ObservationIgnored private var promptReply: WebHost.Reply?
    @ObservationIgnored private let database = AgentDatabase(directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("agent", isDirectory: true))
    @ObservationIgnored private let loopback = LoopbackServer()
    @ObservationIgnored private var authSession: ASWebAuthenticationSession?

    override init() {
        super.init()
        loopback.onRequest = { [weak self] server, connection, method, target in
            self?.engineView?.callAsyncJavaScript(
                "window.__loopback?.(server, connection, method, target)",
                arguments: ["server": server, "connection": connection, "method": method, "target": target],
                in: nil, in: .page, completionHandler: nil)
        }
    }

    /// Bridge ops from the engine page; false if `op` is not ours.
    func handle(_ op: String, _ value: [String: Any], _ reply: @escaping WebHost.Reply) -> Bool {
        switch op {
        case "agent.sql":
            let database = database
            let request = Unchecked(value: value)
            database.queue.async {
                let result: Unchecked
                let error: String?
                do {
                    result = Unchecked(value: try database.perform(request.value as? [String: Any] ?? [:]))
                    error = nil
                } catch let failure {
                    result = Unchecked(value: nil)
                    error = "\(failure)"
                }
                DispatchQueue.main.async { reply(result.value, error) }
            }
        case "agent.keychain.get", "agent.keychain.set", "agent.keychain.delete", "agent.keychain.list":
            let account = value["account"] as? String ?? ""
            do {
                switch op {
                case "agent.keychain.get": reply(try AgentKeychain.get(account) ?? NSNull(), nil)
                case "agent.keychain.set": try AgentKeychain.set(account, value["value"] as? String ?? ""); reply(NSNull(), nil)
                case "agent.keychain.delete": try AgentKeychain.delete(account); reply(NSNull(), nil)
                default: reply(try AgentKeychain.list(), nil)
                }
            } catch {
                reply(nil, "\(error)")
            }
        case "agent.loopback.listen":
            loopback.listen(port: UInt16(clamping: (value["port"] as? NSNumber)?.intValue ?? 0)) { result in
                switch result {
                case .success(let bound): reply(["id": bound.id, "port": Int(bound.port)], nil)
                case .failure(let error): reply(nil, "\(error)")
                }
            }
        case "agent.loopback.respond":
            loopback.respond((value["connection"] as? NSNumber)?.intValue ?? 0, status: (value["status"] as? NSNumber)?.intValue ?? 200,
                             headers: value["headers"] as? [String: String] ?? [:], body: value["body"] as? String ?? "")
            reply(NSNull(), nil)
        case "agent.loopback.close":
            loopback.close((value["id"] as? NSNumber)?.intValue ?? 0)
            reply(NSNull(), nil)
        case "agent.loopback.closeConnections":
            loopback.closeConnections((value["id"] as? NSNumber)?.intValue ?? 0)
            reply(NSNull(), nil)
        case "agent.auth.open":
            guard let url = (value["url"] as? String).flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                reply(nil, "bad url")
                return true
            }
            reply(openAuthSession(url), nil)
        case "agent.auth.close":
            closeAuthSession()
            reply(NSNull(), nil)
        case "agent.clipboard":
            UIPasteboard.general.string = value["value"] as? String ?? ""
            reply(NSNull(), nil)
        case "agent.login.prompt":
            answerPrompt(nil) // a newer prompt replaces an older one
            let options = (value["options"] as? [[String: Any]] ?? []).map {
                Option(id: $0["id"] as? String ?? "", label: $0["label"] as? String ?? "", detail: $0["description"] as? String)
            }
            prompt = Prompt(id: (value["id"] as? NSNumber)?.intValue ?? 0, type: value["type"] as? String ?? "text",
                            message: value["message"] as? String ?? "", placeholder: value["placeholder"] as? String, options: options)
            promptReply = reply
        case "agent.login.dismiss":
            if prompt?.id == (value["id"] as? NSNumber)?.intValue { answerPrompt(nil) }
            reply(NSNull(), nil)
        case "agent.login.event":
            let event = value["event"] as? [String: Any] ?? [:]
            switch event["type"] as? String {
            case "device_code":
                deviceCode = DeviceCode(code: event["userCode"] as? String ?? "", uri: event["verificationUri"] as? String ?? "")
            case "auth_url":
                progress.append(event["instructions"] as? String ?? "Sign in in the browser.")
            default:
                if let message = event["message"] as? String { progress.append(message) }
            }
            reply(NSNull(), nil)
        default:
            return false
        }
        return true
    }

    // MARK: sign-in UI

    func beginLogin(_ provider: String) {
        loginProvider = provider
        prompt = nil
        deviceCode = nil
        progress = []
    }

    func endLogin() {
        answerPrompt(nil)
        closeAuthSession()
        loginProvider = nil
        deviceCode = nil
    }

    /// The user answered the prompt (nil: cancelled).
    func answerPrompt(_ answer: String?) {
        guard let reply = promptReply else { return }
        promptReply = nil
        prompt = nil
        if let answer { reply(answer, nil) } else { reply(nil, "cancelled") }
    }

    /// The engine page went away (crash or reload): its servers and prompts are gone.
    func engineTerminated() {
        loopback.closeAll()
        answerPrompt(nil)
        closeAuthSession()
    }

    // MARK: the sign-in browser

    /// The system browser sheet. Its callback scheme never matches: pi-ai's
    /// flows redirect to http://localhost, which the loopback server answers,
    /// and the engine closes the sheet when the flow has what it needs.
    private func openAuthSession(_ url: URL) -> Bool {
        closeAuthSession()
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "terrarium-auth") { [weak self] _, _ in
            DispatchQueue.main.async { self?.authSession = nil }
        }
        session.presentationContextProvider = self
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
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.compactMap(\.keyWindow).first ?? engineView?.window ?? UIWindow(windowScene: scenes[0])
        }
    }
}
