import CryptoKit
import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the bundled web app under `app://app/` with cross-origin isolation
/// headers (D9) and acts as an offline-capable cache for package downloads:
///
/// - `/pkgs/<python>/<file>`: Pyodide's packages, cache-first from the jsDelivr
///   CDN (D12), per bundled Python (D37)
/// - `/pypi/simple/<name>/`: PyPI's Simple JSON API (PEP 691); cached for 10 min,
///   then network-first with the cache as offline fallback; file URLs are
///   rewritten to `/pypi-files/`
/// - `/pypi-files/<path>`: files.pythonhosted.org, cache-first (files are immutable)
/// - `/__http?url=<url>`: HTTP for Python programs (D25) and the agent's model
///   providers (D32). The request is made natively, so there is no CORS; the
///   worker routes cross-origin XHR and fetch here. Headers scripts may not
///   set travel in `X-Terrarium-Headers` (JSON); network failures answer 502 with
///   `X-Terrarium-Error`. The response streams: every chunk URLSession delivers
///   goes to the page right away (server-sent events need that).
/// - `POST /__fs`: one file operation of a Python program (HostFS, D35), by
///   synchronous XHR from its worker. The mount token is in `X-Fs-Mount`, the
///   call in `X-Fs` and its result in `X-Fs-Result` (JSON, percent-encoded);
///   file bytes are the bodies.
@MainActor
final class AppSchemeHandler: NSObject, WKURLSchemeHandler, URLSessionDataDelegate {
    static let scheme = "app"
    static let pypiSimple = URL(string: "https://pypi.org/simple/")!
    static let pypiFiles = URL(string: "https://files.pythonhosted.org/")!
    static let simpleJSON = "application/vnd.pypi.simple.v1+json"

    private let root: URL
    /// Downloaded Pyodide packages, one folder per Pyodide version.
    private let packageCaches: URL
    private let pypiCache: URL
    private var activeTasks = Set<ObjectIdentifier>()
    /// Python programs' file operations (`/__fs`).
    var hostFS: HostFS?
    /// Proxied requests: URLSession task ID -> the page's request.
    private var proxied: [Int: (task: any WKURLSchemeTask, target: URL, responded: Bool)] = [:]
    private var proxyTasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private lazy var proxySession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120 // between bytes: models can think for a while
        config.httpCookieStorage = .shared
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    init(root: URL) {
        self.root = root.standardizedFileURL
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let packageCaches = support.appendingPathComponent("pyodide-packages", isDirectory: true)
        self.packageCaches = packageCaches
        pypiCache = support.appendingPathComponent("pypi", isDirectory: true)
        let packageDirs = Runtimes.all.map { packageCaches.appendingPathComponent($0.pyodide, isDirectory: true) }
        for dir in packageDirs + [pypiCache.appendingPathComponent("simple"), pypiCache.appendingPathComponent("files")] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        activeTasks.insert(ObjectIdentifier(task))
        guard let url = task.request.url else {
            respond(task, status: 400, body: Data("bad request".utf8), mime: "text/plain")
            return
        }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }

        if path.hasPrefix("/pkgs/") {
            servePackage(task, name: String(path.dropFirst("/pkgs/".count)))
            return
        }
        if path.hasPrefix("/pypi/simple/") {
            serveSimpleIndex(task, project: String(path.dropFirst("/pypi/simple/".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            return
        }
        if path.hasPrefix("/pypi-files/") {
            servePypiFile(task, path: String(path.dropFirst("/pypi-files/".count)))
            return
        }
        if path == "/__http" {
            proxy(task)
            return
        }
        if path == "/__fs" {
            serveFS(task)
            return
        }

        let fileURL = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        guard fileURL.path.hasPrefix(root.path + "/"),
              let data = try? Data(contentsOf: fileURL)
        else {
            respond(task, status: 404, body: Data("not found: \(path)".utf8), mime: "text/plain")
            return
        }
        respond(task, status: 200, body: data, mime: Self.mimeType(for: fileURL))
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        activeTasks.remove(ObjectIdentifier(task))
        if let dataTask = proxyTasks.removeValue(forKey: ObjectIdentifier(task)) {
            proxied.removeValue(forKey: dataTask.taskIdentifier)
            dataTask.cancel()
        }
    }

    // MARK: files for Python programs

    private func serveFS(_ task: any WKURLSchemeTask) {
        let request = task.request
        let decode = { (name: String) in request.value(forHTTPHeaderField: name)?.removingPercentEncoding ?? "" }
        let meta = (try? JSONSerialization.jsonObject(with: Data(decode("X-Fs").utf8))) as? [String: Any] ?? [:]
        let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        let (result, data) = hostFS?.perform(token: decode("X-Fs-Mount"), meta, data: body) ?? (["error": "ENOSYS"], nil)
        let json = (try? JSONSerialization.data(withJSONObject: result)).flatMap { String(data: $0, encoding: .utf8) } ?? #"{"error":"EIO"}"#
        let encoded = json.addingPercentEncoding(withAllowedCharacters: Self.headerSafe) ?? json
        respond(task, status: 200, body: data ?? Data(), mime: "application/octet-stream", extra: ["X-Fs-Result": encoded])
    }

    /// What may stay unescaped in a header value we decode with decodeURIComponent.
    private static let headerSafe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789{}[]:,\"-_.")

    // MARK: HTTP for Python programs

    /// Headers that describe our hop, not the program's request. `user-agent`
    /// is WebKit's own: servers treat it as a browser (Anthropic's token
    /// endpoint answers it with a fake 429). A User-Agent the code set itself
    /// arrives in X-Terrarium-Headers; otherwise URLSession's applies.
    private static let hopHeaders: Set<String> = [
        "host", "origin", "referer", "connection", "content-length", "accept-encoding", "user-agent",
        "sec-fetch-site", "sec-fetch-mode", "sec-fetch-dest", "x-terrarium-headers",
    ]
    /// Response headers that no longer apply (URLSession already decoded the
    /// body) or would override our cross-origin isolation headers (D9).
    private static let droppedResponseHeaders: Set<String> = [
        "content-encoding", "content-length", "transfer-encoding", "connection", "keep-alive",
        "cross-origin-opener-policy", "cross-origin-embedder-policy", "cross-origin-resource-policy",
    ]

    private func proxy(_ task: any WKURLSchemeTask) {
        let incoming = task.request
        guard let query = incoming.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })?.queryItems,
              let target = query.first(where: { $0.name == "url" })?.value.flatMap(URL.init(string:)),
              let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else {
            respond(task, status: 400, body: Data("bad proxy request".utf8), mime: "text/plain")
            return
        }
        var request = URLRequest(url: target)
        request.httpMethod = incoming.httpMethod ?? "GET"
        for (name, value) in incoming.allHTTPHeaderFields ?? [:] where !Self.hopHeaders.contains(name.lowercased()) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let hidden = incoming.value(forHTTPHeaderField: "X-Terrarium-Headers"),
           let extra = try? JSONSerialization.jsonObject(with: Data(hidden.utf8)) as? [String: String] {
            for (name, value) in extra { request.setValue(value, forHTTPHeaderField: name) }
        }
        request.httpBody = incoming.httpBody ?? incoming.httpBodyStream.map(Self.readAll)
        // Stopping the page's request (webView(_:stop:)) cancels the download.
        let dataTask = proxySession.dataTask(with: request)
        proxied[dataTask.taskIdentifier] = (task, target, false)
        proxyTasks[ObjectIdentifier(task)] = dataTask
        dataTask.resume()
    }

    nonisolated func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        MainActor.assumeIsolated {
            guard var entry = proxied[dataTask.taskIdentifier], activeTasks.contains(ObjectIdentifier(entry.task)) else {
                return completionHandler(.cancel)
            }
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] {
                guard let name = key as? String, !Self.droppedResponseHeaders.contains(name.lowercased()) else { continue }
                headers[name] = "\(value)"
            }
            headers["X-Terrarium-Final-Url"] = response.url?.absoluteString ?? entry.target.absoluteString
            headers["Content-Type"] = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            headers.merge(Self.isolationHeaders) { _, new in new }
            headers["Cache-Control"] = "no-store"
            entry.task.didReceive(HTTPURLResponse(url: entry.task.request.url!, statusCode: http?.statusCode ?? 200,
                                                  httpVersion: "HTTP/1.1", headerFields: headers)!)
            entry.responded = true
            proxied[dataTask.taskIdentifier] = entry
            completionHandler(.allow)
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            guard let entry = proxied[dataTask.taskIdentifier], activeTasks.contains(ObjectIdentifier(entry.task)) else { return }
            entry.task.didReceive(data)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        MainActor.assumeIsolated {
            guard let entry = proxied.removeValue(forKey: task.taskIdentifier) else { return }
            proxyTasks.removeValue(forKey: ObjectIdentifier(entry.task))
            if let error, !entry.responded {
                let message = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
                respond(entry.task, status: 502, body: Data(message.utf8), mime: "text/plain", extra: ["X-Terrarium-Error": message])
                return
            }
            guard activeTasks.remove(ObjectIdentifier(entry.task)) != nil else { return }
            if let error { entry.task.didFailWithError(error) } else { entry.task.didFinish() }
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

    // MARK: Pyodide packages (cache-first)

    private func servePackage(_ task: any WKURLSchemeTask, name path: String) {
        let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let runtime = Runtimes.runtime(parts[0]), Self.isSafeComponent(parts[1]) else {
            respond(task, status: 400, body: Data("bad package path".utf8), mime: "text/plain")
            return
        }
        let cached = packageCaches.appendingPathComponent(runtime.pyodide, isDirectory: true).appendingPathComponent(parts[1])
        cacheFirst(task, cached: cached, remote: runtime.cdn.appendingPathComponent(parts[1]))
    }

    // MARK: PyPI

    private func serveSimpleIndex(_ task: any WKURLSchemeTask, project: String) {
        guard Self.isSafeComponent(project) else {
            respond(task, status: 400, body: Data("bad project name".utf8), mime: "text/plain")
            return
        }
        let normalized = project.lowercased().replacingOccurrences(of: "[-_.]+", with: "-", options: .regularExpression)
        let cached = pypiCache.appendingPathComponent("simple/\(normalized).json")
        var request = URLRequest(url: Self.pypiSimple.appendingPathComponent("\(normalized)/"))
        request.setValue(Self.simpleJSON, forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        // Fresh enough: avoid a network round trip on every run.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cached.path),
           let modified = attrs[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 600,
           let data = try? Data(contentsOf: cached) {
            respond(task, status: 200, body: data, mime: Self.simpleJSON, extra: ["X-Cache": "fresh"])
            return
        }
        Task { @MainActor in
            // Network-first so new releases show up; fall back to the cache offline.
            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                let rewritten = Self.rewriteFileURLs(data)
                try? rewritten.write(to: cached, options: .atomic)
                self.respond(task, status: 200, body: rewritten, mime: Self.simpleJSON, extra: ["X-Cache": "miss"])
            } else if let data = try? Data(contentsOf: cached) {
                self.respond(task, status: 200, body: data, mime: Self.simpleJSON, extra: ["X-Cache": "stale"])
            } else {
                self.respond(task, status: 404, body: Data("not found: \(normalized) (offline?)".utf8), mime: "text/plain")
            }
        }
    }

    private func servePypiFile(_ task: any WKURLSchemeTask, path: String) {
        let parts = path.split(separator: "/")
        guard !parts.isEmpty, parts.allSatisfy({ Self.isSafeComponent(String($0)) }) else {
            respond(task, status: 400, body: Data("bad file path".utf8), mime: "text/plain")
            return
        }
        // Store under a hash of the path: the hashed directory layout is deep.
        let key = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        let cached = pypiCache.appendingPathComponent("files/\(key)-\(parts.last!)")
        cacheFirst(task, cached: cached, remote: Self.pypiFiles.appendingPathComponent(path))
    }

    /// Point file URLs in a Simple JSON response at our cache.
    private static func rewriteFileURLs(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        return Data(text.replacingOccurrences(of: "https://files.pythonhosted.org/", with: "\(scheme)://app/pypi-files/").utf8)
    }

    // MARK: helpers

    private func cacheFirst(_ task: any WKURLSchemeTask, cached: URL, remote: URL) {
        if let data = try? Data(contentsOf: cached) {
            respond(task, status: 200, body: data, mime: "application/octet-stream", extra: ["X-Cache": "hit"])
            return
        }
        Task { @MainActor in
            // CDNs answer 5xx now and then while they fetch a file the first time: try again.
            for attempt in 0..<3 {
                do {
                    let (data, response) = try await URLSession.shared.data(from: remote)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 500
                    if status >= 500 && attempt < 2 {
                        try? await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
                        continue
                    }
                    if status == 200 { try? data.write(to: cached, options: .atomic) }
                    self.respond(task, status: status, body: data, mime: "application/octet-stream", extra: ["X-Cache": "miss"])
                } catch {
                    if attempt < 2, (error as? URLError)?.code != .notConnectedToInternet {
                        try? await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
                        continue
                    }
                    self.respond(task, status: 502, body: Data("download failed (offline?): \(error.localizedDescription)".utf8), mime: "text/plain")
                }
                return
            }
        }
    }

    private static func isSafeComponent(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix(".") && !s.contains("/") && !s.contains("\\")
    }

    private func respond(
        _ task: any WKURLSchemeTask, status: Int, body: Data, mime: String, extra: [String: String] = [:]
    ) {
        guard activeTasks.remove(ObjectIdentifier(task)) != nil else { return }
        var headers = ["Content-Type": mime, "Content-Length": String(body.count), "Cache-Control": "no-store"]
        headers.merge(Self.isolationHeaders) { _, new in new }
        headers.merge(extra) { _, new in new }
        let response = HTTPURLResponse(
            url: task.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    private static let isolationHeaders = [
        "Cross-Origin-Opener-Policy": "same-origin",
        "Cross-Origin-Embedder-Policy": "require-corp",
        "Cross-Origin-Resource-Policy": "same-origin",
    ]

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json": return "application/json"
        case "wasm": return "application/wasm"
        case "css": return "text/css; charset=utf-8"
        case "py": return "text/x-python; charset=utf-8"
        case "zip", "whl": return "application/zip"
        default:
            return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
