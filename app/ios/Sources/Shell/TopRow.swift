import SwiftUI

// The wide layouts' top row (D61): no navigation bar, one row of about 40 pt
// with the files toggle, the tabs, the split button, the other half's icons,
// ⋯ and Run. On an open iPhone Duo the system's vertical bar keeps ⋯, Run,
// the files toggle, Jump to Definition, Show Info and Settings (D58); the
// row has the rest.

/// What the sidebar shows (D61).
enum NavigatorPane: String, CaseIterable, Identifiable {
    case files, outline, find, problems
    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: "Files"
        case .outline: "Outline"
        case .find: "Find"
        case .problems: "Problems"
        }
    }

    var symbol: String {
        switch self {
        case .files: "folder"
        case .outline: "list.bullet.indent"
        case .find: "magnifyingglass"
        case .problems: "exclamationmark.triangle"
        }
    }
}

extension AppModel {
    /// The sidebar on one of its panes (wide), else the matching sheet.
    func showNavigator(_ pane: NavigatorPane) {
        navigator = pane
        withAnimation { sidebarVisible = true }
    }

    /// Go to a symbol or a line (":"): the outline in the sidebar, or the sheet on iPhone.
    func goTo(_ query: String) {
        guard wide else { activeSheet = .jump(query); return }
        outlineQuery = query
        outlineFocus += 1
        showNavigator(.outline)
    }

    func findInFolder() {
        if wide { showNavigator(.find) } else { activeSheet = .find }
    }

    func showProblems() {
        if wide { showNavigator(.problems) } else { activeSheet = .problems }
    }

    /// A pick in the sidebar's outline, find or problems: when the sidebar is
    /// over the editor it goes, so the editor shows where it went.
    func navigatorPicked() {
        if sidebarOverlaps || sidebarSlidesOver { withAnimation { sidebarVisible = false } }
    }

    /// The other half on `role`, shown.
    func showHalf(_ role: PanelRole) {
        uncoverHalves()
        withAnimation(.smooth(duration: 0.25)) {
            setPanelRole(role)
            consoleDocked = true
        }
    }

    /// A sidebar that slides over goes when the halves are asked for (the
    /// agent, the docs, a half's icon): it covers them, and while it is up
    /// their overlays are hidden (HalfOverlays).
    func uncoverHalves() {
        if sidebarSlidesOver && sidebarVisible { withAnimation { sidebarVisible = false } }
    }

    /// The half's icon: shows the half on it, or hides the half if it shows it already.
    func toggleHalf(_ role: PanelRole) {
        if panelShown && panelRole == role {
            withAnimation(.smooth(duration: 0.25)) { consoleDocked = false }
        } else {
            showHalf(role)
        }
    }

    /// One of the agent's conversations is working (its icon pulses).
    var agentWorking: Bool {
        let state = agent.state
        return state.busy || (state.conversations?.contains(where: \.running) ?? false)
    }

    /// Where the workspace's actions go: above the other half when it is on
    /// the right, else at the end of the last pane's row (D61). Either way the
    /// top-right corner.
    var actionsAbovePanel: Bool { panelShown && panelSideBySide && !panelFirst }

    /// The sidebar slides over the workspace instead of pushing it (D61):
    /// files, an editor of about 60 columns and the other half next to it
    /// don't fit side by side. Never three columns squeezed. On a phone (an
    /// open iPhone Duo, a Pro Max in landscape) it always slides over: one
    /// way, not one that changes with the rotation, the other half or the
    /// font size.
    var sidebarSlidesOver: Bool {
        guard wide else { return false }
        if UIDevice.current.userInterfaceIdiom == .phone { return true }
        let sidebar: CGFloat = 320
        let editor = CGFloat(settings.fontSize) * 0.6 * 60 + 48
        var half: CGFloat = 0
        if panelShown && panelSideBySide {
            let rest = windowWidth - sidebar
            half = panelRatio.map { rest * $0 } ?? max(320, rest * 0.38)
        }
        return sidebar + editor + half > windowWidth
    }

    /// The sidebar's width when it slides over.
    var slideOverWidth: CGFloat { min(340, windowWidth * 0.8) }

    /// The sidebar is sliding over and covers this part of the window
    /// (global coordinates). A half past it (the open Duo's other screen)
    /// stays as it is: shown, not dimmed, and its taps are its own.
    func sidebarCovers(_ rect: CGRect) -> Bool {
        sidebarSlidesOver && sidebarVisible && rect.minX < slideOverWidth
    }

    /// Where the slid-over sidebar's dimming ends: at the other half when
    /// that is beside the code and clear of the sidebar, else at the
    /// window's edge.
    var slideOverDimEnd: CGFloat {
        if panelShown, panelSideBySide, let rect = panelSlot?.rect, rect.minX >= slideOverWidth { return rect.minX }
        return windowWidth
    }

    /// The first pane on screen (its row starts with the files toggle).
    var firstPane: Int { split ? 0 : focused }
    /// The last pane on screen (its row may end with the actions).
    var lastPane: Int { split ? 1 : focused }
}

/// Shows and hides the sidebar.
struct SidebarToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { withAnimation { model.sidebarVisible.toggle() } } label: {
            Image(systemName: "sidebar.left").frame(width: 34, height: 34)
        }
        .accessibilityLabel(model.sidebarVisible ? "Hide Files" : "Show Files")
    }
}

/// The other half's icons (D61): the one it shows is filled; a tap on another
/// shows it there, a tap on the shown one hides the half. The agent's pulses
/// while it works. Touch and hold for where the half goes.
struct HalfPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelRole.allCases) { role in
                let shown = model.panelShown && model.panelRole == role
                Button { model.toggleHalf(role) } label: {
                    Image(systemName: role == .agent && model.agentWorking ? "sparkles.rectangle.stack.fill" : role.symbol)
                        .symbolEffect(.pulse, isActive: role == .agent && model.agentWorking)
                        .font(.system(size: 15, weight: shown ? .semibold : .regular))
                        .foregroundStyle(shown ? Color.accentColor : Color.secondary)
                        .frame(width: 36, height: 30)
                        .background(shown ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(role.title)
                .accessibilityValue(shown ? "shown" : "")
                .accessibilityAddTraits(shown ? .isSelected : [])
                .accessibilityHint(shown ? "Hides the \(role.title.lowercased())" : "Shows the \(role.title.lowercased()) next to the code")
            }
        }
        .padding(2)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .contextMenu { LayoutItems() }
    }
}

/// Where the other half goes, and the app between the halves: the half's
/// icons' long press and ⋯'s Layout section.
struct LayoutItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let side = model.panelSideBySide
        Section("Layout") {
            Button { withAnimation { model.setPanelFirst(!model.panelFirst) } } label: {
                Label(side ? (model.panelFirst ? "Move to the Right" : "Move to the Left") : (model.panelFirst ? "Move to the Bottom" : "Move to the Top"),
                      systemImage: side ? (model.panelFirst ? "rectangle.righthalf.inset.filled" : "rectangle.lefthalf.inset.filled")
                                        : (model.panelFirst ? "rectangle.bottomhalf.inset.filled" : "rectangle.tophalf.inset.filled"))
            }
            if model.panelRole == .app || model.mainRole == .app {
                Button { withAnimation { model.swapAppHalf() } } label: {
                    Label(model.mainRole == .app ? "Show the Code in the Main Half" : "Show the App in the Main Half", systemImage: "rectangle.2.swap")
                }
            }
            if model.ui.visible && model.appInHalf {
                Button { model.setAppFullScreen(true) } label: { Label("Show the App Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
            }
            if model.panelRatio != nil {
                Button { withAnimation { model.setPanelRatio(nil) } } label: { Label("Reset the Divider", systemImage: "arrow.left.and.right") }
            }
        }
    }
}

/// The workspace's buttons at its top-right corner: the half's icons, the
/// debugger's, Pause, ⋯ and Run (with a vertical bar, ⋯ and Run are there).
struct WorkspaceActions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.session
        HStack(spacing: 8) {
            HalfPicker()
            if !model.verticalBar {
                if let debug = s.debug { DebugBar(debug: debug) }
                if s.status == "running", s.debug == nil { PauseButton() }
                MoreMenu().frame(width: 34, height: 34)
                RunButton().controlSize(.small)
            }
        }
    }
}

/// ⋯: go to, find, format, the file's Python, layout, settings, the file itself.
struct MoreMenu: View {
    @Environment(AppModel.self) private var model
    @State private var renaming = false
    @State private var newName = ""
    @State private var deleting = false

    var body: some View {
        let file = model.file
        menu(file, external: file.map(isExternal) ?? false)
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
                Button { model.goTo("") } label: { Label("Go to…", systemImage: "list.bullet") }
                Button { Task { _ = await model.goToDefinition() } } label: { Label("Jump to Definition", systemImage: "arrow.forward.to.line") }
                    .disabled(external || markdown)
                Button { Task { _ = await model.showInfo() } } label: { Label("Show Info", systemImage: "info.circle") }
                    .disabled(external || markdown)
                Button { model.showDocs() } label: { Label("Python Docs", systemImage: "book") }
            }
            Section {
                Button { model.find() } label: { Label("Find", systemImage: "magnifyingglass") }
                Button { model.findInFolder() } label: {
                    Label("Find in \(file.map { displayName(dirname($0)) } ?? "Files")…", systemImage: "doc.text.magnifyingglass")
                }
                Button { Task { await model.format() } } label: { Label("Format Code", systemImage: "wand.and.stars") }
                    .disabled(external || markdown || model.notebook?.view == "source")
                Button { model.showProblems() } label: { Label("Show Problems", systemImage: "exclamationmark.triangle") }
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
            if model.wide { LayoutItems() }
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
        // Wide, its layout and settings don't need a file.
        .disabled(file == nil && !model.wide)
    }
}

enum TopRowMetrics {
    /// The top row's height (wide layouts without a vertical bar); the tab strip's is 40 otherwise.
    static let height: CGFloat = 44
}
