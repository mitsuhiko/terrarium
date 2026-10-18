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
            VStack(spacing: 0) {
                if model.panes[0].tabs.count > 1 { TabStrip(pane: 0) }
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
            .background(model.editorBackground.ignoresSafeArea())
        }
        .background(model.editorBackground.ignoresSafeArea())
        .modifier(EditorChrome())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

/// iPad: one or two panes and the docked console (right in landscape, below otherwise).
struct WorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height * 1.2 && !model.split
            let layout = landscape ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                editors(width: geo.size.width)
                if model.consoleDocked {
                    Divider()
                    ConsoleView(showHeader: true)
                        .frame(width: landscape ? max(320, geo.size.width * 0.38) : nil, height: landscape ? nil : geo.size.height * 0.36)
                }
            }
        }
        .modifier(EditorChrome())
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func editors(width: CGFloat) -> some View {
        if model.split {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    PaneColumn(pane: 0).frame(width: geo.size.width * model.splitRatio)
                    SplitDivider(width: geo.size.width)
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
    @Environment(AppModel.self) private var model
    @State private var start: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(width: 1)
            .overlay(Color.clear.frame(width: 16).contentShape(Rectangle()))
            .gesture(DragGesture(coordinateSpace: .global).onChanged { g in
                let base = start ?? model.splitRatio
                if start == nil { start = base }
                model.splitRatio = min(0.75, max(0.25, base + g.translation.width / max(1, width)))
            }.onEnded { _ in start = nil })
            .onTapGesture(count: 2) { model.splitRatio = 0.5 }
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
            if empty { EmptyEditor() }
        }
        // The page is transparent: while it resizes (the keyboard comes up) the
        // part it hasn't drawn yet shows this.
        .background(model.editorBackground)
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
        HStack(spacing: 0) {
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
        }
        .frame(height: 40)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tab(_ path: String, active: Bool) -> some View {
        let running = model.session.running && model.session.runningFile == path
        return HStack(spacing: 6) {
            if running { Circle().fill(.green).frame(width: 6, height: 6) }
            if isExternal(path) { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
            Text(tabLabel(path)).font(.subheadline).lineLimit(1)
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
        .onTapGesture { Task { await model.selectTab(path, pane: pane) } }
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

/// The navigation bar: file name (opens "Go to"), status, the ⋯ menu, Run.
private struct EditorChrome: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var renaming = false
    @State private var newName = ""
    @State private var deleting = false

    func body(content: Content) -> some View {
        let file = model.file
        let external = file.map(isExternal) ?? false
        let debug = model.session.debug
        content
            .toolbar {
                ToolbarItem(placement: .principal) { title(file) }
                if model.wide {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if let debug {
                            DebugBar(debug: debug)
                        }
                        Button { withAnimation { model.consoleDocked.toggle() } } label: { Image(systemName: "terminal") }
                            .accessibilityLabel("Toggle console")
                        AgentButton()
                        menu(file, external: external)
                        RunButton()
                    }
                } else {
                    // One item with the buttons close together: a group spaces
                    // them wider than the title can afford on iPhone.
                    ToolbarItem(placement: .topBarTrailing) {
                        TightButtons {
                            AgentButton()
                            menu(file, external: external)
                            RunButton()
                        }
                    }
                }
            }
            .alert("Rename “\(file.map(basename) ?? "")”", isPresented: $renaming) {
                TextField("Name", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    if let file, !newName.isEmpty, newName != basename(file), !newName.contains("/") {
                        Task { _ = await model.rename(file, to: newName) }
                    }
                }
            }
            .confirmationDialog("Delete “\(file.map(basename) ?? "")”?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let file { Task { await model.delete(file) } } }
            } message: {
                Text(file?.hasPrefix("@") == true ? "It goes to the folder's trash if it has one, otherwise it is gone." : "It goes to the Trash in the file browser.")
            }
    }

    /// Room for the title on iPhone: between the back button and the group of
    /// buttons on the right (about 228 pt together).
    private var titleWidth: CGFloat {
        model.wide ? min(420, model.windowWidth * 0.4) : max(90, model.windowWidth - 228)
    }

    /// The file name, cut in the middle when it doesn't fit. Toolbar buttons
    /// keep their label's ideal size (it would run under the other buttons),
    /// so the text gets an exact width: its own, or what is left.
    /// The title leaves out ".py": nearly every file is one, and the room is short.
    private func titleLabel(_ path: String) -> String {
        let name = tabLabel(path)
        return name.hasSuffix(".py") && name.count > 3 ? String(name.dropLast(3)) : name
    }

    private func fileName(_ name: String) -> some View {
        CappedWidth(limit: titleWidth - 16) {
            Text(name).font(.headline).lineLimit(1).truncationMode(.middle)
        }
    }

    private func title(_ file: String?) -> some View {
        VStack(spacing: 0) {
            if let file {
                Button { model.activeSheet = .jump("") } label: {
                    HStack(spacing: 3) {
                        fileName(titleLabel(file))
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
                .accessibilityLabel("\(tabLabel(file)): go to a symbol or line")
            } else {
                Text("Terrarium").font(.headline)
            }
            subtitle(file).lineLimit(1)
        }
    }

    @ViewBuilder
    private func subtitle(_ file: String?) -> some View {
        let s = model.session
        let counts = model.problems[min(model.focused, 1)]
        if let debug = s.debug, let frame = debug.frames.first {
            Text(debug.postMortem ? "Error in \(frame.label)" : "Paused · line \(frame.line)")
                .font(.caption).foregroundStyle(debug.postMortem ? .red : .green)
        } else if let kernel = s.kernel, kernel.path == file, s.running {
            // A notebook's cell (D44).
            Text(kernel.cell.map { "Running cell [\($0)]…" } ?? "Starting Python…").font(.caption).foregroundStyle(.green)
        } else if s.running && s.runningFile == file, let run = s.lastRun {
            Text(run.summary(awaitingInput: s.awaitingInput)).font(.caption).foregroundStyle(.green)
        } else if let file, isExternal(file) {
            Text("Read only").font(.caption).foregroundStyle(.secondary)
        } else if counts.total > 0 {
            Button { model.activeSheet = .problems } label: {
                Label(counts.total == 1 ? "1 problem" : "\(counts.total) problems", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
            }
            .tint(counts.errors > 0 ? .red : .orange)
        } else if let kernel = s.kernel, kernel.path == file, !kernel.python.isEmpty {
            Text("Python \(kernel.python) kernel").font(.caption).foregroundStyle(.secondary)
        } else if model.wide, let file, !dirname(file).isEmpty {
            Text(displayName(dirname(file))).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Which Python the file runs on; picking one pins its folder (`.python-version`, D37).
    private func pythonMenu(_ file: String) -> some View {
        let current = model.filePython
        let title = current.map { "Python \($0.version)" } ?? "Python \(model.defaultPython)"
        return Menu {
            Picker("Python for “\(displayName(dirname(file)))”", selection: Binding(
                get: { model.folderPin ?? "" },
                set: { value in Task { await model.setFolderPython(value.isEmpty ? nil : value) } }
            )) {
                Text("Default (Python \(model.defaultPython))").tag("")
                ForEach(Runtimes.all, id: \.python) { Text($0.label).tag($0.python) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(title, systemImage: "chevron.left.forwardslash.chevron.right")
            if let current, current.reason != "default" {
                Text("from \(current.reason)")
            }
        }
    }

    /// Cells and the kernel (D44).
    @ViewBuilder
    private func notebookSection(_ notebook: NotebookPane, _ file: String) -> some View {
        let ipynb = file.hasSuffix(".ipynb")
        Section {
            if notebook.view != "source" {
                Button { model.notebookCommand("runCell") } label: { Label("Run Cell", systemImage: "play") }
                Button { model.notebookCommand("runAll") } label: { Label("Run All Cells", systemImage: "forward") }
                Menu {
                    Button { model.notebookCommand("runAbove") } label: { Label("Run Cells Above", systemImage: "arrow.up.to.line") }
                    Button { model.notebookCommand("runBelow") } label: { Label("Run Cell and Below", systemImage: "arrow.down.to.line") }
                    Divider()
                    Button { model.notebookCommand("insertCode") } label: { Label("Insert Code Cell", systemImage: "plus.rectangle") }
                    Button { model.notebookCommand("insertMarkdown") } label: { Label("Insert Markdown Cell", systemImage: "text.badge.plus") }
                    if ipynb {
                        Button { model.notebookCommand("moveUp") } label: { Label("Move Cell Up", systemImage: "arrow.up") }
                        Button { model.notebookCommand("moveDown") } label: { Label("Move Cell Down", systemImage: "arrow.down") }
                        Button(role: .destructive) { model.notebookCommand("deleteCell") } label: { Label("Delete Cell", systemImage: "trash") }
                    }
                    Divider()
                    Button { model.notebookCommand("clearOutputs") } label: { Label("Clear All Outputs", systemImage: "xmark.circle") }
                } label: {
                    Label("Cells", systemImage: "square.split.1x2")
                }
            }
            Button { model.restartKernel() } label: { Label("Restart Kernel", systemImage: "arrow.clockwise") }
                .disabled(model.session.kernel?.path != file)
            if ipynb {
                Button { model.notebookCommand("toggleView") } label: {
                    notebook.view == "source"
                        ? Label("Show as Notebook", systemImage: "book.pages")
                        : Label("Show JSON Source", systemImage: "curlybraces")
                }
            }
        }
    }

    private func menu(_ file: String?, external: Bool) -> some View {
        let bps = file.map { model.breakpoints[$0]?.count ?? 0 } ?? 0
        let markdown = file.map(isMarkdown) ?? false
        return Menu {
            Section {
                Button { model.activeSheet = .jump("") } label: { Label("Go to…", systemImage: "list.bullet") }
                Button { Task { _ = await model.goToDefinition() } } label: { Label("Jump to Definition", systemImage: "arrow.forward.to.line") }
                    .disabled(external || markdown)
                Button { Task { _ = await model.showInfo() } } label: { Label("Show Info", systemImage: "info.circle") }
                    .disabled(external || markdown)
                Button { model.showDocs() } label: { Label("Python Docs", systemImage: "book") }
            }
            Section {
                Button { model.find() } label: { Label("Find", systemImage: "magnifyingglass") }
                Button { model.activeSheet = .find } label: {
                    Label("Find in \(file.map { displayName(dirname($0)) } ?? "Files")…", systemImage: "doc.text.magnifyingglass")
                }
                Button { Task { await model.format() } } label: { Label("Format Code", systemImage: "wand.and.stars") }
                    .disabled(external || markdown || model.notebook?.view == "source")
                Button { model.activeSheet = .problems } label: { Label("Show Problems", systemImage: "exclamationmark.triangle") }
                    .disabled(model.problems[min(model.focused, 1)].total == 0)
            }
            if let notebook = model.notebook, let file {
                notebookSection(notebook, file)
            }
            if let view = model.markdownView {
                Section {
                    Button { model.toggleMarkdownView() } label: {
                        view == "preview"
                            ? Label("Edit Markdown", systemImage: "pencil")
                            : Label("Show Preview", systemImage: "eye")
                    }
                }
            }
            if bps > 0, let file {
                Section {
                    Button { model.clearBreakpoints(file) } label: {
                        Label(bps == 1 ? "Remove Breakpoint" : "Remove \(bps) Breakpoints", systemImage: "arrowshape.right")
                    }
                }
            }
            if let file, !external, !markdown {
                Section {
                    pythonMenu(file)
                }
            }
            Section {
                if model.wide {
                    Button { Task { await model.setSplit(!model.split) } } label: {
                        Label(model.split ? "Close Split View" : "Split View", systemImage: "rectangle.split.2x1")
                    }
                }
                Button { model.activeSheet = .settings } label: { Label("Settings…", systemImage: "gearshape") }
            }
            if let file {
                if external {
                    Button { Task { await model.closeTab(file) } } label: { Label("Close Tab", systemImage: "xmark") }
                } else {
                    Section {
                        Button {
                            newName = basename(file)
                            renaming = true
                        } label: { Label("Rename…", systemImage: "pencil") }
                        Button {
                            Task {
                                if let copy = await model.duplicate(file) {
                                    await model.openFile(copy)
                                    model.showToast("Duplicated as “\(basename(copy))”")
                                }
                            }
                        } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        Button { model.activeSheet = .move(file) } label: { Label("Move…", systemImage: "folder") }
                        Button { model.share(file) } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                        if file.hasSuffix(".py") {
                            Button { model.activeSheet = .homeScreen(file) } label: { Label("Add to Home Screen…", systemImage: "apps.iphone.badge.plus") }
                        }
                    }
                    Section {
                        Button(role: .destructive) { deleting = true } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
        .disabled(file == nil)
    }
}

/// Gives its one subview its ideal width, but no more than `limit`, whatever
/// it is offered. Measures the text as it is drawn: in a navigation bar
/// Dynamic Type is capped, so a `UIFont.preferredFont` estimate is too wide.
private struct CappedWidth: Layout {
    var limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let ideal = view.sizeThatFits(.unspecified)
        if ideal.width <= limit { return CGSize(width: ceil(ideal.width), height: ideal.height) }
        // Cut text can be narrower than the room it was given.
        let cut = view.sizeThatFits(ProposedViewSize(width: limit, height: nil))
        return CGSize(width: min(ceil(cut.width), limit), height: cut.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
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
