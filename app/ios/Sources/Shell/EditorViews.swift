import SwiftUI

// The editor area: tabs, CodeMirror panes (web views, D31), the navigation
// bar with Run and the ⋯ menu, and where the console goes.

/// iPhone: one pane, the console as a panel at the bottom.
struct EditorScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            // The console reaches down to the screen's edge; collapsed, its header
            // sits a little into the bottom safe area.
            // The window's inset (the home indicator), not the keyboard's: with the
            // keyboard up the panel sits right on it.
            let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets.bottom ?? 0
            let bottom = geo.safeAreaInsets.bottom > window + 1 ? 0 : window
            let lowered = min(ConsolePanel.lowered, bottom)
            // A closed iPhone Duo: the bar buttons are in the vertical bar, so
            // the tabs go up into the top inset like the open one's (D58).
            let lift = model.verticalBar ? topLift(inset: geo.safeAreaInsets.top) : 0
            VStack(spacing: 0) {
                if !model.panes[0].tabs.isEmpty || model.verticalBar { TabStrip(pane: 0) }
                ZStack(alignment: .bottom) {
                    EditorPaneView(pane: 0)
                        .padding(.bottom, model.editorFocused ? 0 : ConsolePanel.peek - lowered)
                        .padding(.bottom, model.editorFocused ? 0 : bottom)
                    if !model.editorFocused {
                        ConsolePanel(maxHeight: geo.size.height, bottomInset: bottom - lowered)
                    }
                }
                .ignoresSafeArea(.container, edges: .bottom)
            }
            .padding(.top, lift > 0 ? geo.safeAreaInsets.top - lift : 0)
            .ignoresSafeArea(.container, edges: lift > 0 ? .top : [])
            .environment(\.topLift, lift)
            .background(model.editorBackground.ignoresSafeArea())
        }
        .background(model.editorBackground.ignoresSafeArea())
        .modifier(EditorChrome())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

/// iPad: one or two panes and the other half: the console, the agent, the app or
/// the docs (D59), right in landscape, below otherwise, or left / above when the
/// user moves it there. On an open iPhone Duo it takes its side of the fold
/// (D58); with two panes side by side the fold divides the panes instead.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let _ = model.hinge // the fold's margins come and go with the hinge
            let first = model.panelFirst
            let fold = geo.crease.flatMap { crease -> (sideBySide: Bool, gap: CGFloat, panel: CGFloat)? in
                if model.split && crease.sideBySide { return nil }
                return crease.sides(in: geo.size, minimum: 280).map { (crease.sideBySide, $0.gap, first ? $0.before : $0.after) }
            }
            let landscape = fold?.sideBySide ?? (geo.size.width > geo.size.height * 1.2 && !model.split)
            let layout = landscape ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            let total = landscape ? geo.size.width : geo.size.height
            // The user's divider (D61) wins over the fold and the default share.
            let dragged = model.panelRatio.map { min(max(total * $0, 200), total - 280) }
            let size = dragged ?? fold?.panel ?? (landscape ? max(320, geo.size.width * 0.38) : geo.size.height * 0.36)
            let panel = PanelHalf(sideBySide: landscape)
                .frame(width: landscape ? size : nil, height: landscape ? nil : size)
            let gutter = HalfDivider(sideBySide: landscape, thickness: dragged == nil ? fold?.gap ?? 1 : 1, total: total, size: size)
            // An open iPhone Duo: the top rows go up into the top inset (only
            // the screen's corners are there, the bar buttons are in the
            // vertical bar) and keep clear of the corners (clearOfTopCorners).
            let lift = model.verticalBar ? topLift(inset: geo.safeAreaInsets.top) : 0
            layout {
                if model.consoleDocked && first {
                    panel
                    gutter
                }
                MainHalf { editors(width: geo.size.width) }
                if model.consoleDocked && !first {
                    gutter
                    panel
                }
            }
            .padding(.top, lift > 0 ? geo.safeAreaInsets.top - lift : 0)
            .ignoresSafeArea(.container, edges: lift > 0 ? .top : [])
            .environment(\.topLift, lift)
            .onChange(of: landscape, initial: true) { _, side in model.panelSideBySide = side }
        }
        .modifier(EditorChrome())
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func editors(width: CGFloat) -> some View {
        if model.split {
            GeometryReader { geo in
                // At the fold unless the user moved the divider.
                let fold = geo.crease.flatMap { $0.sideBySide ? $0.sides(in: geo.size, minimum: geo.size.width * 0.25) : nil }
                let first = model.splitRatio.map { geo.size.width * $0 } ?? fold?.before ?? geo.size.width / 2
                HStack(spacing: 0) {
                    PaneColumn(pane: 0).frame(width: first)
                    SplitDivider(width: geo.size.width, ratio: first / max(1, geo.size.width),
                                 thickness: model.splitRatio == nil ? fold?.gap ?? 1 : 1)
                    PaneColumn(pane: 1)
                }
            }
        } else {
            PaneColumn(pane: model.focused)
        }
    }
}

private struct SplitDivider: View {
    let width: CGFloat
    /// Where it is now (the user's ratio, the fold or the middle).
    let ratio: CGFloat
    let thickness: CGFloat
    @Environment(AppModel.self) private var model
    @State private var start: CGFloat?

    var body: some View {
        FoldGutter(thickness: thickness, sideBySide: true)
            .overlay(Color.clear.frame(width: max(16, thickness)).contentShape(Rectangle()))
            .gesture(DragGesture(coordinateSpace: .global).onChanged { g in
                let base = start ?? ratio
                if start == nil { start = base }
                model.splitRatio = min(0.75, max(0.25, base + g.translation.width / max(1, width)))
            }.onEnded { _ in start = nil })
            .onTapGesture(count: 2) { model.splitRatio = nil }
            .accessibilityLabel("Resize split view")
    }
}

private struct PaneColumn: View {
    let pane: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(pane: pane)
            EditorPaneView(pane: pane)
        }
        .overlay(alignment: .top) {
            if model.split && model.focused == pane {
                Rectangle().fill(.tint).frame(height: 2)
            }
        }
        .simultaneousGesture(TapGesture().onEnded { if model.focusedPane != pane { model.focusedPane = pane } })
    }
}

/// One CodeMirror page, with the popovers that point into it.
struct EditorPaneView: View {
    let pane: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        let empty = !model.panes.indices.contains(pane) || model.panes[pane].active == nil
        ZStack {
            WebViewHost(webView: model.editors[pane].webView)
                // Wide, the text scrolls under the home indicator (D61); the page
                // keeps its end above it. (On iPhone the console panel is there.)
                .ignoresSafeArea(.container, edges: model.wide ? .bottom : [])
                .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { inset in
                    Task { _ = await model.editorCall(pane, "setInsets", [model.wide ? inset : 0]) }
                }
            if empty { EmptyEditor() }
        }
        // The page is transparent: while it resizes (the keyboard comes up) the
        // part it hasn't drawn yet shows this. Wide, it also fills the side
        // insets in landscape (the text stays clear of them).
        .background(model.editorBackground.ignoresSafeArea(.container, edges: model.wide ? [.horizontal, .bottom] : []))
        .popover(item: Binding(
            get: { model.popover?.pane == pane ? model.popover : nil },
            set: { model.popover = $0 }
        ), attachmentAnchor: .rect(.rect(model.popover?.rect ?? .zero))) { popover in
            Group {
                switch popover.kind {
                case .value(let expr): ValuePopover(expr: expr)
                case .info(let markdown): InfoPopover(markdown: markdown, docs: popover.docs)
                }
            }
            .environment(model)
            .presentationCompactAdaptation(.popover)
        }
    }
}

private struct EmptyEditor: View {
    @Environment(AppModel.self) private var model
    @State private var naming = false
    @State private var name = "untitled.py"

    var body: some View {
        ContentUnavailableView {
            Label { Text("No File Open") } icon: { FileIcon(name: "x.py", size: 64) }
        } description: {
            Text("Pick a file or create a new one.")
        } actions: {
            Button("New File") { naming = true }.buttonStyle(.borderedProminent)
            if model.wide && !model.sidebarVisible {
                Button("Browse Files") { model.sidebarVisible = true }
            }
        }
        .background(Color(.systemBackground))
        .alert("New File", isPresented: $naming) {
            TextField("Name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                Task { if let path = await model.newFile(in: model.currentDir, name: name) { await model.openFile(path) } }
            }
        }
    }
}

/// Open files of one pane. Tap to switch, × to close, long-press for more.
struct TabStrip: View {
    let pane: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.panes.indices.contains(pane) ? model.panes[pane] : Pane()
        // The wide layouts' top row (D61): it starts with the files toggle and
        // ends at the workspace's corner with its actions.
        let row = model.wide && !model.verticalBar
        HStack(spacing: 0) {
            if row && pane == model.firstPane {
                // Clear of an iPad window's controls at the top left (windowed apps).
                SidebarToggle().padding(.leading, 6).containerCornerOffset(.leading, sizeToFit: true)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(p.tabs, id: \.self) { path in
                            tab(path, active: path == p.active).id(path)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .onChange(of: p.active) { _, active in withAnimation { proxy.scrollTo(active) } }
                .onAppear { if let active = p.active { proxy.scrollTo(active) } }
            }
            if model.wide {
                Button {
                    Task { await model.setSplit(!(model.split && pane == 1) && !model.split) }
                } label: {
                    Image(systemName: model.split && pane == 1 ? "xmark" : "rectangle.split.2x1")
                        .frame(width: 34, height: 34)
                }
                .foregroundStyle(.secondary)
                .opacity(model.split && pane == 0 ? 0 : 1)
                .accessibilityLabel(model.split ? "Close Split View" : "Split View")
            }
            if model.wide && pane == model.lastPane && !model.actionsAbovePanel && model.mainRole == .editor {
                WorkspaceActions().padding(.horizontal, 8)
            }
        }
        .clearOfTopCorners()
        .frame(height: row ? TopRowMetrics.height : 40)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tab(_ path: String, active: Bool) -> some View {
        let running = model.session.running && model.session.runningFile == path
        return HStack(spacing: 6) {
            if running { Circle().fill(.green).frame(width: 6, height: 6) }
            if isExternal(path) { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
            Text(tabLabel(path)).font(.subheadline).lineLimit(1)
            if active, model.problems[min(pane, 1)].total > 0 {
                // The count opens the problems (D61, D62).
                let counts = model.problems[min(pane, 1)]
                Button {
                    model.focusedPane = pane
                    model.showProblems()
                } label: {
                    Label("\(counts.total)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(counts.errors > 0 ? .red : .orange)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(counts.total == 1 ? "1 problem" : "\(counts.total) problems")
            }
            if active {
                // The title's place (D58, D61, D62): the active tab opens "Go to".
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            Button {
                Task { await model.closeTab(path, pane: pane) }
            } label: {
                Image(systemName: "xmark").font(.caption2.weight(.semibold)).frame(width: 18, height: 18)
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close \(tabLabel(path))")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background(active ? Color(.systemBackground) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            // The active tab, tapped again: go to a symbol or line.
            if active {
                model.focusedPane = pane
                model.goTo("")
            } else { Task { await model.selectTab(path, pane: pane) } }
        }
        .contextMenu {
            Button { Task { await model.closeTab(path, pane: pane) } } label: { Label("Close Tab", systemImage: "xmark") }
            Button { Task { await model.closeOtherTabs(path, pane: pane) } } label: { Label("Close Other Tabs", systemImage: "xmark.square") }
                .disabled(model.panes[pane].tabs.count < 2)
            if model.wide {
                Button {
                    Task { await model.openInOtherPane(path, from: pane) }
                } label: {
                    Label(model.panes.count > 1 ? (pane == 0 ? "Open on the Right" : "Open on the Left") : "Open in Split View",
                          systemImage: "rectangle.split.2x1")
                }
            }
        }
    }
}

/// The navigation bar where there is one (D61, D62): on iPhone (and a
/// closed iPhone Duo's vertical bar) Go to, Find and Problems, the agent, ⋯
/// and Run, with the active tab as the title; on an open iPhone Duo the
/// system's vertical bar with the files toggle, Jump to Definition, Show
/// Info, Settings, the debugger, ⋯ and Run
/// (D58). The other wide layouts have none: the top row has it all.
private struct EditorChrome: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let file = model.file
        let s = model.session
        content
            .toolbar(model.wide && !model.verticalBar ? .hidden : .automatic, for: .navigationBar)
            .toolbar {
                if !model.wide {
                    if model.verticalBar {
                        // A closed iPhone Duo: all in the vertical bar (D58).
                        TrailingButtons(vertical: true) {
                            navigatorButtons(file)
                            AgentButton()
                            MoreMenu()
                            RunButton()
                        }
                    } else {
                        // One item per side with the buttons close together: a
                        // group spaces them wider than an iPhone's bar can afford.
                        ToolbarItem(placement: .topBarLeading) { TightButtons { navigatorButtons(file) } }
                        TrailingButtons(vertical: false) {
                            AgentButton()
                            MoreMenu()
                            RunButton()
                        }
                    }
                } else if model.verticalBar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        SidebarToggle()
                        // Only plain buttons, each its own item: a styled
                        // button (PauseButton) or a stack of them (DebugBar)
                        // can't go into the vertical bar, and the system
                        // brings back a horizontal bar at the top for it.
                        if let debug = s.debug {
                            // The debugger's buttons take the lookups' place.
                            if debug.postMortem {
                                Button { model.resume("continue") } label: { Image(systemName: "checkmark") }
                                    .accessibilityLabel("Done")
                            } else {
                                Button { model.resume("next") } label: { Image(systemName: "arrow.turn.down.right") }
                                    .accessibilityLabel("Step Over")
                                Button { model.resume("stepIn") } label: { Image(systemName: "arrow.down.to.line") }
                                    .accessibilityLabel("Step Into")
                                Button { model.resume("stepOut") } label: { Image(systemName: "arrow.up.to.line") }
                                    .accessibilityLabel("Step Out")
                                Button { model.stop() } label: { Image(systemName: "stop.fill") }
                                    .tint(.red)
                                    .accessibilityLabel("Stop")
                            }
                        } else {
                            // The bar is tall: the code's lookups and Settings
                            // get their own buttons (they stay in ⋯ too).
                            let code = file.map { !isExternal($0) && !isMarkdown($0) } ?? false
                            Button { Task { _ = await model.goToDefinition() } } label: { Image(systemName: "arrow.forward.to.line") }
                                .accessibilityLabel("Jump to Definition")
                                .disabled(!code)
                            Button { Task { _ = await model.showInfo() } } label: { Image(systemName: "info.circle") }
                                .accessibilityLabel("Show Info")
                                .disabled(!code)
                            Button { model.activeSheet = .settings } label: { Image(systemName: "gearshape") }
                                .accessibilityLabel("Settings")
                            if s.status == "running" {
                                Button { model.pause() } label: { Image(systemName: "pause.fill") }
                                    .disabled(s.awaitingInput || s.pausing)
                                    .accessibilityLabel("Pause")
                            }
                        }
                        MoreMenu()
                        RunButton()
                    }
                }
            }
    }

    /// The navigator's panes as buttons (D62): what the wide layouts' sidebar
    /// has, as sheets. Find is the file's; a long press finds in the folder.
    @ViewBuilder
    private func navigatorButtons(_ file: String?) -> some View {
        let counts = model.problems[min(model.focused, 1)]
        Button { model.goTo("") } label: { Image(systemName: NavigatorPane.outline.symbol) }
            .accessibilityLabel("Go to")
            .disabled(file == nil)
        Menu {
            Button { model.findInFolder() } label: {
                Label("Find in \(file.map { displayName(dirname($0)) } ?? "Files")…", systemImage: "doc.text.magnifyingglass")
            }
        } label: {
            Image(systemName: NavigatorPane.find.symbol)
        } primaryAction: {
            model.find()
        }
        .accessibilityLabel("Find")
        .disabled(file == nil)
        Button { model.showProblems() } label: {
            Image(systemName: counts.total > 0 ? "exclamationmark.triangle.fill" : NavigatorPane.problems.symbol)
        }
        .tint(counts.errors > 0 ? .red : counts.total > 0 ? .orange : nil)
        .accessibilityLabel(counts.total == 0 ? "No problems" : counts.total == 1 ? "1 problem" : "\(counts.total) problems")
        .disabled(counts.total == 0)
    }
}

/// Toolbar buttons close together in one glass group, as one toolbar item:
/// a ToolbarItemGroup spaces them wider than an iPhone's bar can afford.
struct TightButtons<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            ForEach(subviews: content) { $0.frame(width: 40, height: 36) }
        }
        .padding(.horizontal, 2)
    }
}

/// Opens the coding agent for the current project; shows when one of its conversations is working.
struct AgentButton: View {
    var project: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.openAgent(project: project) } label: {
            let state = model.agent.state
            let working = state.busy || (state.conversations?.contains(where: \.running) ?? false)
            Image(systemName: working ? "sparkles.rectangle.stack.fill" : "sparkles")
                .symbolEffect(.pulse, isActive: working)
        }
        .accessibilityLabel("Agent")
    }
}

/// Run, Stop or Continue. On iPad a prominent button of its own; on iPhone
/// it sits in the same group as the agent and ⋯ buttons (a colored symbol),
/// which leaves the file name more room.
struct RunButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.session
        let file = model.file
        if let debug = s.debug, !debug.postMortem {
            styled(Button { model.resume("continue") } label: { symbol("play.fill", .green) }, .green)
                .accessibilityLabel("Continue")
        } else if (s.running && s.runningFile == file) || (s.running && file == nil) {
            styled(Button { model.stop() } label: { symbol("stop.fill", .red) }, .red)
                .accessibilityLabel("Stop")
        } else if let view = model.markdownView {
            // A Markdown file has nothing to run: here it switches between its preview and its source (D46).
            let previewing = view == "preview"
            styled(Button { model.toggleMarkdownView() } label: { symbol(previewing ? "pencil" : "eye", .accentColor) }, .accentColor)
                .accessibilityLabel(previewing ? "Edit Markdown" : "Show Preview")
        } else {
            let disabled = file == nil || s.running || file.map(isExternal) == true
            styled(Button { Task { await model.run() } } label: { symbol("play.fill", disabled ? .secondary : .accentColor) }, .accentColor)
                .disabled(disabled)
                .accessibilityLabel("Run")
        }
    }

    private func symbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).foregroundStyle(model.wide ? AnyShapeStyle(.white) : AnyShapeStyle(color))
    }

    @ViewBuilder
    private func styled(_ button: some View, _ tint: Color) -> some View {
        if model.wide {
            button.buttonStyle(.borderedProminent).tint(tint)
        } else {
            button
        }
    }
}
