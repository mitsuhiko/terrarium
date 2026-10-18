import Observation
import SwiftUI
import WebKit

// The native IDE's state and actions (D31). Files, tabs, panes, breakpoints
// and settings live here; Python and the analysis run in the engine page,
// editing in one editor page per pane.

struct Pane: Codable, Equatable {
    var tabs: [String] = []
    var active: String?
}

struct Breakpoint: Codable, Equatable, Hashable {
    var line: Int
    var enabled: Bool
}

struct ProblemCounts: Equatable {
    var errors = 0
    var warnings = 0
    var total: Int { errors + warnings }
}

struct EditorSettings: Codable, Equatable {
    enum Appearance: String, Codable, CaseIterable {
        case system, light, dark

        var label: String { rawValue.capitalized }
        var style: UIUserInterfaceStyle { self == .light ? .light : self == .dark ? .dark : .unspecified }
    }

    var fontSize = 15
    var wrap = true
    /// The code editor's color theme (web/src/editor/themes.ts, D39).
    var theme = "terrarium"
    /// The whole app's, so the editor's themes show their light or dark side.
    var appearance = Appearance.system
    static let fontSizes = 11...24

    init() {}

    // Settings saved before a key existed keep the rest.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try c.decodeIfPresent(Int.self, forKey: .fontSize) ?? fontSize
        wrap = try c.decodeIfPresent(Bool.self, forKey: .wrap) ?? wrap
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? theme
        appearance = (try? c.decodeIfPresent(Appearance.self, forKey: .appearance)) ?? appearance
    }

    /// What the editor pages get.
    var editorPayload: [String: Any] { ["fontSize": fontSize, "wrap": wrap, "theme": theme] }
}

/// A code editor theme as the editor page describes it (for Settings' previews).
struct EditorTheme: Identifiable, Equatable {
    struct Palette: Equatable {
        let colors: [String: String]
        var keywordBold = false
        func color(_ key: String) -> Color { UIColorParser.color(colors[key]) ?? .gray }
    }

    let id: String
    let name: String
    let light: Palette
    let dark: Palette
}

enum ConsoleDetent: String {
    case peek, half, full
}

enum ActiveSheet: Identifiable, Equatable {
    case find, settings, problems, jump(String), agent, homeScreen(String), newFile(String), move(String)
    var id: String {
        switch self {
        case .homeScreen: "homeScreen"
        case .newFile: "newFile"
        case .move: "move"
        case .find: "find"
        case .settings: "settings"
        case .problems: "problems"
        case .jump: "jump"
        case .agent: "agent"
        }
    }
}

/// A popover anchored in an editor pane (rect in the pane's coordinates).
struct EditorPopover: Identifiable, Equatable {
    enum Kind: Equatable {
        case value(String) // the debugger's value of an expression
        case info(String?) // ty's hover text (nil while loading)
    }
    let id = UUID()
    let pane: Int
    let rect: CGRect
    var kind: Kind
    /// Show Info: the docs of what is at the cursor (D37), once looked up.
    var docs: DocsTarget?
}

struct BreakpointMenu: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let line: Int
    let enabled: Bool
    let count: Int
}

enum ConsoleField: Hashable {
    case console, input
}

enum Route: Hashable {
    case folder(String)
    case editor
    case trash
}

func isExternal(_ path: String) -> Bool { path.hasPrefix("ext:") }
func dirname(_ path: String) -> String { path.contains("/") ? String(path[..<path.lastIndex(of: "/")!]) : "" }
func basename(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }
func joinPath(_ parts: String...) -> String { parts.filter { !$0.isEmpty }.joined(separator: "/") }
func isLocationRoot(_ path: String) -> Bool { path.hasPrefix("@") && !path.contains("/") }
func displayName(_ path: String) -> String {
    if path.isEmpty { return "Files" }
    return isLocationRoot(path) ? String(path.dropFirst()) : basename(path)
}
func tabLabel(_ path: String) -> String { basename(path.replacingOccurrences(of: "ext:", with: "")) }

@MainActor @Observable
final class AppModel {
    // services
    @ObservationIgnored let host: WebHost
    @ObservationIgnored private(set) var engine: PageController!
    @ObservationIgnored private(set) var editors: [PageController] = []
    @ObservationIgnored var engineView: WKWebView { engine.webView }
    let ui = UIHost()
    let session = SessionMirror()
    var turtles: [String: TurtleScene] = [:]

    // the coding agent (D34, AppModel+Agent.swift)
    let agent = AgentMirror()
    let agentHost = AgentHost()
    var agentAccounts: [AgentAccount] = []
    var agentModels: [AgentModelOption] = []
    var agentLoginError: String?
    var agentAccountsShown = false
    /// Edits in the transcript start expanded (the agent=demo launch hook, for screenshots).
    var agentExpandEdits = false
    var agentListShown = false
    /// The agent sheet's height on iPhone: it makes room when the agent opens a file.
    var agentDetent: PresentationDetent = .large
    /// When the user last typed in each pane (the agent's ide_open does not switch away then).
    @ObservationIgnored var lastTyped: [Int: Date] = [:]

    // workspace
    var panes: [Pane] = [Pane()]
    var focusedPane = 0
    var route: [Route] = [] // iPhone: folders and the editor; iPad: folders in the sidebar
    var wide = false
    /// The window's width: the editor's title must fit between the bar's buttons.
    var windowWidth: CGFloat = 390
    var problems = [ProblemCounts(), ProblemCounts()]
    var editorFocused = false
    var fileListVersion = 0
    var breakpoints: [String: [Breakpoint]] = [:]
    var settings = EditorSettings()
    var consoleDetent: ConsoleDetent = .peek
    var consoleDocked = true
    var sidebarVisible = true
    var splitRatio: CGFloat = 0.5
    var activeSheet: ActiveSheet?
    var popover: EditorPopover?
    var breakpointMenu: BreakpointMenu?
    var toast: String?
    var focusedField: ConsoleField?
    var consoleInput = ""
    var programInput = ""
    var consoleHistory: [String] = []
    /// Python versions (D37): the default (Settings), and what the current file runs on.
    var defaultPython = Runtimes.defaultPython
    var filePython: PythonChoice?
    /// The Python the current file's folder pins in its own `.python-version`.
    var folderPin: String?
    /// Files and folders pinned to the top of the browser (D41).
    var favorites: [String] = []
    /// What each pane's file is as a notebook (D44, AppModel+Notebook.swift).
    var notebookPanes: [Int: NotebookPane] = [:]
    /// The editor's themes (from an editor page), for the color around the editor.
    var editorThemeList: [EditorTheme] = []
    @ObservationIgnored var notebookPrompt: NotebookPrompt?
    @ObservationIgnored let docs = DocsPresenter()
    /// The device modules' native side (D40).
    @ObservationIgnored lazy var device: DeviceBridge = {
        let bridge = DeviceBridge(hostFS: host.hostFS)
        bridge.model = self
        return bridge
    }()

    @ObservationIgnored private var lastUsed: [String: Date] = [:]
    @ObservationIgnored private var writes: Task<Void, Never>?
    @ObservationIgnored private var rootSync: Task<Void, Never>?
    @ObservationIgnored private var rootDir: String?
    @ObservationIgnored private var lastStop: (Int, Int)?
    @ObservationIgnored private var lastRunCounter = 0
    /// The run a ui app's Restart ends: the app view stays up until the new run shows its UI or ends.
    @ObservationIgnored private var restartingRun: Int?
    @ObservationIgnored private var lastTurtleLine = 0
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var restored = false
    @ObservationIgnored let selftest = CommandLine.arguments.contains("--selftest")
    /// The console of an engine page iOS ended (D50), for the page that replaces it.
    @ObservationIgnored private var lostSession: String?
    /// The self-test's results while its page is replaced (`engine_recovery`).
    @ObservationIgnored var selftestStash: String?

    /// What the heaps of all Python programs may use together (D50). On the
    /// 6 GB iPhone 14 Pro, iOS ended the engine's process (no MemoryError)
    /// with the heaps at 925 MB but not at 850 MB, every page written
    /// (`memory_full` self-test, 2026-10-17); the rest of the page (the agent,
    /// bigger analysis) needs room too. 0.12 of the memory is about 680 MB there.
    static var pythonMemoryBudget: Int {
        let ram = Double(ProcessInfo.processInfo.physicalMemory)
        return Int(min(max(ram * 0.12, 512 * 1_048_576), 3 * 1_073_741_824))
    }

    static let maxTabs = 10

    init() {
        let files = FileStore(locations: Locations())
        host = WebHost(files: files)
        let args = CommandLine.arguments
        if selftest {
            try? FileManager.default.removeItem(at: WebHost.documentURL(".probe-result.json"))
            try? FileManager.default.removeItem(at: WebHost.documentURL(".probe-log.txt"))
        } else if let size = (try? FileManager.default.attributesOfItem(atPath: WebHost.documentURL(".probe-log.txt").path))?[.size] as? Int,
                  size > 256 * 1024 {
            // The host's diagnostics log grows with every launch; keep it small outside the self-test.
            try? FileManager.default.removeItem(at: WebHost.documentURL(".probe-log.txt"))
        }
        if args.contains("--reset") {
            for url in (try? FileManager.default.contentsOfDirectory(at: files.root, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        loadDefaults()
        // A cold launch from a link, for testing (simctl launch … --launch-url <url>): waits like a real one.
        if let i = args.firstIndex(of: "--launch-url"), i + 1 < args.count, let url = URL(string: args[i + 1]), let action = LaunchAction(url: url) {
            LaunchRouter.send(action)
        }
        var fragment = selftest ? "#selftest" : ""
        if let i = args.firstIndex(of: "--fragment"), i + 1 < args.count { fragment = "#" + args[i + 1] }
        var query = ""
        if let i = args.firstIndex(of: "--query"), i + 1 < args.count, !args[i + 1].isEmpty { query = "?" + args[i + 1] }
        // The engine runs the self-test (it has the session); launch hooks are ours.
        let engineFragment = fragment.hasPrefix("#selftest") ? fragment : ""
        engine = PageController(
            webView: host.makeWebView(role: .engine, page: "engine.html\(query)\(engineFragment)"),
            script: "return await window.__engine.command(name, args)"
        )
        agentHost.engineView = engine.webView
        editors = (0..<2).map { i in
            PageController(webView: host.makeWebView(role: .editor(i), page: "editor.html"), script: "return await window.__editor.call(name, args)")
        }
        // Files a program changed (D35) show up in the browser and in open tabs.
        host.hostFS.onChange = { [weak self] paths in self?.filesChanged(paths) }
        host.handler = { [weak self] op, value, role, reply in
            guard let self else { return reply(nil, "gone") }
            self.handle(op, value, role, reply)
        }
        host.onTerminate = { [weak self] role in
            switch role {
            case .engine:
                self?.engine.markNotReady()
                self?.agentHost.engineTerminated()
                self?.host.unmountAll() // its interpreters are gone
                self?.engineLost()
            case .editor(let i): self?.editors[i].markNotReady()
            }
        }
        ui.store.send = { [weak self] id, args in
            Task { _ = try? await self?.engine.call("uiEvent", ["id": id, "args": args]) }
        }
        ui.store.close = { [weak self] in
            Task { _ = try? await self?.engine.call("closeUI", [:]) }
        }
        ui.store.restart = { [weak self] in self?.restartUIApp() }
        Task { await self.restoreTabs(fragment: fragment) }
        purgeTrash()
    }

    // MARK: persistence

    private func loadDefaults() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "settings"), let s = try? JSONDecoder().decode(EditorSettings.self, from: data) { settings = s }
        favorites = d.stringArray(forKey: "favorites") ?? []
        if let python = d.string(forKey: "python.default"), Runtimes.runtime(python) != nil { defaultPython = python }
        if let data = d.data(forKey: "breakpoints"), let b = try? JSONDecoder().decode([String: [Breakpoint]].self, from: data) { breakpoints = b }
        if let data = d.data(forKey: "tabs"), let saved = try? JSONDecoder().decode([Pane].self, from: data), !saved.isEmpty {
            panes = Array(saved.prefix(2)).map { Pane(tabs: $0.tabs.filter { !isExternal($0) }, active: $0.active.flatMap { isExternal($0) ? nil : $0 }) }
            focusedPane = min(d.integer(forKey: "focusedPane"), panes.count - 1)
        }
    }

    func saveTabs() {
        let clean = panes.map { Pane(tabs: $0.tabs.filter { !isExternal($0) }, active: $0.active.flatMap { isExternal($0) ? nil : $0 }) }
        UserDefaults.standard.set(try? JSONEncoder().encode(clean), forKey: "tabs")
        UserDefaults.standard.set(focusedPane, forKey: "focusedPane")
    }

    func updateSettings(_ change: (inout EditorSettings) -> Void) {
        var s = settings
        change(&s)
        s.fontSize = min(max(s.fontSize, EditorSettings.fontSizes.lowerBound), EditorSettings.fontSizes.upperBound)
        settings = s
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: "settings")
        applyAppearance()
        for editor in editors { Task { _ = try? await editor.call("settings", [s.editorPayload]) } }
    }

    /// Light, dark or the system's, for every window (the editor pages and the
    /// docs viewer follow it through prefers-color-scheme).
    func applyAppearance() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = settings.appearance.style
                // What shows where no view draws, e.g. while the keyboard slides in.
                window.backgroundColor = UIColor(editorBackground)
            }
        }
    }

    /// The editor theme's background, light or dark as the window is: around the
    /// editor (under the console panel, in the bottom safe area).
    var editorBackground: Color {
        guard let theme = editorThemeList.first(where: { $0.id == settings.theme }) ?? editorThemeList.first,
              let light = UIColorParser.uiColor(theme.light.colors["bg"]),
              let dark = UIColorParser.uiColor(theme.dark.colors["bg"]) else { return Color(.systemBackground) }
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    /// The code editor's themes, from an editor page.
    func editorThemes() async -> [EditorTheme] {
        guard let raw = await editorCall(0, "themes") as? [[String: Any]] else { return [] }
        func palette(_ any: Any?) -> EditorTheme.Palette {
            let dict = any as? [String: Any] ?? [:]
            return EditorTheme.Palette(colors: dict.compactMapValues { $0 as? String }, keywordBold: dict["keywordBold"] as? Bool ?? false)
        }
        return raw.compactMap { t in
            guard let id = t["id"] as? String, let name = t["name"] as? String else { return nil }
            return EditorTheme(id: id, name: name, light: palette(t["light"]), dark: palette(t["dark"]))
        }
    }

    // MARK: derived

    var split: Bool { wide && panes.count > 1 }
    var focused: Int { split ? focusedPane : wide ? min(focusedPane, panes.count - 1) : 0 }
    var file: String? { panes.indices.contains(focused) ? panes[focused].active : nil }
    var currentDir: String {
        if case .folder(let dir) = route.last(where: { if case .folder = $0 { true } else { false } }) { return dir }
        return ""
    }
    var editorShown: Bool { wide || route.last == .editor }

    func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation { toast = text }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { withAnimation { self.toast = nil } }
        }
    }

    func haptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: engine calls

    @discardableResult
    func command(_ name: String, _ args: [String: Any] = [:]) async -> Any? {
        do {
            return try await engine.call(name, args)
        } catch {
            WebHost.appendDocument(".probe-log.txt", "[engine] \(name) failed: \(error)\n")
            return nil
        }
    }

    func analysis(_ method: String, _ args: [Any]) async throws -> Any? {
        try await engine.call("analysis", ["method": method, "args": args])
    }

    @discardableResult
    func editorCall(_ pane: Int, _ method: String, _ args: [Any] = []) async -> Any? {
        guard editors.indices.contains(pane) else { return nil }
        return try? await editors[pane].call(method, args)
    }

    // MARK: bridge ops from the pages

    private func handle(_ op: String, _ value: [String: Any], _ role: WebHost.Role, _ reply: @escaping WebHost.Reply) {
        switch (role, op) {
        case (.engine, "engine.ready"):
            engine.markReady()
            host.unmountAll() // left by a page that reloaded
            fileListVersion += 1 // the engine seeds the examples before it is ready (a first launch lists them)
            let lost = lostSession
            lostSession = nil
            Task {
                await command("setMemoryBudget", ["bytes": Self.pythonMemoryBudget])
                if let lost { await command("restoreSession", ["json": lost]) }
                await command("setDefaultPython", ["python": defaultPython])
                await command("setBreakpoints", ["data": breakpointsJSON()])
                await syncAnalysisRoot(force: true)
                await refreshFilePython()
            }
            reply(nil, nil)
        case (.engine, "session.state"):
            if let json = value["json"] as? String { session.apply(json) }
            sessionChanged()
            reply(nil, nil)
        case (.engine, "ui.render"):
            ui.render(value["json"] as? String)
            reply(nil, nil)
        case (.engine, "files.changed"):
            filesChanged(value["paths"] as? [String] ?? [])
            reply(nil, nil)
        case (.engine, "breakpoints.changed"):
            setBreakpointsFromEngine(value["data"] as? [String: Any] ?? [:])
            reply(nil, nil)
        case (.engine, "notebook.events"):
            notebookEvents(value)
            reply(nil, nil)
        case (.engine, "notebook.input"):
            notebookInput(value["prompt"] as? String ?? "", reply: reply)
        case (.engine, "turtle.ops"):
            if let key = value["key"] as? String, let ops = value["ops"] as? String { turtle(key).apply(ops) }
            reply(nil, nil)
        case (.engine, "turtle.state"):
            if let key = value["key"] as? String {
                turtle(key).setState(live: value["live"] as? Bool ?? false, active: value["active"] as? Bool ?? false,
                                     pointer: value["pointer"] as? Bool ?? false, keys: value["keys"] as? Bool ?? false)
            }
            reply(nil, nil)
        case (.engine, "test.link"), (.engine, "test.ui"), (.engine, "test.type"), (.engine, "test.turtle"), (.engine, "test.keybar"), (.engine, "test.hideKeyboard"), (.engine, "app"):
            SelfTest.handle(self, op, value, reply)
        case (.editor(let pane), "editor.event"):
            editorEvent(pane, value)
            reply(nil, nil)
        case (.editor, "analysis"):
            Task {
                do {
                    reply(try await analysis(value["method"] as? String ?? "", value["args"] as? [Any] ?? []), nil)
                } catch {
                    reply(nil, "\(error)")
                }
            }
        case (.engine, "agent.state"):
            if let json = value["json"] as? String { agent.apply(json) }
            reply(nil, nil)
        case (.engine, "ide"):
            Task {
                do {
                    reply(try await ideOperation(value) ?? NSNull(), nil)
                } catch {
                    reply(nil, error.localizedDescription)
                }
            }
        case (.engine, _) where op.hasPrefix("device."):
            device.handle(op, value, reply: reply)
        case (.engine, _) where op.hasPrefix("docs."):
            handleDocs(op, value, reply)
        case (.engine, "agent.flushEditors"):
            // The agent is about to read files: what was typed must be on disk.
            Task {
                await saveAll()
                reply(nil, nil)
            }
        case (.engine, _) where op.hasPrefix("agent."):
            if !agentHost.handle(op, value, reply) { reply(nil, "unknown op \(op)") }
        default:
            reply(nil, "unknown op \(op)")
        }
    }

    private func turtle(_ key: String) -> TurtleScene {
        if let scene = turtles[key] { return scene }
        let scene = TurtleScene(key: key)
        turtles[key] = scene
        return scene
    }

    func sendTurtle(_ scene: TurtleScene, _ event: [String: Any]) {
        Task { _ = await command("turtle", ["key": scene.key, "event": event]) }
    }

    // MARK: session changes

    /// iOS ended the engine's process (D50): keep the console for the page
    /// that replaces it, and end what its programs had on screen.
    private func engineLost() {
        lostSession = session.snapshotJSON()
        device.reset() // its dialogs, sensors and sounds
        for scene in turtles.values { scene.setState(live: false, active: false, pointer: false, keys: false) }
        if let kernel = session.kernel {
            notebookEvents(["path": kernel.path, "events": [["type": "kernel", "state": "dead"]]])
        }
        if notebookPrompt != nil { answerNotebookPrompt(nil, dismiss: true) }
    }

    private func sessionChanged() {
        let debug = session.debug
        // A restarted ui app is done restarting once its new run shows its UI or ends.
        if let run = restartingRun, session.runCounter != run, session.uiOpen || !session.running {
            restartingRun = nil
            ui.restarting = false
        }
        // UI apps are on screen while they run (or restart), except while the debugger is paused.
        let showUI = (session.uiOpen || restartingRun != nil) && debug == nil
        if showUI != ui.visible {
            if showUI { ui.show() } else { ui.hide() }
        }
        // A new run or a pending input() brings the console up.
        if session.runCounter != lastRunCounter {
            lastRunCounter = session.runCounter
            if consoleDetent == .peek { consoleDetent = .half }
            if wide { consoleDocked = true }
        }
        // A cell's input() alert goes when its cell was stopped.
        if !session.running, notebookPrompt != nil { answerNotebookPrompt(nil, dismiss: true) }
        if session.awaitingInput {
            if consoleDetent == .peek { consoleDetent = .half }
            if focusedField != .input { focusedField = .input }
        } else if focusedField == .input {
            focusedField = nil
        }
        // A new turtle drawing gets the whole height on iPhone.
        let lastTurtle = session.lines.last(where: { $0.kind == "turtle" })?.id ?? 0
        if lastTurtle > lastTurtleLine {
            lastTurtleLine = lastTurtle
            if !wide { consoleDetent = .full }
        }
        // Turtle scenes that left the transcript are forgotten.
        if turtles.count > 4 {
            let shown = Set(session.lines.filter { $0.kind == "turtle" }.map(\.text))
            for key in turtles.keys where !shown.contains(key) && !(turtles[key]?.live ?? false) { turtles.removeValue(forKey: key) }
        }
        // The debugger: follow the paused frame.
        let stop = debug.map { ($0.stopId, $0.selected) }
        if stop?.0 != lastStop?.0 || stop?.1 != lastStop?.1 {
            let isNewStop = stop?.0 != lastStop?.0
            lastStop = stop
            if let debug, let frame = debug.frame {
                if isNewStop && !debug.postMortem { haptic() }
                if !wide, route.last != .editor { route.append(.editor) }
                if isNewStop && !wide && consoleDetent == .full { consoleDetent = .half }
                if !panes.enumerated().contains(where: { $0.element.active == frame.file && (split || $0.offset == focused) }) {
                    Task { await openLocation(frame.file, keepConsole: true) }
                }
            }
            popover = nil
            for i in editors.indices { Task { await syncEditorDebug(i) } }
        }
    }

    private func syncEditorDebug(_ pane: Int) async {
        let debug = session.debug
        let path = panes.indices.contains(pane) ? panes[pane].active : nil
        await editorCall(pane, "setPaused", [debug != nil, debug?.postMortem ?? false])
        let line: Any = (debug?.frame).flatMap { $0.file == path ? $0.line : nil } ?? NSNull()
        await editorCall(pane, "setDebugLine", [line, visibleFraction])
    }

    var visibleFraction: Double {
        wide ? 0.9 : consoleDetent == .peek ? 0.85 : consoleDetent == .half ? 0.45 : 0.15
    }

    /// Files written by a program show up in the browser and in open tabs.
    private func filesChanged(_ paths: [String]) {
        fileListVersion += 1
        for path in paths where panes.contains(where: { $0.tabs.contains(path) }) {
            Task {
                guard let text = try? await host.onFileQueue({ try $0.read(path, encoding: "utf8") }) else { return }
                for i in editors.indices { await editorCall(i, "replaceText", [path, text]) }
            }
        }
        // A UI app saving its data every second should not make ty re-read the folder.
        if paths.contains(where: { $0.hasSuffix(".py") || $0.hasSuffix(".pyi") }) { Task { await syncAnalysisRoot(force: true) } }
    }

    // MARK: editor events

    private func editorEvent(_ pane: Int, _ value: [String: Any]) {
        let type = value["type"] as? String ?? ""
        switch type {
        case "ready":
            editors[pane].markReady()
            Task {
                await editorCall(pane, "settings", [settings.editorPayload])
                if editorThemeList.isEmpty {
                    editorThemeList = await editorThemes()
                    applyAppearance()
                }
                if pane < panes.count, let active = panes[pane].active, restored { await show(active, in: pane) }
            }
        case "changes":
            guard let path = value["path"] as? String, let changes = value["changes"] as? String else { return }
            lastTyped[pane] = Date()
            let notebook = value["notebook"] as? Bool ?? false
            for other in editors.indices where other != pane && panes.indices.contains(other) && panes[other].tabs.contains(path) {
                Task { _ = await editorCall(other, "applyRemote", [path, changes, notebook]) }
            }
        case "text":
            guard let path = value["path"] as? String, let text = value["text"] as? String, !isExternal(path) else { return }
            write(path, text)
        case "focus":
            let focused = value["focused"] as? Bool ?? false
            editorFocused = focused
            if focused {
                if focusedPane != pane, pane < panes.count { focusedPane = pane }
                KeyboardAccessory.shared.webView = editors[pane].webView
                focusedField = nil
            }
        case "problems":
            problems[pane] = ProblemCounts(errors: value["errors"] as? Int ?? 0, warnings: value["warnings"] as? Int ?? 0)
        case "longPress":
            guard let path = value["path"] as? String, let line = value["line"] as? Int, !isExternal(path) else { return }
            gutterLongPress(pane, path, line)
        case "breakpoints":
            guard let path = value["path"] as? String, let list = value["breakpoints"] as? [[String: Any]] else { return }
            setBreakpoints(path, list.map { Breakpoint(line: $0["line"] as? Int ?? 0, enabled: $0["enabled"] as? Bool ?? true) }, fromEditor: pane)
        case "inspect":
            guard session.debug != nil, let expr = value["expr"] as? String else { return }
            popover = EditorPopover(pane: pane, rect: rect(value["rect"]), kind: .value(expr))
        case "definition":
            Task { _ = await goToDefinition() }
        case "info":
            Task { _ = await showInfo() }
        case "showProblems":
            activeSheet = .problems
        case "notebook", "runCells", "stop", "restartKernel", "openURL", "openLocation", "notebookError":
            notebookEditorEvent(pane, type, value)
        case "openLink":
            // A link in a Markdown preview to another file (D46).
            guard let path = value["path"] as? String else { return }
            Task { await openLink(path, fragment: value["fragment"] as? String ?? "") }
        default:
            break
        }
    }

    private func rect(_ v: Any?) -> CGRect {
        let r = v as? [String: Any] ?? [:]
        func n(_ k: String) -> CGFloat { CGFloat((r[k] as? NSNumber)?.doubleValue ?? 0) }
        return CGRect(x: n("x"), y: n("y"), width: max(1, n("width")), height: max(1, n("height")))
    }

    // MARK: files and saving

    /// Write a file (in order with other writes).
    func write(_ path: String, _ text: String) {
        let previous = writes
        writes = Task {
            await previous?.value
            do {
                try await host.onFileQueue { try $0.write(path, data: text, encoding: "utf8") }
            } catch {
                showToast("Could not save \(basename(path)): \(error)")
            }
        }
    }

    /// Everything typed so far is on disk.
    func saveAll() async {
        for i in editors.indices where i < panes.count {
            guard let path = panes[i].active, !isExternal(path) else { continue }
            if let text = await editorCall(i, "flush") as? String { write(path, text) }
        }
        await writes?.value
    }

    func readText(_ path: String) async throws -> String {
        if isExternal(path) { return try await analysis("source", [path]) as? String ?? "" }
        await writes?.value
        return try await host.onFileQueue { try $0.read(path, encoding: "utf8") }
    }

    // MARK: opening files

    private func restoreTabs(fragment: String) async {
        // Tabs of files that are gone close.
        var next = panes
        for i in next.indices {
            var tabs: [String] = []
            for t in next[i].tabs where (try? await host.onFileQueue({ try $0.exists(t) })) == true { tabs.append(t) }
            next[i].tabs = tabs
            if let a = next[i].active, !tabs.contains(a) { next[i].active = tabs.first }
        }
        if next.count > 1 && next[1].tabs.isEmpty { next = [next[0]] }
        panes = next
        focusedPane = min(focusedPane, panes.count - 1)
        restored = true
        for (i, p) in panes.enumerated() { if let a = p.active { await show(a, in: i) } }
        await launchHooks(fragment)
        // Shortcuts and terrarium:// links (D38), including the one that launched the app.
        LaunchRouter.attach { [weak self] action in self?.launch(action) }
        TerrariumShortcuts.updateAppShortcutParameters()
    }

    /// Open or run a program for a Home Screen shortcut or a link (D38).
    func launch(_ action: LaunchAction) {
        Task {
            await engine.whenReady()
            let path: String
            switch action {
            case .run(let p), .open(let p): path = p
            }
            guard (try? await host.onFileQueue({ try $0.exists(path) })) == true else {
                showToast("“\(basename(path))” doesn't exist anymore")
                return
            }
            guard case .run = action else { return await openFile(path) }
            // Whatever runs now ends first, as with Stop.
            if session.uiOpen { await command("closeUI") }
            if session.running { await command("stop") }
            for _ in 0..<40 where session.running || session.uiOpen { try? await Task.sleep(for: .milliseconds(50)) }
            await openFile(path)
            await run()
        }
    }

    /// Shows `path` in an editor pane (loading its text if the pane has no state for it).
    private func show(_ path: String, in pane: Int) async {
        let editor = pane
        // Shows can overlap (restoring tabs, launch hooks, the debugger): only
        // the pane's current file may be opened.
        let current = { self.panes.indices.contains(pane) && self.panes[pane].active == path }
        if await editorCall(editor, "has", [path]) as? Bool != true {
            guard let text = try? await readText(path), current() else { return }
            await editorCall(editor, "open", [path, text, isExternal(path)])
        } else {
            guard current() else { return }
            await editorCall(editor, "open", [path, "", isExternal(path)])
        }
        await editorCall(editor, "setBreakpoints", [breakpointList(path)])
        await syncEditorDebug(editor)
        await syncAnalysisRoot()
    }

    func openFile(_ path: String) async {
        await openLocation(path)
    }

    /// Show a file, optionally at a line: in the pane where it is already the
    /// active tab, else as a tab in the focused pane.
    func openLocation(_ path: String, line: Int? = nil, column: Int? = nil, pane: Int? = nil, keepConsole: Bool = false) async {
        let shownIn = panes.indices.first { panes[$0].active == path && (split || $0 == focused) }
        let target = pane ?? shownIn ?? focused
        let previous = file
        if target >= panes.count { panes.append(Pane()) }
        var p = panes[target]
        let dropped = withTab(&p, path)
        panes[target] = p
        focusedPane = target
        for t in dropped { await editorCall(target, "forget", [t]) }
        guard panes.indices.contains(target) else { return }
        await show(path, in: target)
        if let line { await editorCall(target, "reveal", [line, column ?? 1, visibleFraction]) }
        if !wide, route.last != .editor { route.append(.editor) }
        if !keepConsole && path != previous { consoleDetent = .peek } else if consoleDetent == .full { consoleDetent = .half }
        saveTabs()
    }

    /// Insert a tab right after the active one, like Safari; returns tabs closed by the limit.
    private func withTab(_ pane: inout Pane, _ path: String) -> [String] {
        lastUsed[path] = Date()
        if pane.tabs.contains(path) {
            pane.active = path
            return []
        }
        let at = pane.active.flatMap { pane.tabs.firstIndex(of: $0) }.map { $0 + 1 } ?? pane.tabs.count
        pane.tabs.insert(path, at: at)
        var dropped: [String] = []
        while pane.tabs.count > Self.maxTabs {
            let oldest = pane.tabs.filter { $0 != path }.min { (lastUsed[$0] ?? .distantPast) < (lastUsed[$1] ?? .distantPast) }!
            pane.tabs.removeAll { $0 == oldest }
            dropped.append(oldest)
        }
        pane.active = path
        return dropped
    }

    func selectTab(_ path: String, pane: Int) async {
        lastUsed[path] = Date()
        guard panes.indices.contains(pane) else { return }
        panes[pane].active = path
        focusedPane = pane
        await show(path, in: pane)
        saveTabs()
    }

    func closeTab(_ path: String, pane: Int? = nil) async {
        let index = pane ?? focused
        await saveAll()
        await editorCall(index, "forget", [path])
        guard panes.indices.contains(index) else { return }
        var p = panes[index]
        guard let i = p.tabs.firstIndex(of: path) else { return }
        p.tabs.remove(at: i)
        if p.active == path { p.active = p.tabs.isEmpty ? nil : p.tabs[min(i, p.tabs.count - 1)] }
        panes[index] = p
        if panes.count > 1, panes[1].tabs.isEmpty {
            panes = [panes[0]]
            focusedPane = 0
        } else if panes.count > 1, panes[0].tabs.isEmpty {
            panes = [panes[1]]
            focusedPane = 0
            if let a = panes[0].active { await show(a, in: 0) }
        }
        if let active = panes[min(index, panes.count - 1)].active { await show(active, in: min(index, panes.count - 1)) }
        else { await editorCall(index, "open", [NSNull(), "", false]) }
        saveTabs()
    }

    func closeOtherTabs(_ path: String, pane: Int) async {
        guard panes.indices.contains(pane) else { return }
        for t in panes[pane].tabs where t != path { await editorCall(pane, "forget", [t]) }
        guard panes.indices.contains(pane) else { return }
        panes[pane] = Pane(tabs: [path], active: path)
        saveTabs()
    }

    func setSplit(_ on: Bool) async {
        if on && panes.count == 1 {
            panes.append(Pane(tabs: file.map { [$0] } ?? [], active: file))
            focusedPane = 1
            if let f = file { await show(f, in: 1) }
        } else if !on && panes.count > 1 {
            let active = panes[focused].active ?? panes[0].active
            var tabs = panes[0].tabs
            for t in panes[1].tabs where !tabs.contains(t) { tabs.append(t) }
            panes = [Pane(tabs: tabs, active: active)]
            focusedPane = 0
            if let active { await show(active, in: 0) }
        }
        saveTabs()
    }

    func openInOtherPane(_ path: String, from pane: Int) async {
        if panes.count == 1 {
            if panes[0].tabs.count > 1 { await closeTab(path, pane: 0) }
            panes.append(Pane(tabs: [path], active: path))
            focusedPane = 1
            await show(path, in: 1)
        } else {
            await openLocation(path, pane: pane == 0 ? 1 : 0)
        }
        saveTabs()
    }

    // MARK: file operations

    func rename(_ path: String, to name: String) async -> Bool {
        let to = joinPath(dirname(path), name)
        if (try? await host.onFileQueue({ try $0.exists(to) })) == true {
            showToast("“\(name)” already exists")
            return false
        }
        await saveAll()
        do {
            try await host.onFileQueue { try $0.rename(from: path, to: to) }
        } catch {
            showToast("Could not rename: \(error)")
            return false
        }
        renamed(path, to)
        return true
    }

    func renamed(_ from: String, _ to: String) {
        let moved = { (p: String) in p == from || p.hasPrefix(from + "/") ? to + p.dropFirst(from.count) : p }
        var next: [String: [Breakpoint]] = [:]
        for (p, list) in breakpoints { next[moved(p)] = list }
        if next != breakpoints { commitBreakpoints(next) }
        for i in editors.indices { Task { _ = await editorCall(i, "renamePath", [from, to]) } }
        panes = panes.map { Pane(tabs: $0.tabs.map(moved), active: $0.active.map(moved)) }
        updateFavorites(renamed: from, to: to)
        fileListVersion += 1
        saveTabs()
        // The agent's conversations of a renamed folder work in the new one (D36).
        Task { _ = await agentCall("renamed", [from, to]) }
    }

    func deleted(_ path: String) {
        updateFavorites(deleted: path)
        let gone = { (p: String) in p == path || p.hasPrefix(path + "/") }
        let next = breakpoints.filter { !gone($0.key) }
        if next.count != breakpoints.count { commitBreakpoints(next) }
        for i in editors.indices { Task { _ = await editorCall(i, "forget", [path]) } }
        var next2 = panes.map { pane -> Pane in
            var p = pane
            let wasActive = p.active.map(gone) ?? false
            p.tabs.removeAll(where: gone)
            if wasActive { p.active = p.tabs.first }
            return p
        }
        if next2.count > 1, next2[1].tabs.isEmpty { next2 = [next2[0]] }
        panes = next2
        focusedPane = min(focusedPane, panes.count - 1)
        for i in panes.indices {
            if let a = panes[i].active { Task { await show(a, in: i) } } else { Task { _ = await editorCall(i, "open", [NSNull(), "", false]) } }
        }
        if !wide, route.last == .editor, file == nil { route.removeLast() }
        fileListVersion += 1
        saveTabs()
    }

    func duplicate(_ path: String) async -> String? {
        await saveAll()
        let name = basename(path)
        let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 }
        let stem = dot.map { String(name[..<$0]) } ?? name
        let ext = dot.map { String(name[$0...]) } ?? ""
        var n = 2
        while (try? await host.onFileQueue({ [n] in try $0.exists(joinPath(dirname(path), "\(stem) \(n)\(ext)")) })) == true { n += 1 }
        let copy = joinPath(dirname(path), "\(stem) \(n)\(ext)")
        do {
            let text = try await readText(path)
            try await host.onFileQueue { try $0.write(copy, data: text, encoding: "utf8") }
        } catch {
            showToast("Could not duplicate: \(error)")
            return nil
        }
        fileListVersion += 1
        return copy
    }

    func newFile(in dir: String, name: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return nil }
        let path = joinPath(dir, trimmed.contains(".") ? trimmed : "\(trimmed).py")
        if (try? await host.onFileQueue({ try $0.exists(path) })) == true {
            showToast("“\(basename(path))” already exists")
            return nil
        }
        try? await host.onFileQueue { try $0.write(path, data: "", encoding: "utf8") }
        fileListVersion += 1
        return path
    }

    func newFolder(in dir: String, name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return }
        try? await host.onFileQueue { try $0.mkdir(joinPath(dir, trimmed)) }
        fileListVersion += 1
    }

    func linkFolder(_ url: URL) -> String? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let entry = try host.files.locations.add(url)
            fileListVersion += 1
            return entry["path"] as? String
        } catch {
            showToast("Could not open the folder: \(error)")
            return nil
        }
    }

    func unlink(_ path: String) async {
        await saveAll()
        host.files.locations.remove(named: String(path.dropFirst()))
        deleted(path)
    }

    // MARK: running

    func run() async {
        guard let file, !isExternal(file), !isMarkdown(file) else { return }
        // A notebook runs all its cells, in its kernel (D44).
        if file.hasSuffix(".ipynb") { return notebookCommand("runAll") }
        haptic()
        await saveAll()
        var code = await editorCall(focused, "text") as? String
        if code == nil { code = try? await readText(file) }
        await editorCall(focused, "blur")
        if wide { consoleDocked = true }
        await command("runFile", ["path": file, "code": code ?? ""])
    }

    func stop() {
        haptic()
        Task { _ = await command("stop") }
    }

    /// Runs the ui app's program again, like Run (the close button's menu).
    /// The app view stays up, with a spinner, until the new run shows its UI;
    /// a run that ends without one brings the editor back.
    func restartUIApp() {
        guard restartingRun == nil, let path = session.runningFile else { return }
        haptic()
        let previous = session.runCounter
        restartingRun = previous
        ui.restarting = true
        Task {
            await command("closeUI")
            for _ in 0..<40 where session.running || session.uiOpen { try? await Task.sleep(for: .milliseconds(50)) }
            if (try? await host.onFileQueue({ try $0.exists(path) })) == true {
                await openFile(path)
                await run()
                for _ in 0..<40 where session.runCounter == previous { try? await Task.sleep(for: .milliseconds(50)) }
            } else {
                showToast("“\(basename(path))” doesn't exist anymore")
            }
            // Nothing started: let the view go.
            if restartingRun == previous && session.runCounter == previous {
                restartingRun = nil
                ui.restarting = false
                sessionChanged()
            }
        }
    }

    func pause() {
        haptic()
        Task { _ = await command("pause") }
    }

    func resume(_ op: String) {
        haptic()
        Task { _ = await command("resume", ["op": op]) }
    }

    func selectFrame(_ index: Int) {
        Task { _ = await command("selectFrame", ["index": index]) }
    }

    func debugVariables(_ ref: Int) async -> [DebugVariable] {
        guard let raw = await command("debugVariables", ["ref": ref]),
              let data = try? JSONSerialization.data(withJSONObject: raw) else { return [] }
        return (try? JSONDecoder().decode([DebugVariable].self, from: data)) ?? []
    }

    func debugEvaluate(_ expr: String) async -> (DebugVariable?, String?) {
        guard let raw = await command("debugEvaluate", ["expr": expr]) as? [String: Any] else { return (nil, "No answer") }
        if let error = raw["error"] as? String { return (nil, error) }
        guard let value = raw["value"], let data = try? JSONSerialization.data(withJSONObject: value) else { return (nil, "No value") }
        return (try? JSONDecoder().decode(DebugVariable.self, from: data), nil)
    }

    /// Post-mortem debugging of the last error; `frame` is a traceback frame's
    /// index in the debugger's stack (innermost first, D45).
    func inspectError(frame: Int = 0) {
        Task { _ = await command("inspectError", ["frame": frame]) }
    }

    func clearConsole() {
        Task { _ = await command("clear") }
    }

    /// Counts Return in the console fields; the console scrolls to the end.
    var consoleSubmits = 0

    func submitConsole() {
        consoleSubmits += 1
        let source = consoleInput
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        consoleHistory.removeAll { $0 == source }
        consoleHistory.append(source)
        consoleInput = ""
        if session.debug != nil {
            Task { _ = await command("debugConsole", ["source": source]) }
        } else {
            Task { _ = await command("runConsole", ["source": source]) }
        }
    }

    func submitProgramInput() {
        consoleSubmits += 1
        let text = programInput
        programInput = ""
        Task { _ = await command("submitInput", ["text": text]) }
    }

    func appWillResignActive() {
        Task { await saveAll() }
        Task {
            // The program's queued writes first, then staged copies back to their folders.
            _ = await command("background")
            host.syncMounts()
        }
    }

    // MARK: code intelligence

    func format() async {
        guard let file, !isExternal(file) else { return }
        do {
            let changed = try await editors[focused].call("format", [])
            showToast((changed as? Bool) == true ? "Formatted" : "Already formatted")
        } catch {
            showToast("Could not format: \(error.localizedDescription)")
        }
    }

    private struct Cursor {
        let path: String
        /// What ty knows the file as (a notebook's code as a .py, D44).
        let analysisPath: String
        let text: String
        let line: Int
        let column: Int
        let rect: CGRect?
    }

    private func cursor() async -> Cursor? {
        guard let c = await editorCall(focused, "cursor") as? [String: Any], let path = c["path"] as? String, path == file else { return nil }
        return Cursor(path: path, analysisPath: c["analysisPath"] as? String ?? path, text: c["text"] as? String ?? "",
                      line: c["line"] as? Int ?? 1, column: c["column"] as? Int ?? 1,
                      rect: c["rect"] is [String: Any] ? rect(c["rect"]) : nil)
    }

    func goToDefinition() async -> Any? {
        guard let c = await cursor(), !isMarkdown(c.path) else { return ["skipped": true] }
        if isExternal(c.path) {
            showToast("Not available in library files")
            return nil
        }
        await rootSync?.value // the folder's modules must be known first
        do {
            let targets = try await analysis("definition", [c.analysisPath, c.text, c.line, c.column]) as? [[String: Any]] ?? []
            guard let target = targets.first, var path = target["path"] as? String else {
                showToast("No definition found")
                return ["targets": targets]
            }
            let start = target["start"] as? [String: Any] ?? [:]
            if path == c.analysisPath { path = c.path } // in the notebook itself
            haptic()
            await openLocation(path, line: start["line"] as? Int, column: start["column"] as? Int, keepConsole: true)
            return ["file": c.path, "line": c.line, "column": c.column, "targets": targets]
        } catch {
            showToast("Could not find the definition: \(error.localizedDescription)")
            return nil
        }
    }

    func showInfo() async -> String? {
        guard let c = await cursor(), !isExternal(c.path), !isMarkdown(c.path) else { return nil }
        let pop = EditorPopover(pane: focused, rect: c.rect ?? CGRect(x: 40, y: 80, width: 1, height: 1), kind: .info(nil))
        popover = pop
        let markdown = (try? await analysis("hover", [c.analysisPath, c.text, c.line, c.column])) as? String ?? ""
        if popover?.id == pop.id { popover?.kind = .info(markdown) }
        // A standard library name gets a link into the docs.
        if let docs = await docsTarget(path: c.analysisPath, text: c.text, line: c.line, column: c.column), popover?.id == pop.id {
            popover?.docs = docs
        }
        return markdown
    }

    /// ty sees the folder the program runs in: its modules import like top-level ones.
    func syncAnalysisRoot(force: Bool = false) async {
        guard let file, !isExternal(file) else { return }
        let dir = dirname(file)
        if !force && dir == rootDir { return }
        rootDir = dir
        let previous = rootSync
        let task = Task {
            await previous?.value
            guard let tree = try? await host.onFileQueue({ try $0.tree(dir) }) else { return }
            var files: [[String: String]] = []
            for f in tree.prefix(2000) {
                guard let rel = f["path"], rel.hasSuffix(".py") || rel.hasSuffix(".pyi"),
                      let data = f["data"].flatMap({ Data(base64Encoded: $0) }), let text = String(data: data, encoding: .utf8) else { continue }
                files.append(["path": joinPath(dir, rel), "text": text])
                if files.count >= 300 { break }
            }
            // Files on screen may have edits that are not saved yet.
            for i in editors.indices where i < panes.count {
                guard let path = panes[i].active, let j = files.firstIndex(where: { $0["path"] == path }),
                      let text = await editorCall(i, "text") as? String else { continue }
                files[j]["text"] = text
            }
            _ = try? await analysis("sync", [files])
            _ = try? await analysis("setRoot", [dir])
            // Imports of those modules may have been flagged before ty knew them.
            for i in editors.indices { await editorCall(i, "relint") }
        }
        rootSync = task
        await task.value
    }

    // MARK: breakpoints (D23)

    func breakpointList(_ path: String) -> [[String: Any]] {
        (breakpoints[path] ?? []).map { ["line": $0.line, "enabled": $0.enabled] }
    }

    private func breakpointsJSON() -> [String: Any] {
        breakpoints.mapValues { list in list.map { ["line": $0.line, "enabled": $0.enabled] } }
    }

    private func commitBreakpoints(_ next: [String: [Breakpoint]], fromEditor: Int? = nil, toEngine: Bool = true) {
        let cleaned = next.filter { !$0.value.isEmpty }
        let changed = cleaned.filter { breakpoints[$0.key] != $0.value }.map(\.key) + breakpoints.keys.filter { cleaned[$0] == nil }
        breakpoints = cleaned
        UserDefaults.standard.set(try? JSONEncoder().encode(cleaned), forKey: "breakpoints")
        if toEngine { Task { _ = await command("setBreakpoints", ["data": breakpointsJSON()]) } }
        for i in editors.indices where i != fromEditor && i < panes.count {
            if let active = panes[i].active, changed.contains(active) {
                let list = breakpointList(active)
                Task { _ = await editorCall(i, "setBreakpoints", [list]) }
            }
        }
    }

    func setBreakpoints(_ path: String, _ list: [Breakpoint], fromEditor: Int? = nil) {
        var byLine: [Int: Breakpoint] = [:]
        for bp in list where bp.line > 0 && byLine[bp.line] == nil { byLine[bp.line] = bp }
        let sorted = byLine.values.sorted { $0.line < $1.line }
        guard sorted != (breakpoints[path] ?? []) else { return }
        var next = breakpoints
        next[path] = sorted
        commitBreakpoints(next, fromEditor: fromEditor)
    }

    private func setBreakpointsFromEngine(_ data: [String: Any]) {
        var next: [String: [Breakpoint]] = [:]
        for (path, value) in data {
            next[path] = (value as? [[String: Any]] ?? []).map { Breakpoint(line: $0["line"] as? Int ?? 0, enabled: $0["enabled"] as? Bool ?? true) }
        }
        commitBreakpoints(next, toEngine: false)
    }

    func toggleBreakpoint(_ path: String, line: Int, text: String) {
        var list = breakpoints[path] ?? []
        if list.contains(where: { $0.line == line }) {
            list.removeAll { $0.line == line }
        } else {
            list.append(Breakpoint(line: Self.codeLine(text, from: line), enabled: true))
        }
        setBreakpoints(path, list)
    }

    func setBreakpointEnabled(_ path: String, line: Int, _ enabled: Bool) {
        setBreakpoints(path, (breakpoints[path] ?? []).map { $0.line == line ? Breakpoint(line: line, enabled: enabled) : $0 })
    }

    func removeBreakpoint(_ path: String, line: Int) {
        setBreakpoints(path, (breakpoints[path] ?? []).filter { $0.line != line })
    }

    func clearBreakpoints(_ path: String) {
        setBreakpoints(path, [])
    }

    private func gutterLongPress(_ pane: Int, _ path: String, _ line: Int) {
        let list = breakpoints[path] ?? []
        if let existing = list.first(where: { $0.line == line }) {
            breakpointMenu = BreakpointMenu(path: path, line: line, enabled: existing.enabled, count: list.count)
            return
        }
        haptic()
        Task {
            let text = await editorCall(pane, "text") as? String ?? ""
            toggleBreakpoint(path, line: line, text: text)
        }
    }

    /// A breakpoint on a blank or comment line moves to the next line of code.
    static func codeLine(_ text: String, from line: Int) -> Int {
        let lines = text.components(separatedBy: "\n")
        var i = line - 1
        while i < lines.count {
            let t = lines[max(0, i)].trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && !t.hasPrefix("#") { return i + 1 }
            i += 1
        }
        return line
    }

    func toggleBreakpointAtCursor() async {
        guard let c = await cursor(), !isExternal(c.path) else { return }
        toggleBreakpoint(c.path, line: c.line, text: c.text)
    }

    // MARK: launch hooks for screenshots: open=<path>[&bp=<lines>][&split=<path>][&run][&cells][&top=<text>][&folder=<dir>][&pane=files|editor|console][&cursor=<line>:<col>][&focus[=console]][&type=<text, @@ for the cursor>][&agent[=accounts|conversations|demo]][&ask=<prompt>][&docs=<version>/<ref, # as %23>][&settings][&newfile=<dir>][&move=<path>][&trash]

    private func launchHooks(_ fragment: String) async {
        guard !fragment.hasPrefix("#selftest") else { return }
        var hook: [String: String] = [:]
        for part in fragment.dropFirst().split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            hook[kv[0]] = kv.count > 1 ? kv[1] : ""
        }
        await engine.whenReady()
        if let open = hook["open"] {
            if let bp = hook["bp"] {
                setBreakpoints(open, bp.split(separator: ",").compactMap { Int($0) }.map { Breakpoint(line: $0, enabled: true) })
            }
            await openFile(open)
        }
        if let other = hook["split"] {
            await setSplit(true)
            await openFile(other)
        }
        if let view = hook["view"] { _ = await editorCall(focused, "setView", [view]) } // notebook, preview or source
        if hook["run"] != nil {
            try? await Task.sleep(for: .milliseconds(300))
            await run()
        }
        if hook["cells"] != nil {
            try? await Task.sleep(for: .milliseconds(300))
            notebookCommand("runAll")
        }
        if let text = hook["top"] {
            // After the program or the cells finish (outputs change the heights).
            try? await Task.sleep(for: .milliseconds(1000))
            for _ in 0..<120 where session.running { try? await Task.sleep(for: .milliseconds(500)) }
            try? await Task.sleep(for: .milliseconds(800))
            _ = await editorCall(focused, "scrollToText", [text])
        }
        if let dir = hook["folder"] { route = [.folder(dir)] }
        switch hook["pane"] {
        case "console": if wide { consoleDocked = true } else { consoleDetent = .half }
        case "files": if !wide { route = [] }
        case "editor": if wide { consoleDocked = false }
        default: break
        }
        if let agentHook = hook["agent"] {
            openAgent()
            if agentHook == "accounts" { agentAccountsShown = true }
            if agentHook == "conversations" { agentListShown = true }
            if agentHook == "demo" {
                agentExpandEdits = true
                // A scripted model with real tools (web/src/agent/demo.ts), for the store screenshots.
                for _ in 0..<50 where agent.state.root == nil { try? await Task.sleep(for: .milliseconds(200)) }
                await saveAll()
                if let project = agent.state.root { await agentCall("demo", [project, await ideState()]) }
            }
            if let prompt = hook["ask"] {
                // A fresh conversation in the folder, then the prompt as if typed.
                for _ in 0..<50 where agent.state.root == nil { try? await Task.sleep(for: .milliseconds(200)) }
                if let project = agent.state.root { _ = await agentCall("newConversation", [project, NSNull()]) }
                agentSend(prompt)
            }
        }
        if hook["settings"] != nil { activeSheet = .settings }
        if let path = hook["newfile"] { activeSheet = .newFile(path) }
        if let path = hook["move"] { activeSheet = .move(path) }
        if hook["trash"] != nil { route = [.trash] }
        if let target = hook["docs"], let url = URL(string: "docs:\(target.replacingOccurrences(of: "#", with: "%23"))") {
            try? await Task.sleep(for: .milliseconds(300))
            _ = openDocsLink(url)
        }
        if let at = hook["cursor"] {
            let p = at.split(separator: ":").compactMap { Int($0) }
            _ = await editorCall(focused, "setCursor", [p.first ?? 1, p.count > 1 ? p[1] : 1])
        }
        if hook["focus"] == "console" {
            try? await Task.sleep(for: .milliseconds(600))
            focusedField = .console
        } else if hook["focus"] != nil {
            try? await Task.sleep(for: .milliseconds(600))
            for _ in 0..<5 {
                await editorCall(focused, "focus")
                if KeyboardAccessory.shared.focusForTesting() { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        if let text = hook["type"] {
            // As if typed (completions open); "@@" is where the cursor ends up.
            try? await Task.sleep(for: .milliseconds(500))
            let parts = text.components(separatedBy: "@@")
            _ = await editorCall(focused, "insert", [parts.joined(), parts[0].utf16.count])
        }
    }
}
