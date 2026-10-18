import SwiftUI

// Inputs. Values are two-way: a change is written into the node and sent to
// Python, which remembers it, so it never echoes back what is already shown.

struct ButtonNode: View {
    let node: UINode
    @Environment(UIStore.self) private var store
    @Environment(\.uiContext) private var context
    @Environment(\.uiFillWidth) private var fill

    var body: some View {
        let kind = node.string("kind") ?? "filled"
        let destructive = kind == "destructive"
        let button = Button(role: destructive ? .destructive : nil) {
            store.emit(node, "click")
        } label: {
            label.frame(maxWidth: fill && context != .toolbar ? .infinity : nil)
        }
        switch context {
        case .toolbar:
            button
        case .list:
            button.buttonStyle(.borderless)
        case .plain:
            styled(button, kind: kind)
                .controlSize(node.string("size") == "small" ? .small : node.string("size") == "large" ? .extraLarge : .large)
        }
    }

    @ViewBuilder
    private var label: some View {
        let text = node.string("label")
        let icon = node.string("icon")
        if !node.children.isEmpty {
            Children(node: node)
        } else if let icon, let text, !text.isEmpty {
            Label { Text(text) } icon: { IconImage(name: icon) }
        } else if let icon {
            IconImage(name: icon)
        } else {
            Text(text ?? "")
        }
    }

    @ViewBuilder
    private func styled(_ button: some View, kind: String) -> some View {
        switch kind {
        case "plain": button.buttonStyle(.borderless)
        case "tinted": button.buttonStyle(.bordered)
        case "gray": button.buttonStyle(.bordered).tint(.secondary)
        // White content: the icon of a Label would otherwise take the tint,
        // which is the button's own color, and vanish.
        case "destructive": button.buttonStyle(.borderedProminent).tint(.red).foregroundStyle(.white)
        default: button.buttonStyle(.borderedProminent).foregroundStyle(.white)
        }
    }
}

private func keyboard(_ kind: String) -> UIKeyboardType {
    switch kind {
    case "email": .emailAddress
    case "number": .numberPad
    case "decimal": .decimalPad
    case "url": .URL
    case "tel": .phonePad
    case "search": .webSearch
    default: .default
    }
}

struct TextFieldNode: View {
    let node: UINode
    @Environment(UIStore.self) private var store
    @Environment(\.uiContext) private var context
    @FocusState private var focused: Bool

    var body: some View {
        let kind = node.string("kind") ?? "text"
        let placeholder = node.string("placeholder") ?? ""
        let text = Binding(get: { node.string("value") ?? "" }, set: { store.emitValue(node, "value", .string($0)) })
        let field = Group {
            if kind == "password" {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
            }
        }
        .focused($focused)
        .keyboardType(keyboard(kind))
        .textInputAutocapitalization(kind == "text" ? .sentences : .never)
        .autocorrectionDisabled(kind != "text" && kind != "search")
        .submitLabel(kind == "search" ? .search : .done)
        .onSubmit { store.emit(node, "submit", [node.string("value") ?? ""]) }
        .onChange(of: node.focusRequest) { focused = true }
        .onChange(of: node.blurRequest) { focused = false }
        .task {
            if node.bool("autofocus") {
                try? await Task.sleep(for: .milliseconds(350))
                focused = true
            }
        }

        if let label = node.string("label"), !label.isEmpty {
            LabeledContent(label) { field.multilineTextAlignment(.trailing) }
        } else if kind == "search" {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                field
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if context == .list {
            field
        } else {
            field
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

struct TextAreaNode: View {
    let node: UINode
    @Environment(UIStore.self) private var store
    @Environment(\.uiContext) private var context
    @FocusState private var focused: Bool

    var body: some View {
        let rows = max(1, node.props["rows"]?.int ?? 4)
        let field = TextField(node.string("placeholder") ?? "", text: Binding(
            get: { node.string("value") ?? "" },
            set: { store.emitValue(node, "value", .string($0)) }
        ), axis: .vertical)
        .lineLimit(rows...max(rows, 12))
        .focused($focused)
        .onChange(of: node.focusRequest) { focused = true }
        .onChange(of: node.blurRequest) { focused = false }
        if context == .list {
            field
        } else {
            field
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

struct ToggleNode: View {
    let node: UINode
    @Environment(UIStore.self) private var store

    var body: some View {
        Toggle(node.string("label") ?? "", isOn: Binding(
            get: { node.bool("value") },
            set: { store.emitValue(node, "value", .bool($0)) }
        ))
    }
}

struct SliderNode: View {
    let node: UINode
    @Environment(UIStore.self) private var store

    var body: some View {
        let lo = node.double("min") ?? 0
        let hi = max(lo + 1e-9, node.double("max") ?? 1)
        let value = Binding(get: { min(max(node.double("value") ?? lo, lo), hi) }, set: { store.emitValue(node, "value", .number($0)) })
        HStack(spacing: 12) {
            if let label = node.string("label"), !label.isEmpty {
                Text(label)
            }
            if let step = node.double("step"), step > 0 {
                Slider(value: value, in: lo...hi, step: step)
            } else {
                Slider(value: value, in: lo...hi)
            }
        }
    }
}

struct StepperNode: View {
    let node: UINode
    @Environment(UIStore.self) private var store

    var body: some View {
        let value = node.double("value") ?? 0
        let atMin = node.double("min").map { value <= $0 } ?? false
        let atMax = node.double("max").map { value >= $0 } ?? false
        Stepper {
            HStack {
                Text(node.string("label") ?? "")
                Spacer()
                Text(formatted(value)).foregroundStyle(.secondary).monospacedDigit()
            }
        } onIncrement: {
            if !atMax { store.emit(node, "change", [1]) }
        } onDecrement: {
            if !atMin { store.emit(node, "change", [-1]) }
        }
    }

    private func formatted(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(format: "%g", v)
    }
}

struct PickerNode: View {
    let node: UINode
    @Environment(UIStore.self) private var store
    @Environment(\.uiContext) private var context

    var body: some View {
        let options = node.props["options"]?.array?.map { $0.string ?? "" } ?? []
        let label = node.string("label") ?? ""
        let selection = Binding(get: { node.props["value"]?.int ?? -1 }, set: { store.emitValue(node, "value", .number(Double($0))) })
        let picker = Picker(label, selection: selection) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                Text(option).tag(i)
            }
        }
        if node.string("kind") == "menu" {
            if context == .list || label.isEmpty {
                picker.pickerStyle(.menu)
            } else {
                LabeledContent(label) { picker.pickerStyle(.menu).labelsHidden() }
            }
        } else if label.isEmpty {
            picker.pickerStyle(.segmented).labelsHidden()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.footnote).foregroundStyle(.secondary)
                picker.pickerStyle(.segmented).labelsHidden()
            }
        }
    }
}

struct DatePickerNode: View {
    let node: UINode
    @Environment(UIStore.self) private var store

    var body: some View {
        let kind = node.string("kind") ?? "date"
        let components: DatePickerComponents = switch kind {
        case "time": .hourAndMinute
        case "datetime": [.date, .hourAndMinute]
        default: .date
        }
        let label = node.string("label") ?? ""
        let date = Binding(
            get: { Self.parse(node.string("value"), kind) ?? Date() },
            set: { store.emitValue(node, "value", .string(Self.format($0, kind))) }
        )
        if label.isEmpty {
            DatePicker("", selection: date, displayedComponents: components).labelsHidden()
        } else {
            DatePicker(label, selection: date, displayedComponents: components)
        }
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = format
        return f
    }

    private static let formats: [String: [String]] = [
        "date": ["yyyy-MM-dd"],
        "time": ["HH:mm", "HH:mm:ss"],
        "datetime": ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"],
    ]

    static func parse(_ text: String?, _ kind: String) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        for format in formats[kind] ?? formats["date"]! {
            if let d = formatter(format).date(from: text) { return d }
        }
        return nil
    }

    static func format(_ date: Date, _ kind: String) -> String {
        formatter((formats[kind] ?? formats["date"]!)[0]).string(from: date)
    }
}

struct ColorPickerNode: View {
    let node: UINode
    @Environment(UIStore.self) private var store

    var body: some View {
        ColorPicker(node.string("label") ?? "", selection: Binding(
            get: { UIColorParser.color(node.string("value")) ?? .black },
            set: { store.emitValue(node, "value", .string(UIColorParser.hexString(UIColor($0)))) }
        ), supportsOpacity: false)
    }
}
