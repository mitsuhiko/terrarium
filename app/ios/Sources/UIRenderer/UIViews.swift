import SwiftUI

// Views for ui.py elements. Every element is a NodeView: the element's own
// view plus the modifiers every element takes (padding, frame, background,
// border, shadow, opacity, color, tint, ...). Layout context travels in the
// environment: whether the parent is a list, which way it stacks, and whether
// it stretches its children (VStack's default "stretch" alignment).

enum UIContext {
    case plain, list, toolbar
}

extension EnvironmentValues {
    @Entry var uiContext: UIContext = .plain
    /// The axis of the parent stack (for flex and fixed spacers).
    @Entry var uiAxis: Axis? = nil
    /// The parent stretches children to its width (VStack align="stretch", list rows).
    @Entry var uiStretch: Bool = false
    /// The element should fill the width it is given (buttons stretch their label).
    @Entry var uiFillWidth: Bool = false
    /// The screen is the first one of the app: it gets the close button.
    @Entry var uiAppRoot: Bool = false
    /// The app runs in a half of the wide workspace (D59): its bar buttons stay in its own bar.
    @Entry var uiInHalf: Bool = false
    /// Full screen, or back next to the code (the close button's menu, D59).
    @Entry var uiSizeToggle: UISizeToggle?
    /// font_size set on a container: body text inside uses it.
    @Entry var uiBodySize: Double? = nil
}

struct NodeView: View {
    let node: UINode
    @Environment(\.uiAxis) private var axis
    @Environment(\.uiStretch) private var stretch

    var body: some View {
        if !node.bool("hidden") {
            let fills = fillsWidth
            ElementView(node: node, parentAxis: axis)
                .environment(\.uiAxis, nil)
                .environment(\.uiStretch, false)
                .environment(\.uiFillWidth, fills)
                .modifier(CommonModifiers(node: node, axis: axis, stretch: stretch && !hasFixedWidth))
        }
    }

    private var hasFixedWidth: Bool { node.props["width"]?.double != nil }

    private var fillsWidth: Bool {
        if node.props["width"]?.string == "fill" { return true }
        if node.has("flex") && axis == .horizontal { return true }
        return stretch && !hasFixedWidth
    }
}

/// The children of a node, each as a NodeView.
struct Children: View {
    let node: UINode
    var body: some View {
        ForEach(node.children) { NodeView(node: $0) }
    }
}

/// Defaults some elements have for the common modifiers (overridden by props).
private enum ElementDefaults {
    static func padding(_ type: String) -> JSONValue? {
        type == "Card" ? .number(16) : nil
    }
    static func background(_ type: String) -> String? {
        type == "Card" ? "secondary_background" : nil
    }
    static func cornerRadius(_ type: String) -> Double? {
        type == "Card" ? 14 : nil
    }
}

func edgeInsets(_ v: JSONValue?) -> EdgeInsets {
    guard let v else { return EdgeInsets() }
    if let a = v.array?.compactMap(\.double) {
        if a.count == 2 { return EdgeInsets(top: a[0], leading: a[1], bottom: a[0], trailing: a[1]) }
        if a.count == 4 { return EdgeInsets(top: a[0], leading: a[3], bottom: a[2], trailing: a[1]) }
        return EdgeInsets()
    }
    let n = v.double ?? 0
    return EdgeInsets(top: n, leading: n, bottom: n, trailing: n)
}

struct CommonModifiers: ViewModifier {
    let node: UINode
    let axis: Axis?
    let stretch: Bool
    @Environment(UIStore.self) private var store

    func body(content: Content) -> some View {
        let p = node.props
        let type = node.type
        let radius = p["corner_radius"]?.double ?? ElementDefaults.cornerRadius(type) ?? 0
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let background = UIColorParser.color(node.string("background") ?? ElementDefaults.background(type))
        let border = p["border"]?.array
        let shadow = p["shadow"]?.double
        let flex = node.has("flex")
        let widthFill = p["width"]?.string == "fill" || p["max_width"]?.string == "fill"
            || (flex && axis == .horizontal) || stretch
        let heightFill = p["height"]?.string == "fill" || p["max_height"]?.string == "fill" || (flex && axis == .vertical)
        let align: Alignment = switch node.string("text_align") {
        case "center": .center
        case "trailing": .trailing
        case "leading": .leading
        default: type == "Canvas" || type == "Image" ? .center : .leading
        }

        content
            .modifier(TextStyleModifier(node: node))
            .padding(edgeInsets(p["padding"] ?? ElementDefaults.padding(type)))
            .frame(width: p["width"]?.double.map { CGFloat($0) }, height: p["height"]?.double.map { CGFloat($0) })
            .frame(
                minWidth: p["min_width"]?.double.map { CGFloat($0) },
                maxWidth: widthFill ? .infinity : p["max_width"]?.double.map { CGFloat($0) },
                minHeight: p["min_height"]?.double.map { CGFloat($0) },
                maxHeight: heightFill ? .infinity : p["max_height"]?.double.map { CGFloat($0) },
                alignment: align
            )
            .background(background ?? .clear, in: shape)
            .modifier(ClipModifier(radius: radius))
            .overlay {
                if let border, border.count == 2, let width = border[0].double {
                    shape.strokeBorder(UIColorParser.color(border[1].string) ?? .primary, lineWidth: width)
                }
            }
            .shadow(color: .black.opacity(shadow == nil ? 0 : 0.14), radius: (shadow ?? 0) / 2, y: shadow == nil ? 0 : 2)
            .opacity(p["opacity"]?.double ?? 1)
            .padding(edgeInsets(p["margin"]))
            .disabled(node.bool("disabled"))
            .tint(UIColorParser.color(node.string("tint")))
            .modifier(TapModifier(node: node, store: store))
            .modifier(AccessibilityModifier(label: node.string("a11y")))
    }
}

/// color, font_size and font_weight, inherited by what is inside.
private struct TextStyleModifier: ViewModifier {
    let node: UINode

    func body(content: Content) -> some View {
        let color = UIColorParser.color(node.string("color"))
        let size = node.double("font_size")
        let weight = UIFonts.weight(node.double("font_weight"))
        let isText = node.type == "Text"
        Group {
            if let color { content.foregroundStyle(color) } else { content }
        }
        .environment(\.uiBodySize, isText ? nil : size)
        .modifier(OptionalFont(size: isText ? nil : size, weight: isText ? nil : weight))
    }
}

private struct OptionalFont: ViewModifier {
    let size: Double?
    let weight: Font.Weight?
    func body(content: Content) -> some View {
        if let size {
            content.font(.system(size: size, weight: weight ?? .regular))
        } else if let weight {
            content.fontWeight(weight)
        } else {
            content
        }
    }
}

private struct ClipModifier: ViewModifier {
    let radius: Double
    func body(content: Content) -> some View {
        if radius > 0 {
            content.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content
        }
    }
}

private struct AccessibilityModifier: ViewModifier {
    let label: String?
    func body(content: Content) -> some View {
        if let label { content.accessibilityLabel(label) } else { content }
    }
}

/// on_click on elements that don't handle taps themselves (a Card, an Image, a stack).
private struct TapModifier: ViewModifier {
    let node: UINode
    let store: UIStore
    private static let handlesClick: Set<String> = ["Button", "Row", "Link", "Toggle", "TextField", "TextArea"]

    func body(content: Content) -> some View {
        if node.has("on_click") && !Self.handlesClick.contains(node.type) {
            content
                .contentShape(Rectangle())
                .onTapGesture { store.emit(node, "click", [["type": "click"]]) }
                .accessibilityAddTraits(.isButton)
        } else {
            content
        }
    }
}

// MARK: - elements

struct ElementView: View {
    let node: UINode
    let parentAxis: Axis?

    var body: some View {
        switch node.type {
        case "#text": Text(node.string("text") ?? "")
        case "Text": TextNode(node: node)
        case "VStack": StackNode(node: node, axis: .vertical)
        case "HStack": StackNode(node: node, axis: .horizontal)
        case "ZStack": ZStackNode(node: node)
        case "Grid": GridNode(node: node)
        case "ScrollView": ScrollNode(node: node)
        case "Spacer": SpacerNode(node: node, axis: parentAxis)
        case "Divider": Divider()
        case "Card": CardNode(node: node)
        case "Screen": ScreenView(node: node)
        case "NavigationStack": NavStackNode(node: node)
        case "TabView": TabViewNode(node: node)
        case "Tab": PlainStack(node: node)
        case "Toolbar", "Sheet": EmptyView()
        case "Section": PlainSection(node: node)
        case "Row": RowNode(node: node)
        case "Label": LabelNode(node: node)
        case "Icon": IconImage(name: node.string("name") ?? "", size: node.double("size"))
        case "Image": ImageNode(node: node)
        case "ProgressView": ProgressNode(node: node)
        case "Link": LinkNode(node: node)
        case "Canvas": CanvasNode(node: node)
        case "Button": ButtonNode(node: node)
        case "TextField": TextFieldNode(node: node)
        case "TextArea": TextAreaNode(node: node)
        case "Toggle": ToggleNode(node: node)
        case "Slider": SliderNode(node: node)
        case "Stepper": StepperNode(node: node)
        case "Picker": PickerNode(node: node)
        case "DatePicker": DatePickerNode(node: node)
        case "ColorPicker": ColorPickerNode(node: node)
        default: Text("unknown element \(node.type)").foregroundStyle(.red)
        }
    }
}

struct TextNode: View {
    let node: UINode
    @Environment(\.uiBodySize) private var bodySize

    var body: some View {
        let style = UIFonts.style(node.string("font"))
        let mono = node.bool("mono")
        let design: Font.Design = mono ? .monospaced : .default
        let weight = UIFonts.weight(node.double("font_weight")) ?? (node.bool("bold") ? .bold : nil)
        let size = node.double("font_size") ?? (style == .body ? bodySize : nil)
        let font: Font = if let size {
            .system(size: size, weight: weight ?? .regular, design: design)
        } else {
            .system(style, design: design, weight: weight)
        }
        let align: TextAlignment = switch node.string("text_align") {
        case "center": .center
        case "trailing": .trailing
        default: .leading
        }
        let text = Text(node.string("text") ?? "")
            .font(font)
            .italic(node.bool("italic"))
            .lineLimit(node.props["lines"]?.int)
            .multilineTextAlignment(align)
        if node.bool("selectable") {
            text.textSelection(.enabled)
        } else {
            text
        }
    }
}

struct StackNode: View {
    let node: UINode
    let axis: Axis

    var body: some View {
        let spacing = CGFloat(node.double("spacing") ?? 8)
        let align = node.string("align")
        let justify = node.string("justify")
        if axis == .vertical {
            VStack(alignment: horizontal(align), spacing: spacing) {
                Justified(node: node, justify: justify)
            }
            .environment(\.uiAxis, .vertical)
            .environment(\.uiStretch, align == nil || align == "stretch")
        } else if node.bool("wrap") {
            FlowLayout(spacing: spacing) { Children(node: node) }
                .environment(\.uiAxis, .horizontal)
        } else {
            HStack(alignment: vertical(align), spacing: spacing) {
                Justified(node: node, justify: justify)
            }
            .environment(\.uiAxis, .horizontal)
        }
    }

    private func horizontal(_ align: String?) -> HorizontalAlignment {
        switch align {
        case "center": .center
        case "trailing", "end": .trailing
        default: .leading
        }
    }

    private func vertical(_ align: String?) -> VerticalAlignment {
        switch align {
        case "top", "start": .top
        case "bottom", "end": .bottom
        case "baseline": .firstTextBaseline
        default: .center
        }
    }
}

/// Children with spacers for HStack/VStack's `justify`.
private struct Justified: View {
    let node: UINode
    let justify: String?

    var body: some View {
        switch justify {
        case "end", "trailing", "bottom":
            Spacer(minLength: 0)
            Children(node: node)
        case "center":
            Spacer(minLength: 0)
            Children(node: node)
            Spacer(minLength: 0)
        case "between", "around", "evenly":
            if justify != "between" { Spacer(minLength: 0) }
            ForEach(Array(node.children.enumerated()), id: \.element.id) { i, child in
                if i > 0 { Spacer(minLength: 0) }
                NodeView(node: child)
            }
            if justify != "between" { Spacer(minLength: 0) }
        default:
            Children(node: node)
        }
    }
}

/// Lays children out in rows, wrapping when a row is full (HStack(wrap=True)).
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty && rows[rows.count - 1].width + spacing + size.width > maxWidth {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

struct ZStackNode: View {
    let node: UINode
    var body: some View {
        let alignment: Alignment = switch node.string("align") {
        case "top": .top
        case "bottom": .bottom
        case "leading": .leading
        case "trailing": .trailing
        default: .center
        }
        ZStack(alignment: alignment) { Children(node: node) }
    }
}

struct GridNode: View {
    let node: UINode
    var body: some View {
        let spacing = CGFloat(node.double("spacing") ?? 8)
        let columns: [GridItem] = if let min = node.double("min") {
            [GridItem(.adaptive(minimum: min), spacing: spacing)]
        } else {
            Array(repeating: GridItem(.flexible(), spacing: spacing), count: max(1, node.props["columns"]?.int ?? 2))
        }
        LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
            Children(node: node)
        }
        .environment(\.uiStretch, true)
    }
}

struct ScrollNode: View {
    let node: UINode
    var body: some View {
        let spacing = CGFloat(node.double("spacing") ?? 8)
        if node.string("axis") == "horizontal" {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) { Children(node: node) }
                    .environment(\.uiAxis, .horizontal)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: spacing) { Children(node: node) }
                    .environment(\.uiAxis, .vertical)
                    .environment(\.uiStretch, true)
            }
        }
    }
}

struct SpacerNode: View {
    let node: UINode
    let axis: Axis?
    var body: some View {
        if let size = node.double("size") {
            Color.clear.frame(width: axis == .horizontal ? size : nil, height: axis == .vertical ? size : nil)
        } else {
            Spacer(minLength: 0)
        }
    }
}

struct CardNode: View {
    let node: UINode
    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat(node.double("spacing") ?? 8)) {
            Children(node: node)
        }
        .environment(\.uiAxis, .vertical)
        .environment(\.uiStretch, true)
    }
}

/// A container's children top to bottom (a Tab outside a TabView).
struct PlainStack: View {
    let node: UINode
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { Children(node: node) }
            .environment(\.uiAxis, .vertical)
            .environment(\.uiStretch, true)
    }
}

/// A Section that is not directly in a screen's list: a rounded group.
struct PlainSection: View {
    let node: UINode
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header = node.string("header"), !header.isEmpty {
                Text(header.uppercased()).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(node.children.enumerated()), id: \.element.id) { i, child in
                    if i > 0 { Divider().padding(.leading, 16) }
                    NodeView(node: child)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                }
            }
            .environment(\.uiContext, .list)
            .environment(\.uiStretch, true)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let footer = node.string("footer"), !footer.isEmpty {
                Text(footer).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
            }
        }
    }
}

struct RowNode: View {
    let node: UINode
    @Environment(UIStore.self) private var store

    var body: some View {
        let checked = node.props["checked"].flatMap { $0.isNull ? nil : $0.truthy }
        let title = node.string("title")
        let subtitle = node.string("subtitle")
        let detail = node.string("detail")
        HStack(spacing: 12) {
            if let checked {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .contentShape(Rectangle())
                    .onTapGesture { store.emit(node, node.has("on_check") ? "check" : "click") }
                    .accessibilityLabel(checked ? "Done" : "Not done")
                    .accessibilityAddTraits(.isButton)
            }
            if let icon = node.string("icon") {
                IconImage(name: icon).foregroundStyle(.tint).frame(width: 26)
            }
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let title, !title.isEmpty {
                        Text(title).foregroundStyle(checked == true ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    }
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            Children(node: node)
            Spacer(minLength: 0)
            if let detail, !detail.isEmpty {
                Text(detail).foregroundStyle(.secondary)
            }
            if let accessory = node.string("accessory") {
                switch accessory {
                case "chevron":
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                case "check":
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                case "info":
                    Image(systemName: "info.circle").foregroundStyle(.tint)
                default:
                    IconImage(name: accessory).foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if node.has("on_click") { store.emit(node, "click") }
        }
        .accessibilityAddTraits(node.has("on_click") ? .isButton : [])
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if node.has("on_delete") {
                Button(role: .destructive) { store.emit(node, "delete") } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}

struct LabelNode: View {
    let node: UINode
    var body: some View {
        if let icon = node.string("icon") {
            Label { Text(node.string("text") ?? "") } icon: { IconImage(name: icon) }
        } else {
            Text(node.string("text") ?? "")
        }
    }
}

struct ImageNode: View {
    let node: UINode

    var body: some View {
        let src = node.string("src") ?? ""
        let fit = node.string("fit") ?? "contain"
        if src.hasPrefix("data:") {
            if let image = decoded(src) {
                sized(Image(uiImage: image).resizable(), fit: fit, natural: image.size)
            }
        } else if let url = URL(string: src), url.scheme == "http" || url.scheme == "https" {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    sized(image.resizable(), fit: fit, natural: nil)
                } else if phase.error != nil {
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                } else {
                    ProgressView()
                }
            }
        } else if !src.isEmpty {
            Image(systemName: "photo").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func sized(_ image: Image, fit: String, natural: CGSize?) -> some View {
        switch fit {
        case "cover":
            image.scaledToFill().clipped()
        case "fill":
            image
        default:
            image.scaledToFit().frame(maxWidth: natural?.width)
        }
    }

    private func decoded(_ src: String) -> UIImage? {
        if let cached = node.imageCache, cached.src == src { return cached.image }
        guard let comma = src.firstIndex(of: ","),
              let data = Data(base64Encoded: String(src[src.index(after: comma)...]), options: .ignoreUnknownCharacters),
              let image = UIImage(data: data, scale: 2)
        else { return nil }
        node.imageCache = (src, image)
        return image
    }
}

struct ProgressNode: View {
    let node: UINode
    var body: some View {
        let label = node.string("label")
        if let value = node.double("value") {
            ProgressView(value: min(max(value, 0), 1)) {
                if let label { Text(label) }
            }
        } else {
            ProgressView {
                if let label { Text(label) }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct LinkNode: View {
    let node: UINode
    var body: some View {
        let text = node.string("text") ?? ""
        if let url = URL(string: node.string("url") ?? "") {
            Link(text, destination: url)
        } else {
            Text(text)
        }
    }
}

/// Switches a ui app between full screen and a half of the wide workspace (D59).
struct UISizeToggle {
    let title: String
    let symbol: String
    let action: () -> Void
}
