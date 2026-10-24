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
    /// A half shows the running ui app (unless it is full screen).
    var halfShowsApp: Bool { wide && (mainRole == .app || (consoleDocked && panelRole == .app)) }
    /// The running ui app over everything: what the program asked for
    /// (`ui.run(full_screen=True)`), unless the user switched.
    var appFullScreen: Bool { appSizeOverride ?? ui.store.fullScreen }
    /// The running ui app is drawn in a half instead of over everything.
    var appInHalf: Bool { halfShowsApp && !appFullScreen }

    /// Full screen, or back in its half (the half's header, the close button's menu).
    func setAppFullScreen(_ on: Bool) {
        withAnimation(.smooth(duration: 0.3)) { appSizeOverride = on }
    }

    /// Puts the app next to the code: in the half that is set to show it, or
    /// if none is, in the other half (shown if it was hidden).
    func showAppInHalf() {
        uncoverHalves()
        withAnimation(.smooth(duration: 0.3)) {
            if !halfShowsApp {
                setPanelRole(.app)
                consoleDocked = true
            }
            appSizeOverride = false
        }
    }

    /// For the close button's menu: the other way to show the app (wide only).
    var appSizeToggle: UISizeToggle? {
        guard wide else { return nil }
        return appInHalf
            ? UISizeToggle(title: "Full Screen", symbol: "arrow.up.left.and.arrow.down.right") { [weak self] in self?.setAppFullScreen(true) }
            : UISizeToggle(title: "Show Next to the Code", symbol: "arrow.down.right.and.arrow.up.left") { [weak self] in self?.showAppInHalf() }
    }
    /// With a vertical bar (the open iPhone Duo), an app over everything always
    /// has a button next to the code in the bar, not only in the close button's
    /// menu: also when no half shows apps, or the other half is hidden.
    var appHalfButton: UISizeToggle? {
        guard wide, verticalBar, !appInHalf else { return nil }
        return appSizeToggle
    }
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

    /// The agent or the docs just came into view in the other half (unfolding
    /// an iPhone Duo, showing the half, picking them): their sheet goes, so
    /// there is only ever one of each, and the half's is the one.
    func panelRolesShown() {
        if agentInPanel, activeSheet == .agent { activeSheet = nil }
        if docsInPanel, docs.isShown {
            if let page = docs.browser?.ref, let version = docs.browser?.version {
                panelDocs?.open(DocsTarget(version: version, ref: page))
            }
            docs.close()
        }
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

    /// The divider between the halves where the user left it (nil: the fold, or the default share).
    func setPanelRatio(_ ratio: CGFloat?) {
        panelRatio = ratio
        if let ratio { UserDefaults.standard.set(Double(ratio), forKey: "halves.ratio") } else { UserDefaults.standard.removeObject(forKey: "halves.ratio") }
    }

    func loadHalves() {
        let d = UserDefaults.standard
        panelFirst = d.bool(forKey: "halves.first")
        panelRatio = (d.object(forKey: "halves.ratio") as? Double).map { CGFloat($0) }
        mainRole = d.string(forKey: "halves.main").flatMap(MainRole.init) ?? .editor
        let panel = d.string(forKey: "halves.panel").flatMap(PanelRole.init) ?? .console
        setPanelRole(panel == .app && mainRole == .app ? .console : panel)
    }
}

/// The main half: the editors, or the app (drawn by HalfOverlays).
struct MainHalf<Editors: View>: View {
    @ViewBuilder var editors: Editors
    @Environment(AppModel.self) private var model
    @Environment(\.topLift) private var lift

    var body: some View {
        if model.mainRole == .app {
            VStack(spacing: 0) {
                // The top row (D61) has no tabs here, but the files toggle and the actions stay.
                if model.wide && !model.verticalBar || !model.actionsAbovePanel {
                    HStack(spacing: 0) {
                        if model.wide && !model.verticalBar { SidebarToggle().padding(.leading, 6).containerCornerOffset(.leading, sizeToFit: true) }
                        Spacer(minLength: 0)
                        if !model.actionsAbovePanel { WorkspaceActions().padding(.horizontal, 8) }
                    }
                    .clearOfTopCorners()
                    .frame(height: model.verticalBar ? 40 : TopRowMetrics.height)
                    .background(Color(.secondarySystemBackground))
                    .overlay(alignment: .bottom) { Divider() }
                }
                HalfSlot(slot: .main)
            }
            // No row: the app keeps clear of the corners where it was.
            .padding(.top, model.actionsAbovePanel && (model.panelSideBySide || !model.panelFirst) ? lift : 0)
        } else {
            editors
        }
    }
}

/// Between the halves: the fold's gutter or a hairline, and a handle to drag
/// (D61); a double tap puts it back (on the fold, or the default share).
struct HalfDivider: View {
    let sideBySide: Bool
    let thickness: CGFloat
    /// The workspace's length along the split axis, and the half's now.
    let total: CGFloat
    let size: CGFloat
    @Environment(AppModel.self) private var model
    @State private var start: CGFloat?

    var body: some View {
        FoldGutter(thickness: thickness, sideBySide: sideBySide)
            .overlay {
                Color.clear
                    .frame(width: sideBySide ? max(16, thickness) : nil, height: sideBySide ? nil : max(16, thickness))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(coordinateSpace: .global).onChanged { g in
                        let base = start ?? size
                        if start == nil { start = base }
                        // The half after the main one grows when the divider goes left (or up).
                        let delta = sideBySide ? g.translation.width : g.translation.height
                        let next = model.panelFirst ? base + delta : base - delta
                        model.panelRatio = min(max(next, 200), total - 280) / max(1, total)
                    }.onEnded { _ in
                        start = nil
                        model.setPanelRatio(model.panelRatio)
                    })
                    .onTapGesture(count: 2) { withAnimation { model.setPanelRatio(nil) } }
                    .accessibilityLabel("Resize the halves")
            }
            .zIndex(1)
    }
}

/// The other half: its header picks what it shows.
struct PanelHalf: View {
    /// Next to the main half (else above or below it).
    let sideBySide: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.topLift) private var lift

    var body: some View {
        VStack(spacing: 0) {
            // Only where the workspace's corner is (D61): the other half on the right.
            if model.actionsAbovePanel { PanelHeader() }
            if model.panelRole == .console {
                // Its frame too: the sliding sidebar dims up to it (slideOverDimEnd).
                ConsoleView().background { HalfSlot(slot: .panel, fill: .clear) }
            } else {
                HalfSlot(slot: .panel)
            }
        }
        // At the top without a header: it keeps clear of the corners where it was.
        .padding(.top, !model.actionsAbovePanel && (sideBySide || model.panelFirst) ? lift : 0)
        .background(Color(.secondarySystemBackground))
    }
}

enum HalfSlotID { case main, panel }

/// Where a half's agent, docs or app goes; its frame is for HalfOverlays.
private struct HalfSlot: View {
    let slot: HalfSlotID
    var fill = Color(.systemBackground)
    @Environment(AppModel.self) private var model
    @State private var id = UUID()
    /// When it came: while two exist for a moment (the half moved), the newer one's frame counts.
    @State private var since = HalfFrame.next()

    var body: some View {
        fill
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { set($0) }
            .onDisappear { set(nil) }
    }

    /// The newest slot on screen has the place: an older slot's late update
    /// doesn't take it back, and when the newest goes, the place goes back to
    /// one still there. (Moving the half to the left at launch made a
    /// short-lived newer slot on the right; when it went, the one that stayed
    /// had no frame and the half's docs never showed.)
    private func set(_ frame: CGRect?) {
        var live = model.liveHalfSlots[slot] ?? [:]
        live[id] = frame.map { HalfFrame(owner: id, rect: $0, since: since) }
        model.liveHalfSlots[slot] = live
        let value = live.values.max { $0.since < $1.since }
        switch slot {
        case .main: if model.mainSlot != value { model.mainSlot = value }
        case .panel: if model.panelSlot != value { model.panelSlot = value }
        }
    }
}

struct HalfFrame: Equatable {
    let owner: UUID
    let rect: CGRect
    var since = 0

    @MainActor private static var counter = 0
    @MainActor static func next() -> Int {
        counter += 1
        return counter
    }
}

/// The halves' agent, docs and ui app, at the window's top level over their slots.
struct HalfOverlays: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { root in
            let origin = root.frame(in: .global).origin
            // The sidebar sliding over the workspace (D61) hides those it
            // covers: their own hosting controllers would draw over it. Those
            // past it stay (on an open Duo, the other screen).
            let shown = model.wide && !model.sidebarOverlaps
            ZStack(alignment: .topLeading) {
                if shown, model.mainRole == .app, let rect = model.mainSlot?.rect, !model.sidebarCovers(rect) {
                    AppHalf().place(rect, origin)
                }
                if shown, model.panelShown, let rect = model.panelSlot?.rect, !model.sidebarCovers(rect) {
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
    /// Clipping only stops the drawing: the content shape stops the touches
    /// too (else a SwiftUI background there, like "No App Running"'s, takes
    /// the vertical bar's taps, Run's among them).
    func place(_ rect: CGRect, _ origin: CGPoint) -> some View {
        frame(width: rect.width, height: rect.height)
            .clipped()
            .contentShape(Rectangle())
            .padding(.leading, rect.minX - origin.x)
            .padding(.top, rect.minY - origin.y)
    }
}

/// Above the other half when it is on the right: the workspace's corner,
/// with its actions (D61), as high as the tab row beside it.
private struct PanelHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            WorkspaceActions().padding(.horizontal, 8)
        }
        .clearOfTopCorners()
        .frame(height: model.verticalBar ? 40 : TopRowMetrics.height)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The running ui app in a half, or what to do to get one.
struct AppHalf: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.ui.visible && model.appFullScreen {
            ContentUnavailableView {
                Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
            } description: {
                Text("The app is over everything. Touch and hold its close button to show it here again.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
        } else if model.ui.visible {
            UIAppRoot(store: model.ui.store, inHalf: true, sizeToggle: model.appSizeToggle)
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
