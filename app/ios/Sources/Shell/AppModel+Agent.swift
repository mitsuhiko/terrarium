import Foundation
import SwiftUI

// The coding agent's actions (D34, D36). The agent runs in the engine page
// (agent/service.ts), which keeps the conversations and their index; the app
// picks the project, remembers the model picked last, and carries out the
// agent's IDE tools (agent/ide.ts) on the tabs and editors.

/// The project a path belongs to (D36): its top-level folder in Documents, a
/// linked folder's root, or Documents itself for loose files.
func projectRoot(_ path: String) -> String {
    path.split(separator: "/").first.map(String.init) ?? ""
}

struct IDEError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension AppModel {
    /// The project of the open file, else of the folder on screen.
    var agentProject: String {
        if let file, !isExternal(file) { return projectRoot(file.contains("/") ? file : "") }
        return projectRoot(currentDir)
    }

    func openAgent(project: String? = nil) {
        let project = project ?? agentProject
        agentDetent = .large
        agentListShown = false
        activeSheet = .agent
        Task { await agentOpen(project) }
    }

    @discardableResult
    func agentCall(_ method: String, _ args: [Any] = []) async -> Any? {
        await command("agent", ["method": method, "args": args])
    }

    private var agentPreferredModel: Any {
        guard let saved = UserDefaults.standard.dictionary(forKey: "agent.model") else { return NSNull() }
        return saved
    }

    func agentOpen(_ project: String) async {
        await agentImportConversations()
        await agentCall("open", [project, agentPreferredModel])
    }

    /// Before D36 the app kept one conversation per folder in the user defaults; they join the index once.
    private func agentImportConversations() async {
        let key = "agent.conversations"
        guard let old = UserDefaults.standard.dictionary(forKey: key) as? [String: Int], !old.isEmpty else { return }
        do {
            _ = try await engine.call("agent", ["method": "importConversations", "args": [old]])
            UserDefaults.standard.removeObject(forKey: key)
        } catch {
            WebHost.appendDocument(".probe-log.txt", "[agent] import failed: \(error)\n")
        }
    }

    func agentNewConversation() {
        let project = agent.state.root ?? agentProject
        Task { _ = await agentCall("newConversation", [project, agentPreferredModel]) }
    }

    func agentSwitch(_ id: Int) {
        Task { _ = await agentCall("switchTo", [id]) }
    }

    func agentRename(_ id: Int, _ title: String) {
        Task { _ = await agentCall("rename", [id, title]) }
    }

    func agentArchive(_ id: Int, _ archived: Bool) {
        Task { _ = await agentCall("archive", [id, archived]) }
    }

    func agentSetVisible(_ visible: Bool) {
        Task { _ = await agentCall("setVisible", [visible]) }
    }

    func agentSend(_ text: String) {
        Task {
            await saveAll()
            await agentCall("submit", [text, await ideState()])
        }
    }

    /// Whether the user allowed sending messages and project data to this model provider (D51).
    func agentSharingAllowed(_ provider: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: "agent.sharingAllowed") ?? []).contains(provider)
    }

    func agentAllowSharing(_ provider: String) {
        var allowed = UserDefaults.standard.stringArray(forKey: "agent.sharingAllowed") ?? []
        guard !allowed.contains(provider) else { return }
        allowed.append(provider)
        UserDefaults.standard.set(allowed, forKey: "agent.sharingAllowed")
    }

    /// The tabs or the active file changed: a working agent hears about it at its next step.
    func agentIDEChanged() {
        guard agent.state.busy else { return }
        Task { _ = await agentCall("ideChanged", [await ideState()]) }
    }

    func agentStop() {
        haptic()
        Task { _ = await agentCall("abort") }
    }

    func agentSetModel(_ option: AgentModelOption) {
        UserDefaults.standard.set(["provider": option.provider, "modelId": option.model], forKey: "agent.model")
        Task { _ = await agentCall("setModel", [option.provider, option.model]) }
    }

    func loadAgentAccounts() async {
        let raw = await agentCall("accounts") as? [[String: Any]] ?? []
        agentAccounts = raw.map { a in
            let oauth = a["oauth"] as? [String: Any]
            let apiKey = a["apiKey"] as? [String: Any]
            return AgentAccount(
                id: a["id"] as? String ?? "", name: a["name"] as? String ?? "", featured: a["featured"] as? Bool ?? false,
                oauthName: oauth?["name"] as? String, oauthLabel: oauth?["label"] as? String,
                subscription: oauth?["subscription"] as? Bool ?? false,
                apiKeyName: apiKey?["name"] as? String, signedIn: a["signedIn"] as? String)
        }
    }

    func loadAgentModels() async {
        let raw = await agentCall("availableModels") as? [[String: Any]] ?? []
        agentModels = raw.map {
            AgentModelOption(provider: $0["provider"] as? String ?? "", providerName: $0["providerName"] as? String ?? "",
                             model: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "")
        }
    }

    /// Sign in (type "oauth" or "api_key"); the flow's prompts show in LoginFlowView.
    func agentLogin(_ provider: String, _ type: String) async {
        agentLoginError = nil
        agentHost.beginLogin(provider)
        do {
            _ = try await engine.call("agent", ["method": "login", "args": [provider, type]])
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            if !message.contains("cancelled") { agentLoginError = message }
        }
        agentHost.endLogin()
        await loadAgentAccounts()
        await loadAgentModels()
        // A first sign-in gives the current conversation a model.
        if agent.state.model == nil, let project = agent.state.root { await agentOpen(project) }
    }

    func agentCancelLogin() {
        agentHost.answerPrompt(nil)
        Task { _ = await agentCall("cancelLogin") }
    }

    func agentLogout(_ provider: String) async {
        await agentCall("logout", [provider])
        await loadAgentAccounts()
        await loadAgentModels()
    }

    // MARK: the IDE as the agent sees it (agent/ide.ts)

    /// Tabs, the active file, cursor and selection, a running program, how the active file's last run failed.
    func ideState() async -> [String: Any] {
        let shownPanes = panes.prefix(wide ? 2 : 1)
        var state: [String: Any] = [
            "panes": shownPanes.map { ["tabs": $0.tabs, "active": $0.active ?? NSNull()] as [String: Any] },
            "focused": focused, "split": split,
            "file": file ?? NSNull(), "line": NSNull(), "column": NSNull(), "selection": NSNull(),
            "running": (session.running ? session.runningFile : nil) ?? NSNull(), "error": NSNull(),
        ]
        guard let file else { return state }
        if let c = await editorCall(focused, "cursor") as? [String: Any], c["path"] as? String == file {
            state["line"] = c["line"] ?? NSNull()
            state["column"] = c["column"] ?? NSNull()
            state["selection"] = c["selection"] ?? NSNull()
        }
        if let run = session.lastRun, run.file == file, run.status == "error" || run.status == "crashed" {
            let output = session.lines.filter { $0.runId == run.id && ($0.kind == "stderr" || $0.kind == "stdout") }.map(\.text).joined()
            state["error"] = String(output.suffix(2000))
        }
        return state
    }

    /// The user typed in the pane a moment ago: the agent must not switch its file away.
    private func typing(in pane: Int) -> Bool {
        editorFocused && pane == focused && Date().timeIntervalSince(lastTyped[pane] ?? .distantPast) < 3
    }

    /// An IDE tool's operation (agent/ide.ts). Messages go to the model as they are.
    func ideOperation(_ value: [String: Any]) async throws -> Any? {
        let path = value["path"] as? String ?? ""
        let name = value["shown"] as? String ?? basename(path)
        switch value["method"] as? String {
        case "state":
            return await ideState()
        case "open":
            return try await ideOpen(path, line: value["line"] as? Int, endLine: value["endLine"] as? Int, pane: value["pane"] as? Int)
        case "close":
            let holding = panes.indices.filter { panes[$0].tabs.contains(path) }
            guard !holding.isEmpty else { throw IDEError(message: "\(basename(path)) is not open in the editor.") }
            for i in holding.reversed() where panes.indices.contains(i) { await closeTab(path, pane: i) }
            return ["message": "Closed \(basename(path)).", "state": await ideState()]
        case "buffer":
            // What the editor has (typed but not saved included); a restored tab not shown yet has the file's text.
            guard let i = panes.indices.first(where: { panes[$0].tabs.contains(path) }) else { return NSNull() }
            if let text = await editorCall(i, "text", [path]) as? String { return ["text": text] }
            return ["text": try await readText(path)]
        case "relint":
            for i in panes.indices where panes[i].active == path { await editorCall(i, "relint") }
            return NSNull()
        case "format":
            return try await ideFormat(path, name)
        case "docs":
            let version = value["version"] as? String ?? defaultPython
            let ref = value["ref"] as? String ?? ""
            guard let page = await DocsIndex.shared.read(ref, version: version) else {
                throw IDEError(message: "No such docs section: \(ref) (Python \(version)). Use docs_search to find refs.")
            }
            showDocs(DocsTarget(version: version, ref: ref))
            return ["message": "Showing the Python \(version) docs: \(page.title)."]
        default:
            throw IDEError(message: "unknown IDE operation")
        }
    }

    private func ideOpen(_ path: String, line: Int?, endLine: Int?, pane: Int?) async throws -> [String: Any] {
        let name = basename(path)
        guard (try? await host.onFileQueue({ try $0.exists(path) })) == true else { throw IDEError(message: "No such file: \(name)") }
        var message: String
        let wanted = pane.flatMap { wide && (0...1).contains($0) ? $0 : nil }
        let target = wanted ?? panes.indices.first { panes[$0].active == path && (split || $0 == focused) } ?? focused
        if file != path && target == focused && typing(in: focused) {
            // Not away from what the user is typing in: the other pane, or a tab behind it.
            let current = file.map(basename) ?? "a file"
            if wide {
                await openLocation(path, line: endLine == nil ? line : nil, pane: focused == 0 ? 1 : 0, keepConsole: true)
                if let line, let endLine { await editorCall(focusedPane, "revealRange", [line, endLine, visibleFraction]) }
                message = "The user is typing in \(current), so \(name) opened in the other pane."
            } else {
                addBackgroundTab(path)
                message = "The user is typing in \(current), so \(name) opened as a tab behind it."
            }
        } else {
            await openLocation(path, line: endLine == nil ? line : nil, pane: wanted, keepConsole: true)
            if let line, let endLine { await editorCall(focusedPane, "revealRange", [line, endLine, visibleFraction]) }
            let at = line.map { l in endLine.map { $0 > l ? " at lines \(l)-\($0)" : " at line \(l)" } ?? " at line \(l)" } ?? ""
            message = "Opened \(name)\(at)\(split ? " in pane \(focusedPane + 1)" : "")."
        }
        // On iPhone the agent sheet makes room for the file.
        if !wide && activeSheet == .agent { agentDetent = .medium }
        return ["message": message, "state": await ideState()]
    }

    private func ideFormat(_ path: String, _ name: String) async throws -> [String: Any] {
        var pane = panes.indices.first { panes[$0].active == path && (split || $0 == focused) }
        if pane == nil, let i = panes.indices.first(where: { panes[$0].tabs.contains(path) && (split || $0 == focused) }) {
            if typing(in: i) { throw IDEError(message: "The user is typing in another file in that pane; ask before formatting \(name), or use format.") }
            await selectTab(path, pane: i)
            pane = i
        }
        guard let pane else { throw IDEError(message: "\(name) is not open in the editor. Use format for files on disk, or ide_open it first.") }
        let typed = lastTyped[pane]
        let changed: Bool
        do {
            changed = try await editors[pane].call("format", []) as? Bool == true
        } catch {
            let reason = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            throw IDEError(message: "Could not format \(name): \(reason)")
        }
        lastTyped[pane] = typed // the agent's change is not the user typing
        return ["message": changed ? "Formatted \(name) in the editor; the user can undo it there." : "\(name) is already formatted."]
    }

    /// A tab next to the active one that does not come to the front.
    private func addBackgroundTab(_ path: String) {
        guard panes.indices.contains(focused), !panes[focused].tabs.contains(path) else { return }
        var p = panes[focused]
        let at = p.active.flatMap { p.tabs.firstIndex(of: $0) }.map { $0 + 1 } ?? p.tabs.count
        p.tabs.insert(path, at: at)
        panes[focused] = p
        saveTabs()
    }
}
