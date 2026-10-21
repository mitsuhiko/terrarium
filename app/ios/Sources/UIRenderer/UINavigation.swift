import SwiftUI

// The app's frame: the root, screens (a grouped List with a navigation bar),
// navigation stacks, tabs, sheets, dialogs and toasts.

/// A running ui app, full screen or in a half of the wide workspace (D59).
struct UIAppRoot: View {
    let store: UIStore
    var inHalf = false

    var body: some View {
        RootContent(root: store.root)
            .modifier(LayerHost(level: 0))
            .environment(store)
            .environment(\.uiAppRoot, true)
            .environment(\.uiInHalf, inHalf)
            .tint(UIColorParser.color(store.tint))
            .preferredColorScheme(store.theme == "dark" ? .dark : store.theme == "light" ? .light : nil)
            .background {
                // Without the close button, two fingers swiping down close the app.
                if !store.closeButton {
                    TwoFingerSwipeDown { store.close() }.allowsHitTesting(false)
                }
            }
    }
}

/// The app's close button on its first screen: a tap ends the program,
/// touch and hold offers Restart.
private struct CloseAppButton: View {
    @Environment(UIStore.self) private var store

    var body: some View {
        Menu {
            Button("Restart", systemImage: "arrow.clockwise") { store.restart() }
        } label: {
            Label("Close", systemImage: "xmark")
        } primaryAction: {
            store.close()
        }
        .labelStyle(.iconOnly)
        .accessibilityHint("Touch and hold to restart")
    }
}

/// A two-finger swipe down anywhere in the window. The recognizer sits on the
/// window, next to the views' own gestures, so it works over lists and canvases.
private struct TwoFingerSwipeDown: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.action = action
        return view
    }

    func updateUIView(_ view: Probe, context: Context) {
        view.action = action
    }

    static func dismantleUIView(_ view: Probe, coordinator: ()) {
        view.detach()
    }

    final class Probe: UIView, UIGestureRecognizerDelegate {
        var action: () -> Void = {}
        private var recognizer: UISwipeGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard let window else { return }
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped))
            swipe.direction = .down
            swipe.numberOfTouchesRequired = 2
            swipe.cancelsTouchesInView = false
            swipe.delegate = self
            window.addGestureRecognizer(swipe)
            recognizer = swipe
        }

        func detach() {
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            recognizer = nil
        }

        @objc private func swiped() { action() }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

private struct RootContent: View {
    let root: UINode

    var body: some View {
        let kids = root.children.filter { !$0.bool("hidden") }
        if kids.count == 1, let only = kids.first, only.type == "NavigationStack" || only.type == "TabView" {
            NodeView(node: only)
        } else if kids.count == 1, let only = kids.first, only.type == "Screen" {
            NavigationStack { ScreenView(node: only) }
        } else {
            NavigationStack { ScreenContent(nodes: root.children).modifier(ScreenChrome(title: nil, large: false, toolbars: [])) }
        }
    }
}

// MARK: screens

/// A screen: its content as a grouped list, its title and toolbar.
struct ScreenView: View {
    let node: UINode

    var body: some View {
        let toolbars = node.children.filter { $0.type == "Toolbar" }
        ScreenContent(nodes: node.children.filter { $0.type != "Toolbar" })
            .modifier(ScreenChrome(title: node.string("title"), large: node.props["large"]?.truthy ?? true, toolbars: toolbars))
    }
}

/// Title, toolbar items and the app's close button.
struct ScreenChrome: ViewModifier {
    let title: String?
    let large: Bool
    let toolbars: [UINode]
    @Environment(\.uiAppRoot) private var appRoot
    @Environment(\.uiInHalf) private var inHalf
    @Environment(UIStore.self) private var store

    func body(content: Content) -> some View {
        let leading = toolbars.filter { $0.string("placement") == "leading" }
        let trailing = toolbars.filter { $0.string("placement") != "leading" }
        content
            .navigationTitle(title ?? "")
            .navigationBarTitleDisplayMode(large && !(title ?? "").isEmpty ? .large : .inline)
            .toolbar {
                if appRoot && store.closeButton {
                    ToolbarItem(placement: .topBarLeading) { CloseAppButton() }
                        .horizontalOnly(inHalf)
                    if !leading.isEmpty { ToolbarSpacer(.fixed, placement: .topBarLeading) }
                }
                if !leading.isEmpty {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        ForEach(leading) { Children(node: $0).environment(\.uiContext, .toolbar) }
                    }
                    .horizontalOnly(inHalf)
                }
                if !trailing.isEmpty {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        ForEach(trailing) { Children(node: $0).environment(\.uiContext, .toolbar) }
                    }
                    .horizontalOnly(inHalf)
                }
            }
            .environment(\.uiAppRoot, false)
    }
}

/// A screen's children in an inset grouped list: Sections become list
/// sections, Rows list rows, anything else a row of its own on the background.
struct ScreenContent: View {
    let nodes: [UINode]

    var body: some View {
        List {
            ForEach(nodes) { child in
                ScreenRow(node: child)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .environment(\.uiContext, .plain)
    }
}

private struct ScreenRow: View {
    let node: UINode

    var body: some View {
        switch node.type {
        case "Section":
            if !node.bool("hidden") {
                ListSection(node: node)
            }
        case "Sheet", "Toolbar":
            EmptyView()
        case "Row":
            NodeView(node: node)
                .environment(\.uiContext, .list)
                .environment(\.uiStretch, true)
                .environment(\.uiAxis, .vertical)
        default:
            NodeView(node: node)
                .environment(\.uiStretch, true)
                .environment(\.uiAxis, .vertical)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }
}

private struct ListSection: View {
    let node: UINode

    var body: some View {
        let header = node.string("header").flatMap { $0.isEmpty ? nil : $0 }
        let footer = node.string("footer").flatMap { $0.isEmpty ? nil : $0 }
        Section {
            ForEach(node.children) { child in
                NodeView(node: child)
                    .environment(\.uiContext, .list)
                    .environment(\.uiStretch, true)
                    .environment(\.uiAxis, .vertical)
            }
        } header: {
            if let header { Text(header) }
        } footer: {
            if let footer { Text(footer) }
        }
    }
}

// MARK: navigation

struct NavStackNode: View {
    let node: UINode
    @Environment(UIStore.self) private var store
    @Environment(\.uiAppRoot) private var appRoot

    var body: some View {
        let screens = node.children
        let path = screens.dropFirst().map(\.id).filter { !node.poppedLocally.contains($0) }
        NavigationStack(path: Binding(get: { path }, set: { popTo($0, from: path) })) {
            Group {
                if let root = screens.first {
                    ScreenView(node: root)
                }
            }
            .environment(\.uiAppRoot, appRoot)
            .navigationDestination(for: Int.self) { id in
                if let screen = store.node(id) {
                    ScreenView(node: screen).environment(\.uiAppRoot, false)
                }
            }
        }
    }

    /// The user went back (button, edge swipe, long-press menu): hide the
    /// screens right away and tell Python, which pops them for real.
    private func popTo(_ newPath: [Int], from old: [Int]) {
        guard newPath.count < old.count, Array(old.prefix(newPath.count)) == newPath else { return }
        for id in old[newPath.count...].reversed() {
            node.poppedLocally.insert(id)
            if let screen = store.node(id) { store.emit(screen, "back") }
        }
    }
}

struct TabViewNode: View {
    let node: UINode
    @Environment(UIStore.self) private var store

    var body: some View {
        let selected = node.props["selected"]?.int ?? 0
        TabView(selection: Binding(get: { selected }, set: { store.emitValue(node, "selected", .number(Double($0))) })) {
            ForEach(Array(node.children.enumerated()), id: \.element.id) { i, tab in
                TabContent(tab: tab)
                    .tabItem {
                        Label {
                            Text(tab.string("title") ?? "")
                        } icon: {
                            Image(systemName: UIIcons.symbol(tab.string("icon")) ?? "circle")
                        }
                    }
                    .badge(tab.string("badge").flatMap { $0.isEmpty ? nil : Text($0) })
                    .tag(i)
            }
        }
    }
}

private struct TabContent: View {
    let tab: UINode

    var body: some View {
        let kids = tab.children.filter { !$0.bool("hidden") }
        if kids.count == 1, let only = kids.first, only.type == "NavigationStack" {
            NodeView(node: only)
        } else if kids.count == 1, let only = kids.first, only.type == "Screen" {
            NavigationStack { ScreenView(node: only) }
        } else {
            NavigationStack {
                ScreenContent(nodes: tab.children).modifier(ScreenChrome(title: nil, large: false, toolbars: []))
            }
        }
    }
}

// MARK: sheets, dialogs, toasts

/// Presents what belongs on top of one layer (the app, or a sheet): the next
/// open sheet, and dialogs and toasts when this is the topmost layer.
struct LayerHost: ViewModifier {
    let level: Int
    @Environment(UIStore.self) private var store

    func body(content: Content) -> some View {
        let sheets = store.openSheets
        let sheet = sheets.count > level ? sheets[level] : nil
        let top = sheets.count == level
        content
            .sheet(item: Binding(get: { sheet }, set: { value in
                if value == nil, let sheet, sheet.bool("open") { store.sheetDismissed(sheet) }
            })) { node in
                SheetView(node: node)
                    .modifier(LayerHost(level: level + 1))
                    .environment(store)
                    .tint(UIColorParser.color(store.tint))
            }
            .modifier(DialogHost(dialog: top ? store.dialogs.first : nil))
            .overlay(alignment: .top) {
                if top { ToastHost() }
            }
    }
}

struct SheetView: View {
    let node: UINode
    @Environment(UIStore.self) private var store

    var body: some View {
        NavigationStack {
            ScreenContent(nodes: node.children)
                .navigationTitle(node.string("title") ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { store.sheetDismissed(node) }
                    }
                }
        }
        .presentationDetents(node.string("size") == "medium" ? [.medium, .large] : [.large])
    }
}

private struct DialogHost: ViewModifier {
    let dialog: UIDialog?
    @Environment(UIStore.self) private var store
    @State private var text = ""

    func body(content: Content) -> some View {
        let spec = dialog?.spec ?? [:]
        let title = spec["title"]?.string ?? ""
        let message = spec["message"]?.string
        let isAlert = dialog.map { $0.kind != "choose" } ?? false
        let isChoice = dialog?.kind == "choose"
        content
            .alert(title, isPresented: Binding(get: { isAlert }, set: { if !$0 { cancel() } }), presenting: dialog) { d in
                switch d.kind {
                case "prompt":
                    TextField(d.spec["placeholder"]?.string ?? "", text: $text)
                        .textInputAutocapitalization(.sentences)
                    Button(d.spec["cancel"]?.string ?? "Cancel", role: .cancel) { store.replyDialog(d, nil) }
                    Button(d.spec["ok"]?.string ?? "OK") { store.replyDialog(d, text) }
                case "confirm":
                    Button(d.spec["cancel"]?.string ?? "Cancel", role: .cancel) { store.replyDialog(d, false) }
                    Button(d.spec["ok"]?.string ?? "OK", role: d.spec["destructive"]?.truthy == true ? .destructive : nil) {
                        store.replyDialog(d, true)
                    }
                default:
                    Button(d.spec["ok"]?.string ?? "OK") { store.replyDialog(d, nil) }
                }
            } message: { _ in
                if let message { Text(message) }
            }
            .confirmationDialog(title, isPresented: Binding(get: { isChoice }, set: { if !$0 { cancel() } }),
                                titleVisibility: title.isEmpty ? .hidden : .visible, presenting: dialog) { d in
                let options = d.spec["options"]?.array?.compactMap(\.string) ?? []
                ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                    Button(option) { store.replyDialog(d, i) }
                }
                Button(d.spec["cancel"]?.string ?? "Cancel", role: .cancel) { store.replyDialog(d, nil) }
            } message: { _ in
                if let message { Text(message) }
            }
            .onChange(of: dialog?.id, initial: true) {
                text = dialog?.spec["value"]?.string ?? ""
            }
    }

    /// Dismissed without a button (e.g. tapping outside an action sheet).
    private func cancel() {
        guard let dialog else { return }
        store.replyDialog(dialog, dialog.kind == "confirm" ? false : nil)
    }
}

private struct ToastHost: View {
    @Environment(UIStore.self) private var store

    var body: some View {
        VStack(spacing: 8) {
            ForEach(store.toasts) { toast in
                Text(toast.text)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 8)
        .animation(.spring(duration: 0.35), value: store.toasts)
        .allowsHitTesting(false)
    }
}
