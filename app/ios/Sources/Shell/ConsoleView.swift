import SwiftUI
import UIKit

// The console: runs as blocks (header and output), input() right where the
// program asked, ANSI colors, tracebacks that open the line, inline images
// and turtle screens, the debugger's paused block, and the >>> prompt.

/// iPhone: the console as a panel over the bottom of the editor, with three
/// heights (peek, half, full) to drag between or tap.
struct ConsolePanel: View {
    static let peek: CGFloat = 58
    /// How far the collapsed header goes into the bottom safe area.
    static let lowered: CGFloat = 16
    let maxHeight: CGFloat
    /// The safe area below the panel's content (its background fills it).
    var bottomInset: CGFloat = 0
    @Environment(AppModel.self) private var model
    @State private var drag: CGFloat?

    var body: some View {
        let height = drag ?? height(for: model.consoleDetent)
        let collapsed = drag == nil && model.consoleDetent == .peek
        let shape = UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16, style: .continuous)
        VStack(spacing: 0) {
            header(collapsed: collapsed)
            // Open, the >>> bar's background goes down to the screen's edge.
            if !collapsed { ConsoleView(bottomInset: bottomInset) }
        }
        .frame(height: height + (collapsed ? 0 : bottomInset), alignment: .top)
        .frame(maxWidth: .infinity)
        .clipShape(shape)
        .padding(.bottom, collapsed ? bottomInset : 0)
        .background(shape.fill(Color(.secondarySystemBackground)).shadow(color: .black.opacity(0.12), radius: 12, y: -2))
        .animation(drag == nil ? .smooth(duration: 0.3) : nil, value: height)
    }

    private func height(for detent: ConsoleDetent) -> CGFloat {
        switch detent {
        case .peek: Self.peek
        case .half: (maxHeight * 0.5).rounded()
        case .full: maxHeight - 8
        }
    }

    private func header(collapsed: Bool) -> some View {
        let s = model.session
        let run = s.lastRun
        let debug = s.debug
        let title = debug != nil ? (debug!.postMortem ? "Inspecting Error" : "Paused")
            : collapsed && run != nil ? run!.summary(awaitingInput: s.awaitingInput) : "Console"
        return VStack(spacing: 4) {
            Capsule().fill(Color(.tertiaryLabel)).frame(width: 36, height: 5).padding(.top, 6)
            HStack(spacing: 10) {
                StatusDot()
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if collapsed {
                        Text(preview).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if s.status == "running" && debug == nil {
                    PauseButton()
                }
                if let debug { DebugBar(debug: debug) }
                Image(systemName: collapsed ? "chevron.up" : "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.smooth) { model.consoleDetent = model.consoleDetent == .peek ? .half : .peek }
        }
        .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { g in
                let base = height(for: model.consoleDetent)
                drag = min(maxHeight - 8, max(Self.peek, base - g.translation.height))
            }
            .onEnded { g in
                let projected = (drag ?? 0) - g.predictedEndTranslation.height * 0.3 + g.translation.height * 0.3
                let best = [ConsoleDetent.peek, .half, .full].min { abs(height(for: $0) - projected) < abs(height(for: $1) - projected) }!
                drag = nil
                withAnimation(.smooth) { model.consoleDetent = best }
            })
    }

    private var preview: String {
        let s = model.session
        if let debug = s.debug, let frame = debug.frames.first { return "\(frame.label) · line \(frame.line)" }
        for line in s.lines.reversed() {
            if ["stdout", "stderr", "input"].contains(line.kind) {
                let text = ANSI.strip(line.text).trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? ""
                if !text.isEmpty { return text }
            }
            if line.kind == "image" { return "Figure" }
            if line.kind == "turtle" { return "Turtle graphics" }
        }
        if let run = s.lastRun { return run.file.map(basename) ?? "Console" }
        return "Output and >>> prompt"
    }
}

struct StatusDot: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }

    private var color: Color {
        let s = model.session
        if let debug = s.debug { return debug.postMortem ? .red : .green }
        if s.awaitingInput { return .orange }
        switch s.lastRun?.status {
        case "running", "ok": return .green
        case "error", "crashed": return .red
        case "stopped": return .gray
        default: return Color(.tertiaryLabel)
        }
    }
}

struct PauseButton: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Button { model.pause() } label: { Image(systemName: "pause.fill").font(.footnote) }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .disabled(model.session.awaitingInput || model.session.pausing)
            .accessibilityLabel("Pause")
    }
}

/// The transcript and the >>> prompt.
struct ConsoleView: View {
    /// Room below the >>> bar (the bottom safe area), in its background.
    var bottomInset: CGFloat = 0
    @Environment(AppModel.self) private var model
    @State private var atBottom = true

    var body: some View {
        @Bindable var model = model
        let s = model.session
        let groups = Self.group(s.lines)
        let lastRunID = groups.last?.runId
        VStack(spacing: 0) {
            GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if s.lines.isEmpty {
                            ContentUnavailableView {
                                Label("Console", systemImage: "terminal")
                            } description: {
                                Text("Output from your programs appears here. Type Python below to try something out.")
                            }
                            .padding(.top, 20)
                        }
                        ForEach(groups, id: \.runId) { group in
                            RunBlock(group: group, last: group.runId == lastRunID)
                        }
                        if let debug = s.debug, !groups.contains(where: { $0.runId == lastRunID }) {
                            PausedBlock(debug: debug)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.bottom, 8)
                }
                // When the keyboard (and its key bar) shrinks the console, keep
                // the end of the output in view instead of under them.
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .onScrollGeometryChange(for: ScrollState.self) { geo in
                    ScrollState(bottom: geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 30, height: geo.contentSize.height)
                } action: { old, new in
                    // Rows measured taller than estimated (a traceback's open
                    // frame) push the end down: follow it if we were there.
                    if new.height > old.height && old.bottom && !new.bottom {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    } else {
                        atBottom = new.bottom
                    }
                }
                .onChange(of: contentKey) {
                    if atBottom { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: s.debug?.stopId) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: model.consoleSubmits) {
                    // Return in >>> or input(): follow the output again.
                    atBottom = true
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .environment(\.consoleHeight, geo.size.height)
            }
            replBar
        }
        .background(Color(.secondarySystemBackground))
    }

    private struct ScrollState: Equatable {
        let bottom: Bool
        let height: CGFloat
    }

    private var contentKey: Int {
        let s = model.session
        return s.lines.count &* 31 &+ (s.lines.last?.text.count ?? 0) &+ (s.awaitingInput ? 7 : 0)
    }

    private var replBar: some View {
        @Bindable var model = model
        let s = model.session
        let paused = s.debug
        let busy = s.running && paused == nil
        let frame = paused?.frame
        let placeholder = frame.map { "Python in \($0.name == "<module>" ? basename($0.file) : $0.name + "()")" }
            ?? (busy ? (s.awaitingInput ? "Answer the program above" : "Running…") : "Python")
        return HStack(spacing: 8) {
            Text(">>>").font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
            CodeField(text: $model.consoleInput, placeholder: placeholder, field: .console, returnKey: .go,
                      history: model.consoleHistory) { model.submitConsole() }
                .frame(height: 36)
                .padding(.horizontal, 12)
                .background(Color(.tertiarySystemFill), in: Capsule())
                .disabled(busy)
            if !s.lines.isEmpty && !busy && paused == nil {
                Button { model.clearConsole() } label: { Image(systemName: "trash") }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear console")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .padding(.bottom, bottomInset)
        .background(.bar)
    }

    struct Group {
        let runId: Int
        var lines: [ConsoleLine]
    }

    static func group(_ lines: [ConsoleLine]) -> [Group] {
        var groups: [Group] = []
        for line in lines {
            if let last = groups.last, last.runId == line.runId {
                groups[groups.count - 1].lines.append(line)
            } else {
                groups.append(Group(runId: line.runId, lines: [line]))
            }
        }
        return groups
    }
}

private struct RunBlock: View {
    let group: ConsoleView.Group
    let last: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.session
        let run = s.runs[group.runId]
        // While paused, the paused block sits where the program stopped and
        // >>> evaluations follow it, next to the prompt you type in.
        let splitAt = last ? s.debug?.firstLineId : nil
        let before = group.lines.filter { splitAt == nil || $0.id < splitAt! }
        let after = splitAt == nil ? [] : group.lines.filter { $0.id >= splitAt! }
        VStack(alignment: .leading, spacing: 0) {
            if let run { header(run) }
            ForEach(before) { LineView(line: $0, dir: run?.dir ?? "", inspectable: inspectable(run)) }
            if last && s.awaitingInput { InputLine() }
            if let debug = s.debug, last { PausedBlock(debug: debug) }
            ForEach(after) { LineView(line: $0, dir: run?.dir ?? "", inspectable: inspectable(run)) }
        }
        .padding(.bottom, 6)
    }

    /// The run's uncaught error can still be debugged (the worker keeps it).
    private func inspectable(_ run: RunInfo?) -> Bool {
        guard let run else { return false }
        return run.status == "error" && run.file != nil && last && model.session.canInspect
    }

    private func header(_ run: RunInfo) -> some View {
        let s = model.session
        let paused = s.debug != nil && last
        let time = Date(timeIntervalSince1970: run.startedAt / 1000).formatted(date: .omitted, time: .shortened)
        let inspectable = self.inspectable(run)
        return HStack(spacing: 8) {
            Group {
                switch run.status {
                case "running" where paused: Image(systemName: "pause.circle.fill").foregroundStyle(.green)
                case "running": ProgressView().controlSize(.mini)
                case "ok": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case "stopped": Image(systemName: "stop.circle.fill").foregroundStyle(.gray)
                default: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            .font(.footnote)
            .frame(width: 16)
            Text(run.file.map(basename) ?? "Console").font(.footnote.weight(.semibold))
            Text("\(run.summary(awaitingInput: s.awaitingInput && last, paused: paused))\(run.python.map { " · Python \($0)" } ?? "") · \(time)")
                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if inspectable {
                Button { model.inspectError() } label: { Label("Inspect", systemImage: "ladybug").font(.footnote) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }
}

extension EnvironmentValues {
    /// The console's visible height: a turtle screen fits in it (never scaled up).
    @Entry var consoleHeight: CGFloat = .infinity
}

private struct LineView: View {
    let line: ConsoleLine
    let dir: String
    var inspectable = false
    @Environment(AppModel.self) private var model
    @Environment(\.consoleHeight) private var consoleHeight

    var body: some View {
        switch line.kind {
        case "run":
            EmptyView()
        case "image":
            if let data = Data(base64Encoded: line.text), let image = UIImage(data: data, scale: 2) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: image.size.width)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .accessibilityLabel("Figure")
            }
        case "turtle":
            if let scene = model.turtles[line.text] {
                TurtleView(scene: scene, maxHeight: consoleHeight - 60) { scene, event in model.sendTurtle(scene, event) }
                    .padding(.horizontal, 16)
            }
        case "prompt":
            Text(">>> " + line.text)
                .font(.system(size: 13.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        case "stderr" where line.trace != nil:
            TracebackView(trace: line.trace!, dir: dir, inspectable: inspectable)
        case "stderr" where line.text.contains("File \"") && !line.text.contains("\u{1b}"):
            TextTracebackView(text: line.text, dir: dir)
        default:
            ForEach(Array(ANSI.chunks(line.text).enumerated()), id: \.offset) { _, chunk in
                Text(ANSI.attributed(chunk, base: color))
                    .font(.system(size: 13.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var color: Color {
        switch line.kind {
        case "stderr": .red
        case "system": .secondary
        case "input": .blue
        default: .primary
        }
    }
}

/// stderr with `File "x.py", line 3` lines that open that line (a
/// traceback the program printed itself; the runtime's come as data, D45).
private struct TextTracebackView: View {
    let text: String
    let dir: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let lines = text.hasSuffix("\n") ? String(text.dropLast()).components(separatedBy: "\n") : text.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if let link = ConsoleLinks.parse(line, dir: dir) {
                    Text(line)
                        .underline(true, color: .red.opacity(0.4))
                        .foregroundStyle(.red)
                        .onTapGesture { Task { await model.openLocation(link.path, line: link.line, keepConsole: true) } }
                        .accessibilityAddTraits(.isLink)
                        .accessibilityHint("Shows \(basename(link.path)), line \(link.line)")
                } else {
                    Text(line).foregroundStyle(.red)
                }
            }
        }
        .font(.system(size: 13.5, design: .monospaced))
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// input(): a field right where the program asked.
private struct InputLine: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        CodeField(text: $model.programInput, placeholder: "Input", field: .input, returnKey: .send, history: []) {
            model.submitProgramInput()
        }
        .frame(height: 32)
        .padding(.horizontal, 10)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

/// Links in tracebacks: `File "x.py", line 3` for files of the project.
enum ConsoleLinks {
    struct Link {
        let text: String
        let path: String
        let line: Int
    }

    private static let projectRoot = "/home/pyodide/project/"
    private static let regex = try! NSRegularExpression(pattern: #"^(\s*)(File "([^"]+)", line (\d+))(.*)$"#)

    static func parse(_ line: String, dir: String) -> Link? {
        let ns = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let file = ns.substring(with: m.range(at: 3))
        guard let number = Int(ns.substring(with: m.range(at: 4))), let path = resolve(file, dir: dir) else { return nil }
        return Link(text: ns.substring(with: m.range(at: 2)), path: path, line: number)
    }

    /// A traceback's file name as an app path: project files only, relative
    /// to the folder the program ran in (`dir`).
    static func resolve(_ file: String, dir: String) -> String? {
        if file.hasPrefix("<") { return nil }
        if file.hasPrefix(projectRoot) { return joinPath(dir, String(file.dropFirst(projectRoot.count))) }
        if file.hasPrefix("/") { return nil } // stdlib, site-packages, runtime
        return joinPath(dir, file)
    }

    /// A frame of a traceback as data (D45): the program's own files only.
    static func resolve(_ frame: TraceFrame, dir: String) -> String? {
        guard frame.kind == "app", let file = frame.file else { return nil }
        return resolve(file, dir: dir)
    }

    @MainActor
    static func all(_ session: SessionMirror) -> [Link] {
        session.lines.filter { $0.kind == "stderr" }.flatMap { line in
            let dir = session.runs[line.runId]?.dir ?? ""
            return line.text.components(separatedBy: "\n").compactMap { parse($0, dir: dir) }
        }
    }
}

/// ANSI SGR colors in program output.
enum ANSI {
    private static let palette: [UIColor] = [
        "#000000", "#c91b00", "#00a600", "#c7c400", "#2225c4", "#ca30c7", "#00a6b2", "#bfbfbf",
        "#686868", "#ff6e67", "#5ffa68", "#fffc67", "#6871ff", "#ff77ff", "#60fdff", "#ffffff",
    ].map { UIColorParser.uiColor($0)! }
    /// SGR codes, and OSC 8 links (console.write_link, D40).
    private static let regex = try! NSRegularExpression(pattern: "\u{1b}\\[([0-9;]*)([A-Za-z])|\u{1b}\\]8;[^;\u{1b}\u{07}]*;([^\u{1b}\u{07}]*)(?:\u{1b}\\\\|\u{07})")

    static func strip(_ text: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
    }

    /// Long output in pieces of about 80 lines, so the list stays lazy.
    static func chunks(_ text: String) -> [String] {
        let trimmed = text.hasSuffix("\n") ? String(text.dropLast()) : text
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count <= 80 { return [trimmed] }
        return stride(from: 0, to: lines.count, by: 80).map { lines[$0..<min($0 + 80, lines.count)].joined(separator: "\n") }
    }

    private static func color256(_ n: Int) -> UIColor {
        if n < 16 { return palette[n] }
        if n >= 232 {
            let v = CGFloat(8 + (n - 232) * 10) / 255
            return UIColor(white: v, alpha: 1)
        }
        let i = n - 16
        func c(_ x: Int) -> CGFloat { x == 0 ? 0 : CGFloat(55 + x * 40) / 255 }
        return UIColor(red: c(i / 36), green: c((i / 6) % 6), blue: c(i % 6), alpha: 1)
    }

    static func attributed(_ text: String, base: Color) -> AttributedString {
        var out = AttributedString()
        guard text.contains("\u{1b}") else {
            var plain = AttributedString(text)
            plain.foregroundColor = base
            return plain
        }
        var fg: UIColor?
        var bg: UIColor?
        var bold = false, dim = false, italic = false, underline = false
        var link: URL?
        let ns = text as NSString
        var last = 0
        func push(_ s: String) {
            guard !s.isEmpty else { return }
            var a = AttributedString(s)
            a.foregroundColor = fg.map { Color(uiColor: $0) } ?? base
            if let bg { a.backgroundColor = Color(uiColor: bg) }
            if bold { a.inlinePresentationIntent = .stronglyEmphasized }
            if italic { a.inlinePresentationIntent = (a.inlinePresentationIntent ?? []).union(.emphasized) }
            if underline { a.underlineStyle = .single }
            if dim { a.foregroundColor = (fg.map { Color(uiColor: $0) } ?? base).opacity(0.6) }
            if let link {
                a.link = link
                a.underlineStyle = .single
                if fg == nil { a.foregroundColor = .accentColor }
            }
            out += a
        }
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            push(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
            if m.range(at: 3).location != NSNotFound {
                let target = ns.substring(with: m.range(at: 3))
                link = target.isEmpty ? nil : URL(string: target)
                continue
            }
            guard m.range(at: 2).location != NSNotFound, ns.substring(with: m.range(at: 2)) == "m" else { continue }
            let codes = ns.substring(with: m.range(at: 1)).split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
            var i = 0
            while i < codes.count {
                let c = codes[i]
                switch c {
                case 0: fg = nil; bg = nil; bold = false; dim = false; italic = false; underline = false
                case 1: bold = true
                case 2: dim = true
                case 3: italic = true
                case 4: underline = true
                case 22: bold = false; dim = false
                case 23: italic = false
                case 24: underline = false
                case 30...37: fg = palette[c - 30]
                case 90...97: fg = palette[c - 90 + 8]
                case 40...47: bg = palette[c - 40]
                case 100...107: bg = palette[c - 100 + 8]
                case 39: fg = nil
                case 49: bg = nil
                case 38, 48:
                    if i + 2 < codes.count, codes[i + 1] == 5 {
                        let v = color256(codes[i + 2])
                        if c == 38 { fg = v } else { bg = v }
                        i += 2
                    } else if i + 4 < codes.count, codes[i + 1] == 2 {
                        let v = UIColor(red: CGFloat(codes[i + 2]) / 255, green: CGFloat(codes[i + 3]) / 255, blue: CGFloat(codes[i + 4]) / 255, alpha: 1)
                        if c == 38 { fg = v } else { bg = v }
                        i += 4
                    }
                default: break
                }
                i += 1
            }
        }
        push(ns.substring(from: last))
        return out
    }
}

/// A one-line field for code: no capitalization, autocorrection or smart
/// punctuation; ↑/↓ walk the history on a hardware keyboard.
struct CodeField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let field: ConsoleField
    let returnKey: UIReturnKeyType
    let history: [String]
    let onSubmit: () -> Void
    @Environment(AppModel.self) private var model

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> HistoryTextField {
        let view = HistoryTextField()
        view.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardType = .asciiCapable
        view.returnKeyType = returnKey
        view.delegate = context.coordinator
        view.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: HistoryTextField, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        view.placeholder = placeholder
        view.history = history
        view.onHistory = { [binding = $text] value in binding.wrappedValue = value }
        let wants = model.focusedField == field
        view.wantsFocus = wants
        if wants && !view.isFirstResponder && view.window != nil {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !wants && view.isFirstResponder {
            DispatchQueue.main.async { _ = view.resignFirstResponder() }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: CodeField
        init(_ parent: CodeField) { self.parent = parent }

        @MainActor @objc func changed(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            MainActor.assumeIsolated {
                parent.text = textField.text ?? ""
                parent.onSubmit()
            }
            return false
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            MainActor.assumeIsolated {
                if parent.model.focusedField != parent.field { parent.model.focusedField = parent.field }
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            MainActor.assumeIsolated {
                if parent.model.focusedField == parent.field { parent.model.focusedField = nil }
            }
        }
    }
}

final class HistoryTextField: UITextField {
    var history: [String] = []
    var onHistory: (String) -> Void = { _ in }
    /// Take the keyboard once on screen (input() asks before the field exists).
    var wantsFocus = false
    private var index = -1

    /// The code keys above the keyboard, like the editor's.
    override var inputAccessoryView: UIView? {
        get { KeyboardAccessory.shared.fieldView }
        set {}
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { KeyboardAccessory.shared.field = self }
        return ok
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if wantsFocus && window != nil && !isFirstResponder {
            DispatchQueue.main.async { [weak self] in _ = self?.becomeFirstResponder() }
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        guard !history.isEmpty else { return super.keyCommands }
        let up = UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(older))
        let down = UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(newer))
        up.wantsPriorityOverSystemBehavior = true
        down.wantsPriorityOverSystemBehavior = true
        return [up, down] + (super.keyCommands ?? [])
    }

    @objc private func older() {
        index = index < 0 ? history.count - 1 : max(0, index - 1)
        set(history[index])
    }

    @objc private func newer() {
        guard index >= 0 else { return }
        index += 1
        if index >= history.count {
            index = -1
            set("")
        } else {
            set(history[index])
        }
    }

    private func set(_ value: String) {
        text = value
        onHistory(value)
    }

    override func resignFirstResponder() -> Bool {
        index = -1
        return super.resignFirstResponder()
    }
}
