import SwiftUI

// The wide workspace's two halves (D59): the main half shows the editor or
// the running ui app, the other half (where the console docks: right in
// landscape, below otherwise, past the fold on an open iPhone Duo, D58)
// shows the console, the agent, the app or the docs. The user picks; nothing
// switches by itself. Agent, docs and ui apps have navigation stacks of their
// own, which can't be inside the workspace's: SwiftUI leaves out their bars
// and moves their buttons into the workspace's, also from a hosting
// controller of their own. So the halves only keep their place and report
// its frame, and RootView draws them there, at the window's top level
// (HalfOverlays), like a ui app over everything.

/// What the main half shows.
enum MainRole: String {
    case editor, app
}

/// What the other half shows.
enum PanelRole: String, CaseIterable, Identifiable {
    case console, agent, app, docs
    var id: String { rawValue }

    var title: String {
        switch self {
        case .console: "Console"
        case .agent: "Agent"
        case .app: "App"
        case .docs: "Docs"
        }
    }

    var symbol: String {
        switch self {
        case .console: "terminal"
        case .agent: "sparkles"
        case .app: "macwindow"
        case .docs: "book"
        }
    }
}

extension AppModel {
    /// The other half is on screen.
    var panelShown: Bool { wide && consoleDocked }
    /// The running ui app is drawn in a half instead of over everything.
    var appInHalf: Bool { wide && (mainRole == .app || (consoleDocked && panelRole == .app)) }
    var agentInPanel: Bool { panelShown && panelRole == .agent }
    var docsInPanel: Bool { panelShown && panelRole == .docs }

    func setPanelRole(_ role: PanelRole) {
        if role == .app && mainRole == .app { mainRole = .editor }
        panelRole = role
        if role == .agent, activeSheet == .agent { activeSheet = nil }
        if role == .docs, panelDocs == nil {
            panelDocs = DocsBrowser(schemeHandler: host.schemeHandler, target: DocsTarget(version: defaultPython, ref: nil))
        }
        saveHalves()
    }

    /// Moves the app between the halves; the other half gets back what it showed before.
    func swapAppHalf() {
        if mainRole == .app {
            mainRole = .editor
            panelRole = .app
        } else {
            mainRole = .app
            if panelRole == .app { panelRole = lastPanelRole }
        }
        saveHalves()
    }

    /// The other half before the main one: left of it (on an open iPhone Duo,
    /// left of the fold) or above it. The files make room for it.
    func setPanelFirst(_ first: Bool) {
        panelFirst = first
        if first && wide { sidebarVisible = false }
        saveHalves()
    }

    func saveHalves() {
        if panelRole != .app { lastPanelRole = panelRole }
        UserDefaults.standard.set(mainRole.rawValue, forKey: "halves.main")
        UserDefaults.standard.set(panelRole.rawValue, forKey: "halves.panel")
        UserDefaults.standard.set(panelFirst, forKey: "halves.first")
    }

    func loadHalves() {
        let d = UserDefaults.standard
        panelFirst = d.bool(forKey: "halves.first")
        mainRole = d.string(forKey: "halves.main").flatMap(MainRole.init) ?? .editor
        let panel = d.string(forKey: "halves.panel").flatMap(PanelRole.init) ?? .console
        setPanelRole(panel == .app && mainRole == .app ? .console : panel)
    }
}

/// The main half: the editors, or the app (drawn by HalfOverlays).
struct MainHalf<Editors: View>: View {
    @ViewBuilder var editors: Editors
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.mainRole == .app {
            HalfSlot(slot: .main)
        } else {
            editors
        }
    }
}

/// The other half: its header picks what it shows.
struct PanelHalf: View {
    /// Next to the main half (else above or below it).
    let sideBySide: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(sideBySide: sideBySide)
            if model.panelRole == .console {
                ConsoleView()
            } else {
                HalfSlot(slot: .panel)
            }
        }
        .background(Color(.secondarySystemBackground))
    }
}

enum HalfSlotID { case main, panel }

/// Where a half's agent, docs or app goes; its frame is for HalfOverlays.
private struct HalfSlot: View {
    let slot: HalfSlotID
    @Environment(AppModel.self) private var model
    @State private var id = UUID()

    var body: some View {
        Color(.systemBackground)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { set($0) }
            .onDisappear { set(nil) }
    }

    /// A slot that went away clears only its own frame: a new one may have set it already.
    private func set(_ frame: CGRect?) {
        let current = slot == .main ? model.mainSlot : model.panelSlot
        if frame == nil && current?.owner != id { return }
        let value = frame.map { HalfFrame(owner: id, rect: $0) }
        switch slot {
        case .main: model.mainSlot = value
        case .panel: model.panelSlot = value
        }
    }
}

struct HalfFrame: Equatable {
    let owner: UUID
    let rect: CGRect
}

/// The halves' agent, docs and ui app, at the window's top level over their slots.
struct HalfOverlays: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { root in
            let origin = root.frame(in: .global).origin
            // An iPad's sidebar in portrait slides over the workspace: it covers them too.
            let shown = model.wide && !model.sidebarOverlaps
            ZStack(alignment: .topLeading) {
                if shown, model.mainRole == .app, let rect = model.mainSlot?.rect {
                    AppHalf().place(rect, origin)
                }
                if shown, model.panelShown, let rect = model.panelSlot?.rect {
                    switch model.panelRole {
                    case .console:
                        EmptyView()
                    case .agent:
                        AgentView(embedded: true).place(rect, origin)
                            .task { await model.agentOpen(model.agentProject) }
                    case .app:
                        AppHalf().place(rect, origin)
                    case .docs:
                        if let browser = model.panelDocs { DocsView(browser: browser, close: nil).place(rect, origin) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea()
    }
}

private extension View {
    /// Laid out there, not drawn there with an offset: its safe area follows
    /// where it really is. Clipped: backgrounds next to a safe area (the
    /// vertical bar's) reach into it, over the workspace's bar buttons.
    func place(_ rect: CGRect, _ origin: CGPoint) -> some View {
        frame(width: rect.width, height: rect.height)
            .clipped()
            .padding(.leading, rect.minX - origin.x)
            .padding(.top, rect.minY - origin.y)
    }
}

/// The picker, and for the console its run state.
private struct PanelHeader: View {
    let sideBySide: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.session
        let debug = s.debug
        HStack(spacing: 10) {
            Picker("Show", selection: Binding(get: { model.panelRole }, set: { model.setPanelRole($0) })) {
                ForEach(PanelRole.allCases) { role in
                    Image(systemName: role.symbol).accessibilityLabel(role.title).tag(role)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            if model.panelRole == .console {
                StatusDot()
                if let debug {
                    Text(debug.postMortem ? "Inspecting Error" : "Paused").font(.subheadline.weight(.semibold)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if model.panelRole == .console, s.status == "running", debug == nil { PauseButton() }
            if model.panelRole == .app || model.mainRole == .app {
                Button { withAnimation { model.swapAppHalf() } } label: {
                    Image(systemName: "rectangle.2.swap")
                }
                .accessibilityLabel(model.mainRole == .app ? "Show the code in the main half" : "Show the app in the main half")
            }
            Button { withAnimation { model.setPanelFirst(!model.panelFirst) } } label: {
                Image(systemName: sideBySide
                      ? (model.panelFirst ? "rectangle.righthalf.inset.filled" : "rectangle.lefthalf.inset.filled")
                      : (model.panelFirst ? "rectangle.bottomhalf.inset.filled" : "rectangle.tophalf.inset.filled"))
            }
            .accessibilityLabel(sideBySide ? (model.panelFirst ? "Move to the right" : "Move to the left")
                                           : (model.panelFirst ? "Move to the bottom" : "Move to the top"))
        }
        .padding(.horizontal, 12)
        .frame(height: 40) // the tab strip's height: the two line up
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The running ui app in a half, or what to do to get one.
struct AppHalf: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.ui.visible {
            UIAppRoot(store: model.ui.store, inHalf: true)
                .overlay { if model.ui.restarting { ProgressView().controlSize(.large) } }
        } else {
            ContentUnavailableView {
                Label("No App Running", systemImage: "macwindow")
            } description: {
                Text("Run a program that uses ui and it shows here.")
            } actions: {
                if model.mainRole == .app {
                    Button("Show Code") { withAnimation { model.swapAppHalf() } }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
        }
    }
}
