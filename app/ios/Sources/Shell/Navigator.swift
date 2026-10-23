import SwiftUI

// The wide layouts' sidebar is a navigator (D61): the files, the open file's
// outline, find in folder and the problems, picked in a row at its top. On
// iPhone (no sidebar) Go to, Find and Problems stay sheets.

struct NavigatorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            NavigatorPicker()
            switch model.navigator {
            case .files:
                SidebarFiles()
            case .outline:
                OutlinePane()
            case .find:
                FindView(embedded: true)
            case .problems:
                ProblemsView(embedded: true)
            }
        }
        .background(Color(.systemGroupedBackground))
    }
}

extension EnvironmentValues {
    /// In the wide layout's sidebar: the files draw their own header (SidebarFiles).
    @Entry var inSidebar = false
}

/// The sidebar's files: the top of `model.route`, with a header of its own,
/// not in a NavigationStack. A navigation controller in the sidebar laid its
/// content out for the window's vertical bar on an iPhone Duo (D58): it
/// added the bar's inset (84 pt) at the sidebar's trailing edge, far from the
/// bar, and put a pushed folder's back button there.
private struct SidebarFiles: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let top = model.route.last { $0 != .editor }
        ZStack {
            Group {
                switch top {
                case .folder(let dir): FileBrowserView(dir: dir)
                case .trash: TrashView()
                default: FileBrowserView(dir: "")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .id("\(model.route.count):\(top.map { String(describing: $0) } ?? "")")
            .transition(.asymmetric(insertion: .move(edge: model.routeDeeper ? .trailing : .leading), removal: .opacity))
        }
        .clipped()
        .animation(.smooth(duration: 0.25), value: model.route)
        .environment(\.inSidebar, true)
    }
}

/// The sidebar files' header: back (in a folder or the Trash), the title and
/// the folder's buttons, in the place of a navigation bar.
struct SidebarHeader<Buttons: View>: View {
    let title: String
    @ViewBuilder var buttons: Buttons
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            if !model.route.isEmpty {
                Button { model.route.removeLast() } label: {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 34, height: 34)
                }
                .accessibilityLabel("Back")
            }
            Text(title).font(.headline).lineLimit(1)
                .padding(.leading, model.route.isEmpty ? 8 : 0)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            buttons.frame(minWidth: 34, minHeight: 34)
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
    }
}

/// A row that opens a folder or the Trash: a navigation link on iPhone, a
/// push onto the sidebar's own stack when wide.
struct RouteLink<Label: View>: View {
    let route: Route
    @ViewBuilder var label: Label
    @Environment(AppModel.self) private var model
    @Environment(\.inSidebar) private var inSidebar

    var body: some View {
        if inSidebar {
            Button { model.route.append(route) } label: {
                HStack(spacing: 8) {
                    label
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .tint(.primary)
        } else {
            NavigationLink(value: route) { label }
        }
    }
}

/// The sidebar's panes, as icons in a row as high as the editor's top row.
private struct NavigatorPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            ForEach(NavigatorPane.allCases) { pane in
                let selected = model.navigator == pane
                Button { model.navigator = pane } label: {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 15, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(selected ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
                        .overlay(alignment: .topTrailing) {
                            if pane == .problems, model.problems[min(model.focused, 1)].total > 0 {
                                Circle().fill(model.problems[min(model.focused, 1)].errors > 0 ? .red : .orange)
                                    .frame(width: 7, height: 7).offset(x: -10, y: 4)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pane.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 10)
        .containerCornerOffset(.leading, sizeToFit: true)
        .frame(height: model.verticalBar ? 40 : TopRowMetrics.height)
    }
}

/// One entry of an outline: a class, function or method, or a Markdown heading.
struct OutlineRow: View {
    let label: String
    let line: Int
    let kind: String?
    let depth: Int
    var current = false

    var body: some View {
        HStack(spacing: 8) {
            if let kind {
                // A Markdown heading's kind is its level, "h1" to "h6" (D46).
                let heading = kind.hasPrefix("h")
                Text(heading ? kind.uppercased() : kind == "class" ? "C" : kind == "method" ? "M" : "ƒ")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: heading ? 24 : 20, height: 20)
                    .background(heading ? Color.orange : kind == "class" ? Color.purple : kind == "method" ? Color.teal : Color.blue, in: RoundedRectangle(cornerRadius: 5))
                    .padding(.leading, CGFloat(depth) * 16)
            }
            Text(label).font(.body.monospaced()).fontWeight(current ? .semibold : .regular)
            Spacer()
            Text("\(line)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// The outline of the focused editor's file (D61): kept up to date as it is
/// edited, the symbol with the cursor marked; the filter takes a name or
/// ":line".
private struct OutlinePane: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var symbols: [(name: String, kind: String, line: Int, depth: Int)] = []
    @State private var lines = 1
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter, or :line", text: $query)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .onSubmit { if let first = items.first { jump(first.line) } }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        Button { jump(item.line) } label: {
                            OutlineRow(label: item.label, line: item.line, kind: item.kind, depth: item.depth, current: i == currentIndex)
                        }
                        .tint(.primary)
                        .listRowBackground(i == currentIndex ? Color.accentColor.opacity(0.12) : Color.clear)
                        .id(i)
                    }
                    if items.isEmpty {
                        Text(emptyText).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
                .onChange(of: currentIndex) { _, i in if let i, query.isEmpty { withAnimation { proxy.scrollTo(i, anchor: .center) } } }
            }
        }
        .onAppear { take() }
        .onChange(of: model.outlineFocus) { _, _ in take() }
        // Follows the file and its edits (a pause in typing).
        .task(id: "\(model.file ?? "")|\(model.focused)|\(model.editRevision)") {
            if !symbols.isEmpty { try? await Task.sleep(for: .milliseconds(400)) }
            await load()
        }
    }

    private var emptyText: String {
        if model.file == nil { return "No file open." }
        if !symbols.isEmpty { return "No matching symbols" }
        return model.file.map(isMarkdown) == true ? "No headings in this file" : "No classes or functions in this file"
    }

    /// Opened for something (Go to Line: ":"): that in the filter, and the cursor there.
    private func take() {
        query = model.outlineQuery
        model.outlineQuery = ""
        if model.outlineFocus > 0 { focused = true }
    }

    private func load() async {
        guard let r = await model.editorCall(model.focused, "outline") as? [String: Any] else { symbols = []; return }
        lines = r["lines"] as? Int ?? 1
        symbols = (r["symbols"] as? [[String: Any]] ?? []).map {
            ($0["name"] as? String ?? "", $0["kind"] as? String ?? "function", $0["line"] as? Int ?? 1, $0["depth"] as? Int ?? 0)
        }
    }

    private var items: [(label: String, line: Int, kind: String?, depth: Int)] {
        let trimmed = query.trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))
        if let n = Int(trimmed) {
            let line = max(1, min(n, lines))
            return [("Go to Line \(line)", line, nil, 0)]
        }
        let q = query.trimmingCharacters(in: CharacterSet(charactersIn: ":@").union(.whitespaces)).lowercased()
        return symbols.filter { q.isEmpty || $0.name.lowercased().contains(q) }.map { ($0.name, $0.line, $0.kind, $0.depth) }
    }

    /// The symbol with the cursor: the last one that starts at or before its line.
    private var currentIndex: Int? {
        guard query.isEmpty else { return nil }
        return items.lastIndex { $0.kind != nil && $0.line <= model.cursorLine }
    }

    private func jump(_ line: Int) {
        focused = false
        model.navigatorPicked()
        Task { _ = await model.editorCall(model.focused, "reveal", [line, 1, model.visibleFraction]) }
    }
}
