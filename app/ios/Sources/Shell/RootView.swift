import SwiftUI
import UIKit
import WebKit

/// The app (D31): files and editor in a navigation stack on iPhone, a split
/// view with the files in the sidebar on iPad and an open iPhone Duo (D58);
/// ui apps on top (D30).
struct RootView: View {
    @State private var model = AppModel()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            // The engine page is never shown, but stays in the window.
            WebViewHost(webView: model.engineView)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Group {
                if sizeClass == .regular {
                    WideLayout()
                } else {
                    NarrowLayout()
                }
            }
            // The halves' agent, docs and app (D59), over their places in the workspace.
            HalfOverlays()
            // Over everything, unless a half of the workspace shows it (D59).
            if model.ui.visible && !model.appInHalf {
                UIAppRoot(store: model.ui.store, sizeToggle: model.appSizeToggle, halfButton: model.appHalfButton)
                    .overlay { if model.ui.restarting { ProgressView().controlSize(.large) } }
                    .transition(.move(edge: .bottom))
                    .zIndex(1)
            }
        }
        .overlay(alignment: .top) { ToastView(text: model.toast) }
        .background { ShortcutButtons() }
        .background { VerticalBarProbe { model.verticalBar = $0 } }
        .sheet(item: $model.activeSheet) { sheet in
            Group {
                switch sheet {
                case .find: FindView()
                case .settings: SettingsView()
                case .problems: ProblemsView()
                case .jump(let initial): JumpView(initial: initial)
                case .homeScreen(let path): HomeScreenView(path: path)
                case .newFile(let dir): NewFileView(dir: dir)
                case .move(let path): MoveView(path: path)
                case .agent:
                    AgentView()
                        .presentationDetents([.medium, .large], selection: $model.agentDetent)
                        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                }
            }
            .environment(model)
        }
        .confirmationDialog(
            model.breakpointMenu.map { "Breakpoint on line \($0.line)" } ?? "",
            isPresented: Binding(get: { model.breakpointMenu != nil }, set: { if !$0 { model.breakpointMenu = nil } }),
            titleVisibility: .visible, presenting: model.breakpointMenu
        ) { menu in
            if menu.enabled {
                Button("Disable Breakpoint") { model.setBreakpointEnabled(menu.path, line: menu.line, false) }
            } else {
                Button("Enable Breakpoint") { model.setBreakpointEnabled(menu.path, line: menu.line, true) }
            }
            Button("Remove Breakpoint", role: .destructive) { model.removeBreakpoint(menu.path, line: menu.line) }
            if menu.count > 1 {
                Button("Remove All \(menu.count) in File", role: .destructive) { model.clearBreakpoints(menu.path) }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.windowWidth = $0 }
        .onOpenURL { url in
            if let action = LaunchAction(url: url) { LaunchRouter.send(action) }
        }
        .onChange(of: sizeClass, initial: true) { _, size in model.setWide(size == .regular) }
        // One agent and one docs viewer at a time: the half's when it shows them (D59).
        .onChange(of: model.agentInPanel) { _, shown in if shown { model.panelRolesShown() } }
        .onChange(of: model.docsInPanel) { _, shown in if shown { model.panelRolesShown() } }
        .onHinge { model.hinge = $0 }
        .onChange(of: model.panes) { _, _ in model.agentIDEChanged() }
        .onChange(of: model.file, initial: true) { _, _ in Task { await model.refreshFilePython() } }
        .onChange(of: model.focusedPane) { _, _ in model.agentIDEChanged() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.appWillResignActive() }
        }
        .environment(model)
        .onAppear {
            model.applyAppearance()
            model.loadHalves()
            model.host.presenter = {
                var vc = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
                while let presented = vc?.presentedViewController { vc = presented }
                return vc
            }
        }
    }
}

/// iPhone: files, then the editor (with the console as a panel at the bottom).
private struct NarrowLayout: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.route) {
            FileBrowserView(dir: "")
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .folder(let dir): FileBrowserView(dir: dir)
                    case .editor: EditorScreen()
                    case .trash: TrashView()
                    }
                }
        }
    }
}

/// iPad: files in the sidebar; editors (one or two panes) and the console.
private struct WideLayout: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: Binding(
            get: { model.sidebarVisible ? .all : .detailOnly },
            set: { model.sidebarVisible = $0 != .detailOnly }
        )) {
            NavigationStack(path: $model.route) {
                FileBrowserView(dir: "")
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .folder(let dir): FileBrowserView(dir: dir)
                        case .trash: TrashView()
                        case .editor: EmptyView()
                        }
                    }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
            // With a vertical bar the editor's bar has the toggle (D58).
            .toolbar(removing: model.verticalBar ? .sidebarToggle : nil)
        } detail: {
            NavigationStack { WorkspaceView() }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { model.workspaceMinX = $0 }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

/// Puts a page's web view into SwiftUI (the same instance moves between screens).
struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if webView.superview !== container { attach(to: container) }
    }

    private func attach(to container: UIView) {
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }
}

private struct ToastView: View {
    let text: String?
    var body: some View {
        if let text {
            Text(text)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }
}

/// Hardware keyboard shortcuts (Xcode's and VS Code's where they do not clash).
private struct ShortcutButtons: View {
    @Environment(AppModel.self) private var model

    private static func function(_ n: Int) -> KeyEquivalent {
        KeyEquivalent(Character(UnicodeScalar(0xF703 + n)!))
    }

    var body: some View {
        let debug = model.session.debug
        let stepping = debug != nil && debug?.postMortem == false
        VStack {
            Button("Run") { Task { await model.run() } }.keyboardShortcut("r", modifiers: .command)
            Button("Stop") { model.stop() }.keyboardShortcut(".", modifiers: .command)
            Button("Show Preview or Source") { model.toggleMarkdownView() }.keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Go to Line") { model.activeSheet = .jump(":") }.keyboardShortcut("l", modifiers: .command)
            Button("Go to Symbol") { model.activeSheet = .jump("") }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Find in Folder") { model.activeSheet = .find }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Settings") { model.activeSheet = .settings }.keyboardShortcut(",", modifiers: .command)
            Button("Agent") { model.openAgent() }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Python Docs") { model.showDocs() }.keyboardShortcut("0", modifiers: [.command, .shift])
            Button("Close Tab") { if let f = model.file { Task { await model.closeTab(f) } } }.keyboardShortcut("w", modifiers: .command)
            Button("Split View") { if model.wide { Task { await model.setSplit(!model.split) } } }.keyboardShortcut("\\", modifiers: .command)
            Button("Previous Tab") { cycle(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Tab") { cycle(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Toggle Breakpoint") { Task { await model.toggleBreakpointAtCursor() } }.keyboardShortcut(Self.function(9), modifiers: [])
            Button("Run or Continue") {
                if stepping { model.resume("continue") } else { Task { await model.run() } }
            }.keyboardShortcut(Self.function(5), modifiers: [])
            if stepping {
                Button("Step Over") { model.resume("next") }.keyboardShortcut(Self.function(6), modifiers: [])
                Button("Step Into") { model.resume("stepIn") }.keyboardShortcut(Self.function(7), modifiers: [])
                Button("Step Out") { model.resume("stepOut") }.keyboardShortcut(Self.function(8), modifiers: [])
                Button("Continue") { model.resume("continue") }.keyboardShortcut("y", modifiers: [.command, .control])
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func cycle(_ step: Int) {
        let pane = model.panes[model.focused]
        guard pane.tabs.count > 1, let active = pane.active, let i = pane.tabs.firstIndex(of: active) else { return }
        let next = pane.tabs[(i + step + pane.tabs.count) % pane.tabs.count]
        Task { await model.selectTab(next, pane: model.focused) }
    }
}
