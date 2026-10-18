import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves `web/dist` under `app://app/` with the isolation headers (D9) and
/// proxies `/__http?url=…` like the app (D25), with two differences:
///
/// - The response streams: every chunk URLSession delivers goes to the page
///   right away (`didReceive` more than once), which server-sent events need.
/// - Credentials are added here. A request carrying the launch token
///   (`X-Terrarium-Token`, which only the page's main thread knows) to a host we
///   hold a credential for gets that header set natively. The key never
///   enters the web view.
@MainActor
final class SchemeHandler: NSObject, WKURLSchemeHandler, URLSessionDataDelegate {
    struct Credential {
        let header: String
        let value: String
    }

    static let scheme = "app"
    let token = UUID().uuidString
    /// "host" or "host:port" → the header to set.
    var credentials: [String: Credential] = [:]

    private let root: URL
    private var active = Set<ObjectIdentifier>()
    private var proxied: [Int: (task: any WKURLSchemeTask, injected: Bool, responded: Bool)] = [:]
    private var sessionTasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        active.insert(ObjectIdentifier(task))
        guard let url = task.request.url else { return respond(task, 400, Data("bad request".utf8), "text/plain") }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        if path == "/__http" { return proxy(task) }
        let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            return respond(task, 404, Data("not found: \(path)".utf8), "text/plain")
        }
        respond(task, 200, data, Self.mimeType(file))
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
        if let dataTask = sessionTasks.removeValue(forKey: ObjectIdentifier(task)) {
            proxied.removeValue(forKey: dataTask.taskIdentifier)
            dataTask.cancel()
        }
    }

    // MARK: proxy

    /// Headers of our hop, not the caller's request. `user-agent` is WebKit's
    /// own: forwarding it makes servers treat us as a browser (Anthropic's
    /// token endpoint answers a browser or curl User-Agent with a fake 429).
    /// A User-Agent the code set itself arrives in X-Terrarium-Headers.
    private static let hopHeaders: Set<String> = [
        "host", "origin", "referer", "connection", "content-length", "accept-encoding", "user-agent",
        "sec-fetch-site", "sec-fetch-mode", "sec-fetch-dest", "x-terrarium-headers", "x-terrarium-token",
    ]
    private static let droppedResponseHeaders: Set<String> = [
        "content-encoding", "content-length", "transfer-encoding", "connection", "keep-alive",
        "cross-origin-opener-policy", "cross-origin-embedder-policy", "cross-origin-resource-policy",
    ]

    private func proxy(_ task: any WKURLSchemeTask) {
        let incoming = task.request
        guard let query = incoming.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })?.queryItems,
              let target = query.first(where: { $0.name == "url" })?.value.flatMap(URL.init(string:)),
              let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = target.host
        else { return respond(task, 400, Data("bad proxy request".utf8), "text/plain") }
        var request = URLRequest(url: target)
        request.httpMethod = incoming.httpMethod ?? "GET"
        for (name, value) in incoming.allHTTPHeaderFields ?? [:] where !Self.hopHeaders.contains(name.lowercased()) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // Headers fetch may not set (User-Agent, …) travel as JSON, as in the app (D25).
        if let hidden = incoming.value(forHTTPHeaderField: "X-Terrarium-Headers"),
           let extra = try? JSONSerialization.jsonObject(with: Data(hidden.utf8)) as? [String: String] {
            for (name, value) in extra { request.setValue(value, forHTTPHeaderField: name) }
        }
        var injected = false
        let key = target.port.map { "\(host):\($0)" } ?? host
        if incoming.value(forHTTPHeaderField: "X-Terrarium-Token") == token, let credential = credentials[key] ?? credentials[host] {
            request.setValue(credential.value, forHTTPHeaderField: credential.header)
            injected = true
        }
        request.httpBody = incoming.httpBody ?? incoming.httpBodyStream.map(Self.readAll)
        let dataTask = session.dataTask(with: request)
        proxied[dataTask.taskIdentifier] = (task, injected, false)
        sessionTasks[ObjectIdentifier(task)] = dataTask
        dataTask.resume()
    }

    nonisolated func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        MainActor.assumeIsolated {
            guard var entry = proxied[dataTask.taskIdentifier] else { return completionHandler(.cancel) }
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] {
                guard let name = key as? String, !Self.droppedResponseHeaders.contains(name.lowercased()) else { continue }
                headers[name] = "\(value)"
            }
            headers.merge(Self.isolation) { _, new in new }
            headers["Cache-Control"] = "no-store"
            if entry.injected { headers["X-Terrarium-Credential"] = "injected" }
            let reply = HTTPURLResponse(url: entry.task.request.url!, statusCode: http?.statusCode ?? 200,
                                        httpVersion: "HTTP/1.1", headerFields: headers)!
            entry.task.didReceive(reply)
            entry.responded = true
            proxied[dataTask.taskIdentifier] = entry
            completionHandler(.allow)
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            proxied[dataTask.taskIdentifier]?.task.didReceive(data)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        MainActor.assumeIsolated {
            guard let entry = proxied.removeValue(forKey: task.taskIdentifier) else { return }
            sessionTasks.removeValue(forKey: ObjectIdentifier(entry.task))
            guard active.remove(ObjectIdentifier(entry.task)) != nil else { return }
            if let error {
                if entry.responded {
                    entry.task.didFailWithError(error)
                } else {
                    active.insert(ObjectIdentifier(entry.task))
                    let message = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
                    respond(entry.task, 502, Data(message.utf8), "text/plain", ["X-Terrarium-Error": message])
                }
            } else {
                entry.task.didFinish()
            }
        }
    }

    private nonisolated static func readAll(_ stream: InputStream) -> Data {
        var data = Data()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    // MARK: helpers

    private static let isolation = [
        "Cross-Origin-Opener-Policy": "same-origin",
        "Cross-Origin-Embedder-Policy": "require-corp",
        "Cross-Origin-Resource-Policy": "same-origin",
    ]

    private func respond(_ task: any WKURLSchemeTask, _ status: Int, _ body: Data, _ mime: String, _ extra: [String: String] = [:]) {
        guard active.remove(ObjectIdentifier(task)) != nil else { return }
        var headers = ["Content-Type": mime, "Content-Length": String(body.count), "Cache-Control": "no-store"]
        headers.merge(Self.isolation) { _, new in new }
        headers.merge(extra) { _, new in new }
        task.didReceive(HTTPURLResponse(url: task.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(body)
        task.didFinish()
    }

    private static func mimeType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json": return "application/json"
        case "wasm": return "application/wasm"
        default: return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
