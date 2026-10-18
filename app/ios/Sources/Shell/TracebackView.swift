import SwiftUI
import UIKit

// A traceback as data (D45, _terrarium_traceback.py), drawn for small screens:
// frames in Python's order (most recent call last), the innermost of the
// program's own frames open with its source and the failing span marked,
// library frames folded, the exception at the bottom with its message in
// the regular font. Earlier exceptions of a chain are folded. Notebooks draw
// the same in HTML (web/src/editor/trace.ts).

struct Trace: Codable, Equatable {
    let text: String
    let exceptions: [TraceException]
}

struct TraceException: Codable, Equatable {
    let type: String
    let message: String
    let notes: [String]?
    let chain: String? // how the exception before this one led to it: cause, context
    let frames: [TraceFrame]
    let syntax: TraceFrame?
    let group: [[TraceException]]?
    let groupMore: Int?
}

struct TraceFrame: Codable, Equatable {
    struct Context: Codable, Equatable {
        let start: Int
        let lines: [String]
    }

    let kind: String // app, library, omitted
    let file: String?
    let name: String?
    let line: Int?
    let endLine: Int?
    let col: Int?
    let endCol: Int?
    let context: Context?
    let `repeat`: Int?
    let count: Int?
    let debug: Int?

    var title: String {
        guard let name else { return "SyntaxError" }
        return name == "<module>" ? "module level" : name
    }

    var location: String { "\(file ?? "?"):\(line ?? 0)" }
}

enum TraceText {
    static func chain(_ kind: String?) -> String {
        kind == "cause"
            ? "The above exception was the direct cause of the following exception:"
            : "During handling of the above exception, another exception occurred:"
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }
}

/// What the views below need from the console line they are in.
private struct TraceEnv {
    let dir: String
    /// Frames of the run's uncaught exception can open the debugger there.
    let inspectable: Bool
}

struct TracebackView: View {
    let trace: Trace
    let dir: String
    let inspectable: Bool

    var body: some View {
        TraceChainView(chain: trace.exceptions, env: TraceEnv(dir: dir, inspectable: inspectable), top: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                Button { UIPasteboard.general.string = trace.text } label: { Label("Copy Traceback", systemImage: "doc.on.doc") }
            }
    }
}

/// A chain, oldest first: the last exception open, the ones before it folded.
private struct TraceChainView: View {
    let chain: [TraceException]
    let env: TraceEnv
    let top: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(chain.enumerated()), id: \.offset) { i, exc in
                if i > 0, exc.chain != nil {
                    Text(TraceText.chain(exc.chain))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if i == chain.count - 1 {
                    ExceptionView(exc: exc, env: env, openInnermost: true, inspectable: top && env.inspectable)
                } else {
                    FoldedException(exc: exc, env: env)
                }
            }
        }
    }
}

private struct FoldedException: View {
    let exc: TraceException
    let env: TraceEnv
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FoldRow(open: $open) {
                Text("\(Text(exc.type).fontWeight(.semibold).foregroundStyle(.red)): \(TraceText.firstLine(exc.message))")
                    .font(.subheadline)
                    .lineLimit(2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if open { ExceptionView(exc: exc, env: env, openInnermost: false, inspectable: false) }
        }
    }
}

/// A row that folds something: a chevron that turns, the label, the whole row a button.
private struct FoldRow<Content: View>: View {
    @Binding var open: Bool
    var enabled = true
    @ViewBuilder let label: Content

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { open.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .opacity(enabled ? 1 : 0)
                label
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityValue(enabled ? (open ? "Expanded" : "Collapsed") : "")
    }
}

private struct ExceptionView: View {
    let exc: TraceException
    let env: TraceEnv
    let openInnermost: Bool
    /// Its frames can open the debugger (the run's uncaught exception).
    let inspectable: Bool

    private enum Item {
        case frame(Int, TraceFrame)
        case library([TraceFrame])
        case omitted(Int)
    }

    /// Library frames in a row fold into one item (unless the open frame is among them).
    private var items: [Item] {
        let open = openIndex
        var out: [Item] = []
        var i = 0
        let frames = exc.frames
        while i < frames.count {
            let f = frames[i]
            if f.kind == "omitted" {
                out.append(.omitted(f.count ?? 0))
                i += 1
            } else if f.kind == "library" {
                var j = i
                while j < frames.count && frames[j].kind == "library" { j += 1 }
                if j - i == 1 || (open.map { $0 >= i && $0 < j } ?? false) {
                    for k in i..<j { out.append(.frame(k, frames[k])) }
                } else {
                    out.append(.library(Array(frames[i..<j])))
                }
                i = j
            } else {
                out.append(.frame(i, f))
                i += 1
            }
        }
        return out
    }

    /// The innermost frame of the program's own (or any with source) starts open.
    private var openIndex: Int? {
        guard openInnermost, exc.syntax == nil else { return nil }
        return exc.frames.lastIndex { $0.kind == "app" && $0.context != nil }
            ?? exc.frames.lastIndex { $0.kind != "omitted" && $0.context != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !exc.frames.isEmpty || exc.syntax != nil {
                VStack(alignment: .leading, spacing: 0) {
                    let open = openIndex
                    ForEach(Array(items.enumerated()), id: \.offset) { n, item in
                        if n > 0 { Divider().padding(.leading, 28) }
                        switch item {
                        case .frame(let i, let f):
                            FrameRow(frame: f, env: env, initiallyOpen: i == open, inspectable: inspectable)
                        case .library(let frames):
                            LibraryFrames(frames: frames, env: env)
                        case .omitted(let count):
                            Text("\(count) more frames not shown")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 28)
                                .padding(.vertical, 8)
                        }
                    }
                    if let syntax = exc.syntax {
                        if !items.isEmpty { Divider().padding(.leading, 28) }
                        FrameRow(frame: syntax, env: env, initiallyOpen: true, inspectable: false)
                    }
                }
                .background(Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            header
            if let group = exc.group, !group.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(group.enumerated()), id: \.offset) { k, member in
                        GroupMember(index: k + 1, chain: member, env: env)
                    }
                    if let more = exc.groupMore, more > 0 {
                        Text("and \(more) more").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color(.separator)).frame(width: 2) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(exc.type)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            if !exc.message.isEmpty {
                Text(exc.message)
                    .font(.subheadline)
            }
            ForEach(Array((exc.notes ?? []).enumerated()), id: \.offset) { _, note in
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
        .overlay(alignment: .leading) { Rectangle().fill(.red).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct LibraryFrames: View {
    let frames: [TraceFrame]
    let env: TraceEnv
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FoldRow(open: $open) {
                Text("\(frames.count) library frames")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .accessibilityHint("Frames in the standard library or installed packages")
            if open {
                ForEach(Array(frames.enumerated()), id: \.offset) { _, f in
                    Divider().padding(.leading, 28)
                    FrameRow(frame: f, env: env, initiallyOpen: false, inspectable: false)
                }
            }
        }
    }
}

private struct GroupMember: View {
    let index: Int
    let chain: [TraceException]
    let env: TraceEnv
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let last = chain.last
            FoldRow(open: $open) {
                Text("\(Text("\(index)").foregroundStyle(.secondary).monospacedDigit())  \(Text(last?.type ?? "").fontWeight(.semibold).foregroundStyle(.red)): \(TraceText.firstLine(last?.message ?? ""))")
                    .font(.subheadline)
                    .lineLimit(2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if open {
                // Members are chains themselves (type-erased: the views nest).
                AnyView(TraceChainView(chain: chain, env: TraceEnv(dir: env.dir, inspectable: false), top: false))
            }
        }
    }
}

private struct FrameRow: View {
    let frame: TraceFrame
    let env: TraceEnv
    let inspectable: Bool
    @State private var open: Bool
    @Environment(AppModel.self) private var model

    init(frame: TraceFrame, env: TraceEnv, initiallyOpen: Bool, inspectable: Bool) {
        self.frame = frame
        self.env = env
        self.inspectable = inspectable
        _open = State(initialValue: initiallyOpen && frame.context != nil)
    }

    private var target: String? { ConsoleLinks.resolve(frame, dir: env.dir) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FoldRow(open: $open, enabled: frame.context != nil) {
                Text(frame.title)
                    .font(.system(size: 13, weight: frame.kind == "app" ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(frame.kind == "app" ? .primary : .secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .padding(.top, 8)
            .padding(.horizontal, 10)
            .accessibilityLabel("\(frame.title), \(frame.file ?? ""), line \(frame.line ?? 0)")
            HStack(spacing: 8) {
                if let target {
                    Button {
                        Task { await model.openLocation(target, line: frame.line, keepConsole: true) }
                    } label: {
                        Text(frame.location).font(.system(size: 12, design: .monospaced))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityHint("Shows \(basename(target)), line \(frame.line ?? 0)")
                } else {
                    Text(frame.location)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if let n = frame.repeat, n > 0 {
                    Text("repeated \(n) more \(n == 1 ? "time" : "times")")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.leading, 28)
            .padding(.trailing, 10)
            .padding(.top, 1)
            .padding(.bottom, 8)
            if open, let context = frame.context {
                CodeCard(frame: frame, context: context)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let target { Task { await model.openLocation(target, line: frame.line, keepConsole: true) } }
                    }
                    .transition(.opacity)
            }
        }
        .contextMenu {
            if let target {
                Button { Task { await model.openLocation(target, line: frame.line, keepConsole: true) } } label: {
                    Label("Show in Editor", systemImage: "arrow.up.forward.square")
                }
            }
            if inspectable, let index = frame.debug {
                Button { model.inspectError(frame: index) } label: { Label("Inspect Here", systemImage: "ladybug") }
            }
            if let line = currentLine {
                Button { UIPasteboard.general.string = line } label: { Label("Copy Line", systemImage: "doc.on.doc") }
            }
        }
    }

    private var currentLine: String? {
        guard let context = frame.context, let line = frame.line else { return nil }
        let i = line - context.start
        return context.lines.indices.contains(i) ? context.lines[i] : nil
    }
}

/// The context lines with numbers; the failing lines tinted, their span
/// marked; long lines scroll sideways, starting where the span is.
private struct CodeCard: View {
    let frame: TraceFrame
    let context: TraceFrame.Context
    private let size: CGFloat = 12.5
    private let rowHeight: CGFloat = 19
    @State private var position = ScrollPosition(edge: .leading)
    @State private var placed = false

    private var first: Int { frame.line ?? 0 }
    private var last: Int { frame.endLine ?? first }
    private func failing(_ n: Int) -> Bool { n >= first && n <= last }

    var body: some View {
        let numbers = context.lines.indices.map { context.start + $0 }
        let width = String(numbers.last ?? 0).count
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(numbers, id: \.self) { n in
                    Text(String(n).leftPadded(to: width))
                        .foregroundStyle(failing(n) ? Color.red : Color(.tertiaryLabel))
                        .frame(height: rowHeight)
                }
            }
            .padding(.horizontal, 10)
            .accessibilityHidden(true)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(numbers, id: \.self) { n in
                        line(n, context.lines[n - context.start])
                            .frame(height: rowHeight)
                    }
                }
                .padding(.trailing, 12)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.width } action: { _, width in
                // A span that starts far to the right: scrolled to, a bit of what is before it showing.
                guard !placed, width > 0 else { return }
                placed = true
                let x = spanStart
                if x > width * 0.6 { position.scrollTo(x: x - width * 0.2) }
            }
        }
        .font(.system(size: size, design: .monospaced))
        .padding(.vertical, 4)
        .background(alignment: .top) {
            VStack(spacing: 0) {
                ForEach(numbers, id: \.self) { n in
                    (failing(n) ? Color.red.opacity(0.11) : Color.clear).frame(height: rowHeight)
                }
            }
            .padding(.vertical, 4)
        }
        .background(Color(.systemBackground))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private func line(_ n: Int, _ text: String) -> some View {
        if failing(n) {
            let (before, span, after) = split(n, text)
            HStack(spacing: 0) {
                Text(before)
                Text(span)
                    .underline(true, color: .red)
                    .background(Color.red.opacity(0.22), in: RoundedRectangle(cornerRadius: 2))
                Text(after)
            }
            .fixedSize()
        } else {
            Text(text).fixedSize()
        }
    }

    /// A failing line in three parts: before, in and after the span (columns are characters, D45).
    private func split(_ n: Int, _ text: String) -> (String, String, String) {
        let chars = Array(text.unicodeScalars)
        let indent = chars.firstIndex { $0 != " " && $0 != "\t" } ?? 0
        var from = n == first ? (frame.col ?? indent) : indent
        var to = n == last ? (frame.endCol ?? chars.count) : chars.count
        from = min(max(0, from), chars.count)
        to = min(max(from, to), chars.count)
        func string(_ r: Range<Int>) -> String { String(String.UnicodeScalarView(chars[r])) }
        if to == from {
            // A point (a SyntaxError at the end of a line): mark one character, or a space after the end.
            if from < chars.count { to = from + 1 } else { return (string(0..<from), " ", "") }
        }
        return (string(0..<from), string(from..<to), string(to..<chars.count))
    }

    /// Where the span starts on the first failing line, in points.
    private var spanStart: CGFloat {
        let i = first - context.start
        guard context.lines.indices.contains(i) else { return 0 }
        let (before, _, _) = split(first, context.lines[i])
        let advance = ("M" as NSString).size(withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: size, weight: .regular)]).width
        return CGFloat(before.unicodeScalars.count) * advance
    }

    private var accessibilityText: String {
        guard let line = frame.line else { return "" }
        let i = line - context.start
        let code = context.lines.indices.contains(i) ? context.lines[i] : ""
        return "Line \(line): \(code)"
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
