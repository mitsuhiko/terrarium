import SwiftUI

// The Python documentation (D37) and the Python versions (D37): the viewer,
// the docs index for the engine (agent tools, help()), Show Info's link into
// the docs, the default version and a folder's `.python-version`.

/// Which Python a file runs on, as the engine decides it (web/src/runtimes.ts).
struct PythonChoice: Equatable {
    let python: String // "3.14"
    let version: String // "3.14.2"
    let reason: String // "default", ".python-version"'s path, "script metadata", ...
}

extension AppModel {
    // MARK: the viewer

    func showDocs(_ target: DocsTarget) {
        // In the other half when it shows the docs (D59), else a sheet.
        if docsInPanel, let panelDocs { return panelDocs.open(target) }
        docs.show(target, schemeHandler: host.schemeHandler, from: host.presenter)
    }

    /// The docs of the Python the current file runs on.
    func showDocs() {
        Task {
            var version = defaultPython
            if let file, !isExternal(file), let choice = await pythonFor(file) { version = choice.python }
            showDocs(DocsTarget(version: version, ref: nil))
        }
    }

    /// help(x) and the agent: the docs of a symbol ("json.loads"); its title, or nil when the docs don't have it.
    func showDocs(symbol: String, version: String) async -> String? {
        guard let found = await DocsIndex.shared.lookup(symbol, version: version) else { return nil }
        showDocs(DocsTarget(version: version, ref: found.ref))
        return found.title
    }

    var docsState: [String: Any] {
        let browser = docsInPanel ? panelDocs : docs.browser
        return ["shown": docs.isShown || docsInPanel, "inPanel": docsInPanel, "version": browser?.version ?? NSNull(), "ref": browser?.ref ?? NSNull(), "title": browser?.title ?? NSNull()]
    }

    func closeDocs() {
        docs.close()
    }

    /// `docs.*` bridge ops from the engine.
    func handleDocs(_ op: String, _ value: [String: Any], _ reply: @escaping WebHost.Reply) {
        let version = value["version"] as? String ?? defaultPython
        Task {
            switch op {
            case "docs.search":
                let hits = await DocsIndex.shared.search(value["query"] as? String ?? "", version: version, limit: value["limit"] as? Int ?? 10)
                reply(hits.map { $0.json(version) }, nil)
            case "docs.read":
                guard let page = await DocsIndex.shared.read(value["ref"] as? String ?? "", version: version) else { return reply(NSNull(), nil) }
                reply(["ref": page.ref, "title": page.title, "markdown": page.markdown], nil)
            case "docs.show":
                if let symbol = value["symbol"] as? String {
                    reply(await showDocs(symbol: symbol, version: version) ?? NSNull(), nil)
                } else {
                    showDocs(DocsTarget(version: version, ref: value["ref"] as? String))
                    reply(true, nil)
                }
            default:
                reply(nil, "unknown op \(op)")
            }
        }
    }

    /// A `docs:3.14/library/json.html#json.loads` link (the agent's answers).
    func openDocsLink(_ url: URL) -> Bool {
        guard url.scheme == "docs" else { return false }
        let rest = url.absoluteString.dropFirst("docs:".count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
        guard let version = parts.first, Runtimes.runtime(version) != nil else { return false }
        showDocs(DocsTarget(version: version, ref: parts.count > 1 ? parts[1].removingPercentEncoding ?? parts[1] : nil))
        return true
    }

    // MARK: Show Info -> docs

    /// The standard library module of a ty definition target ("ext:vendored://stdlib/json/__init__.pyi" -> "json").
    static func stdlibModule(_ target: String) -> String? {
        // The app's own modules (ui, clipboard, ...) are documented too (D42).
        if let range = target.range(of: "/terrarium-stubs/") {
            let file = String(target[range.upperBound...])
            return file.hasPrefix("_") ? nil : (file as NSString).deletingPathExtension
        }
        guard let range = target.range(of: "stdlib/") else { return nil }
        var module = String(target[range.upperBound...])
        for suffix in [".pyi", ".py"] where module.hasSuffix(suffix) { module.removeLast(suffix.count) }
        if module.hasSuffix("/__init__") { module.removeLast("/__init__".count) }
        return module.replacingOccurrences(of: "/", with: ".")
    }

    /// The identifier at a 1-based line/column.
    static func identifier(in text: String, line: Int, column: Int) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line - 1) else { return nil }
        let chars = Array(lines[line - 1].utf16)
        let isWord = { (c: UInt16) in (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127 }
        var start = min(max(column - 1, 0), chars.count)
        var end = start
        while start > 0 && isWord(chars[start - 1]) { start -= 1 }
        while end < chars.count && isWord(chars[end]) { end += 1 }
        guard end > start else { return nil }
        return String(utf16CodeUnits: Array(chars[start..<end]), count: end - start)
    }

    /// The docs for what ty resolved at the cursor, if it is in the standard library.
    func docsTarget(path: String, text: String, line: Int, column: Int) async -> DocsTarget? {
        guard let targets = try? await analysis("definition", [path, text, line, column]) as? [[String: Any]],
              let target = targets.first?["path"] as? String, isExternal(target),
              let module = Self.stdlibModule(target),
              let word = Self.identifier(in: text, line: line, column: column) else { return nil }
        let version = await pythonFor(path)?.python ?? defaultPython
        var candidates = ["\(module).\(word)"]
        if module.split(separator: ".").last.map(String.init) == word { candidates.insert(module, at: 0) }
        for symbol in candidates {
            if let found = await DocsIndex.shared.lookup(symbol, version: version) { return DocsTarget(version: version, ref: found.ref) }
        }
        return nil
    }

    // MARK: Python versions

    func setDefaultPython(_ python: String) {
        guard Runtimes.runtime(python) != nil else { return }
        defaultPython = python
        UserDefaults.standard.set(python, forKey: "python.default")
        Task {
            await command("setDefaultPython", ["python": python])
            await refreshFilePython()
            await syncAnalysisRoot(force: true)
        }
    }

    func pythonFor(_ path: String) async -> PythonChoice? {
        guard let r = await command("pythonFor", ["path": path]) as? [String: Any], let python = r["python"] as? String else { return nil }
        return PythonChoice(python: python, version: r["version"] as? String ?? python, reason: r["reason"] as? String ?? "")
    }

    /// What the ⋯ menu shows for the current file.
    func refreshFilePython() async {
        guard let file, !isExternal(file) else {
            filePython = nil
            folderPin = nil
            return
        }
        let dir = dirname(file)
        let pinPath = joinPath(dir, ".python-version")
        let pin = (try? await host.onFileQueue { try $0.exists(pinPath) ? try $0.read(pinPath, encoding: "utf8") : "" }) ?? ""
        let pinned = pin.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && !$0.hasPrefix("#") }
        folderPin = pinned.flatMap { p in Runtimes.all.first { p == $0.python || p.hasPrefix("\($0.python).") }?.python }
        filePython = await pythonFor(file)
    }

    /// Pin the current file's folder to a Python (a `.python-version`, as uv writes it), or unpin it.
    func setFolderPython(_ python: String?) async {
        guard let file, !isExternal(file) else { return }
        let path = joinPath(dirname(file), ".python-version")
        do {
            if let python {
                try await host.onFileQueue { try $0.write(path, data: "\(python)\n", encoding: "utf8") }
            } else if (try? await host.onFileQueue({ try $0.exists(path) })) == true {
                try await host.onFileQueue { try $0.delete(path) }
            }
        } catch {
            showToast("Could not change the Python version: \(error)")
            return
        }
        fileListVersion += 1
        await refreshFilePython()
        showToast(filePython.map { "Runs on Python \($0.version)" } ?? "Python version changed")
        await syncAnalysisRoot(force: true)
    }
}
