import Observation
import SwiftUI

// The native side of ui.py (D26, D30): Python owns the element tree and sends
// batched ops; this store mirrors it as one observable node per element, and
// SwiftUI views read the nodes. A `set` op touches one node, so only the views
// reading that node update, which is the same fine-grained model as Solid.
//
// Messages: {seq, ops: [...]}. Ops (see uikit/web/renderer.js for the web twin):
//   ["mount", parentId, beforeId|null, {i, t, p, c}]   build a subtree, insert it
//   ["move", parentId, id, beforeId|null]                reorder
//   ["unmount", id]                                      remove (and forget the subtree)
//   ["set", id, {prop: value}]                           update props
//   ["call", id, method, args]                           focus(), blur(), ...
//   ["config", {theme, tint, title, close_button, full_screen}]  ["dialog", n, spec]
//   ["toast", text, seconds]  ["frame", canvasId]  ["reset"]
//   ["close"]                                            ui.close(): end the app
// Events go back as send("<id>:<event>", JSON args). A new store asks for a
// full snapshot ("0:resync").

@MainActor @Observable
final class UINode: Identifiable {
    let id: Int
    let type: String
    var props: [String: JSONValue]
    var children: [UINode] = []
    @ObservationIgnored weak var parent: UINode?
    /// Screens the user popped (back button, edge swipe) that Python has not
    /// unmounted yet; the navigation path leaves them out.
    var poppedLocally: Set<Int> = []
    /// Bumped by `call` ops; text fields watch them to take or give up focus.
    var focusRequest = 0
    var blurRequest = 0
    @ObservationIgnored var imageCache: (src: String, image: UIImage)?

    init(id: Int, type: String, props: [String: JSONValue]) {
        self.id = id
        self.type = type
        self.props = props
    }

    func string(_ key: String) -> String? {
        guard let v = props[key], !v.isNull else { return nil }
        return v.string
    }

    func double(_ key: String) -> Double? { props[key]?.double }
    func bool(_ key: String) -> Bool { props[key]?.truthy ?? false }
    func has(_ key: String) -> Bool { props[key].map { !$0.isNull } ?? false }
}

struct UIDialog: Identifiable, Equatable {
    let id: Int
    let spec: [String: JSONValue]
    var kind: String { spec["kind"]?.string ?? "alert" }
}

struct UIToast: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

@MainActor @Observable
final class UIStore {
    private(set) var root = UINode(id: 0, type: "#root", props: [:])
    var theme: String?
    var tint: String?
    /// The app's first screen has the close button (`ui.run(close_button=)`);
    /// without it a two-finger swipe down closes the app.
    var closeButton = true
    /// `ui.run(full_screen=True)`: over everything, also where a half of the
    /// wide workspace would show the app (D59).
    var fullScreen = false
    var dialogs: [UIDialog] = []
    var toasts: [UIToast] = []
    /// Sheets that are open, in the order they were created (nested ones last).
    private(set) var openSheets: [UINode] = []

    @ObservationIgnored private(set) var nodes: [Int: UINode] = [:]
    @ObservationIgnored private var sheetIDs: Set<Int> = []
    @ObservationIgnored var frameAcks: [Int: () -> Void] = [:]
    /// Sends an event to Python: ("<id>:<event>", JSON array of arguments).
    @ObservationIgnored var send: (String, String) -> Void = { _, _ in }
    /// Ends the app (the close button, `ui.close()`, a two-finger swipe down).
    @ObservationIgnored var close: () -> Void = {}
    /// Runs the app's program again (the close button's menu).
    @ObservationIgnored var restart: () -> Void = {}
    /// The program asked to close: what it sends after that is not shown.
    @ObservationIgnored private var closed = false
    @ObservationIgnored var lastRender: (ops: Int, ms: Double) = (0, 0)

    init() {
        nodes[0] = root
    }

    // MARK: ops

    func render(_ message: String) {
        let t0 = CACurrentMediaTime()
        guard let msg = JSONValue.parse(message), let ops = msg["ops"]?.array else { return }
        var sheetsChanged = false
        for op in ops where !closed {
            guard let a = op.array, let name = a.first?.string else { continue }
            if apply(name, Array(a.dropFirst())) { sheetsChanged = true }
        }
        if sheetsChanged { updateSheets() }
        lastRender = (ops.count, (CACurrentMediaTime() - t0) * 1000)
    }

    /// Applies one op; returns whether open sheets may have changed.
    private func apply(_ name: String, _ a: [JSONValue]) -> Bool {
        switch name {
        case "mount":
            guard a.count >= 3, let parentID = a[0].int, let parent = nodes[parentID] else { return false }
            let node = build(a[2], sheets: &sheetIDs)
            insert(node, into: parent, before: a[1].int.flatMap { nodes[$0] })
            return !sheetIDs.isEmpty
        case "move":
            guard a.count >= 2, let parentID = a[0].int, let parent = nodes[parentID],
                  let id = a[1].int, let node = nodes[id] else { return false }
            insert(node, into: parent, before: a.count > 2 ? a[2].int.flatMap { nodes[$0] } : nil)
            return false
        case "unmount":
            guard let id = a.first?.int, let node = nodes[id] else { return false }
            if let parent = node.parent {
                parent.children.removeAll { $0 === node }
                parent.poppedLocally.remove(id)
            }
            node.parent = nil
            forget(node)
            return true
        case "set":
            guard a.count >= 2, let id = a[0].int, let node = nodes[id], let props = a[1].object else { return false }
            for (k, v) in props where node.props[k] != v { node.props[k] = v }
            return node.type == "Sheet" && props["open"] != nil
        case "call":
            guard a.count >= 2, let id = a[0].int, let node = nodes[id], let method = a[1].string else { return false }
            switch method {
            case "focus": node.focusRequest += 1
            case "blur": node.blurRequest += 1
            default: break
            }
            return false
        case "config":
            let config = a.first?.object ?? [:]
            theme = config["theme"]?.string
            tint = config["tint"].flatMap { $0.isNull ? nil : $0.string }
            closeButton = config["close_button"].map { $0.isNull || $0.truthy } ?? true
            fullScreen = config["full_screen"]?.truthy ?? false
            return false
        case "close":
            closed = true
            close()
            return false
        case "dialog":
            guard a.count >= 2, let id = a[0].int else { return false }
            dialogs.append(UIDialog(id: id, spec: a[1].object ?? [:]))
            return false
        case "toast":
            let toast = UIToast(text: a.first?.string ?? "")
            toasts.append(toast)
            let seconds = a.count > 1 ? a[1].double ?? 2 : 2
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                withAnimation { self?.toasts.removeAll { $0.id == toast.id } }
            }
            return false
        case "frame":
            if let id = a.first?.int { frameAcks[id]?() }
            return false
        case "reset":
            reset()
            return true
        default:
            return false
        }
    }

    private func build(_ tree: JSONValue, sheets: inout Set<Int>) -> UINode {
        let node = UINode(id: tree["i"]?.int ?? -1, type: tree["t"]?.string ?? "?", props: tree["p"]?.object ?? [:])
        nodes[node.id] = node
        if node.type == "Sheet" { sheets.insert(node.id) }
        if let kids = tree["c"]?.array {
            node.children = kids.map { kid in
                let child = build(kid, sheets: &sheets)
                child.parent = node
                return child
            }
        }
        return node
    }

    private func insert(_ node: UINode, into parent: UINode, before: UINode?) {
        if let old = node.parent { old.children.removeAll { $0 === node } }
        node.parent = parent
        if let before, let i = parent.children.firstIndex(where: { $0 === before }) {
            parent.children.insert(node, at: i)
        } else {
            parent.children.append(node)
        }
    }

    private func forget(_ node: UINode) {
        nodes.removeValue(forKey: node.id)
        sheetIDs.remove(node.id)
        frameAcks.removeValue(forKey: node.id)
        for child in node.children { forget(child) }
    }

    func reset() {
        root = UINode(id: 0, type: "#root", props: [:])
        nodes = [0: root]
        sheetIDs = []
        frameAcks = [:]
        dialogs = []
        openSheets = []
        closeButton = true
        fullScreen = false
        closed = false
    }

    private func updateSheets() {
        let open = sheetIDs.sorted().compactMap { nodes[$0] }.filter { $0.bool("open") }
        if open.map(\.id) != openSheets.map(\.id) { openSheets = open }
    }

    // MARK: events

    func emit(_ node: UINode, _ event: String, _ args: [Any] = []) {
        guard nodes[node.id] === node else { return }
        send("\(node.id):\(event)", jsonText(args))
    }

    /// The renderer already shows `value`: remember it, so Python's echo is a no-op.
    func emitValue(_ node: UINode, _ key: String, _ value: JSONValue, event: String = "change") {
        if node.props[key] == value { return }
        node.props[key] = value
        emit(node, event, [value.foundation])
    }

    func sheetDismissed(_ node: UINode) {
        node.props["open"] = .bool(false)
        updateSheets()
        emit(node, "dismiss")
    }

    func replyDialog(_ dialog: UIDialog, _ value: Any?) {
        guard dialogs.contains(where: { $0.id == dialog.id }) else { return }
        dialogs.removeAll { $0.id == dialog.id }
        send("0:dialog", jsonText([dialog.id, value ?? NSNull()]))
    }

    func resync() {
        send("0:resync", "[]")
    }

    func node(_ id: Int) -> UINode? { nodes[id] }

    // MARK: testing

    /// The tree as JSON-able values, for the app's self-test.
    func snapshot(_ node: UINode? = nil) -> [String: Any] {
        let node = node ?? root
        var out: [String: Any] = ["i": node.id, "t": node.type, "p": node.props.mapValues(\.foundation)]
        let kids = node.children.filter { !(node.poppedLocally.contains($0.id)) }
        if !kids.isEmpty { out["c"] = kids.map { snapshot($0) } }
        return out
    }
}
