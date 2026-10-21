import SwiftUI

// Foldable iPhones (the iPhone Duo, iOS 27.1; D58). Closed, the outer screen
// is a compact-width iPhone; open, the inner one is regular width, so folding
// switches between the narrow and the wide layout (`AppModel.setWide`). The
// inner screen divides at the fold: iOS reports it as a "division" reserved
// region, and layouts that split in two put their divider there.

/// The hinge, as far as layouts care.
enum HingePosture: Equatable {
    case closed, partiallyOpen, fullyOpen
}

/// Where the screen folds, in a view's own coordinates.
struct Crease: Equatable {
    /// A vertical fold: the halves are side by side (else stacked).
    var sideBySide: Bool
    /// The fold with the margins the system keeps interactive content out of.
    var rect: CGRect
    /// The system's flag: bent, the fold matters; flat, it is barely visible.
    var active: Bool

    /// The lengths before the fold, of the fold, and after it along the split
    /// axis, if both sides are at least `minimum`. Flat, the fold is a hairline
    /// at its middle; bent, nothing goes in its margins.
    func sides(in size: CGSize, minimum: CGFloat) -> (before: CGFloat, gap: CGFloat, after: CGFloat)? {
        let length = sideBySide ? size.width : size.height
        let lo = sideBySide ? rect.minX : rect.minY
        let hi = sideBySide ? rect.maxX : rect.maxY
        let mid = (lo + hi) / 2
        let (a, b) = active && hi - lo > 1 ? (lo, hi) : (mid - 0.5, mid + 0.5)
        let before = max(0, a), after = max(0, length - b)
        guard before >= minimum, after >= minimum else { return nil }
        return (before, length - before - after, after)
    }
}

extension GeometryProxy {
    /// The fold that crosses this view from edge to edge, if any.
    var crease: Crease? {
        guard #available(iOS 27.1, *) else { return nil }
        let regions = reservedRegions(kind: .division, options: .includeInactive)
        for region in regions.sorted(by: { $0.isActive && !$1.isActive }) {
            let r = region.frame
            if r.minY <= 1, r.maxY >= size.height - 1, r.midX > 0, r.midX < size.width, r.width < size.width / 4 {
                return Crease(sideBySide: true, rect: r, active: region.isActive)
            }
            if r.minX <= 1, r.maxX >= size.width - 1, r.midY > 0, r.midY < size.height, r.height < size.height / 4 {
                return Crease(sideBySide: false, rect: r, active: region.isActive)
            }
        }
        return nil
    }
}

extension View {
    /// Calls `action` when the device's hinge moves (nil: no hinge, or the
    /// view left a hierarchy that has one).
    @ViewBuilder
    func onHinge(_ action: @escaping (HingePosture?) -> Void) -> some View {
        if #available(iOS 27.1, *) {
            onHingeChange { _, context in
                guard let hinge = context.hinge else { return action(nil) }
                action(hinge.status == .closed ? .closed : hinge.status == .partiallyOpen ? .partiallyOpen : .fullyOpen)
            }
        } else {
            self
        }
    }
}

/// What sits between two halves: a hairline, or on a bent fold, the fold's
/// margins with a hairline in the middle.
struct FoldGutter: View {
    let thickness: CGFloat
    let sideBySide: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if thickness > 1 { model.editorBackground }
            Rectangle()
                .fill(Color(.separator))
                .frame(width: sideBySide ? 1 : nil, height: sideBySide ? nil : 1)
        }
        .frame(width: sideBySide ? max(1, thickness) : nil, height: sideBySide ? nil : max(1, thickness))
    }
}

/// Whether the system shows a vertical bar (iOS 27.1): on the iPhone Duo it
/// takes the navigation bar's buttons to the side of the screen.
struct VerticalBarProbe: UIViewRepresentable {
    let changed: (Bool) -> Void

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.changed = changed
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.changed = changed
    }

    final class Probe: UIView {
        var changed: (Bool) -> Void = { _ in }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            if #available(iOS 27.1, *) {
                registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) { (probe: Probe, _: UITraitCollection) in
                    probe.report()
                }
            }
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        func report() {
            guard #available(iOS 27.1, *), window != nil else { return }
            let shown = traitCollection.verticalBarEdge != .unspecified
            DispatchQueue.main.async { self.changed(shown) }
        }
    }
}

/// A screen's buttons on the right of the navigation bar: packed into one item
/// on iPhone (the title needs the room), or separate items that go into the
/// vertical bar when the system shows one (iPhone Duo, D58).
struct TrailingButtons<Content: View>: ToolbarContent {
    let vertical: Bool
    @ViewBuilder var content: Content

    var body: some ToolbarContent {
        if vertical, #available(iOS 27.1, *) {
            ToolbarItemGroup(placement: .topBarTrailing) { content }
                .axisBehavior(.verticalPreferred)
        } else {
            ToolbarItem(placement: .topBarTrailing) { TightButtons { content } }
        }
    }
}

extension ToolbarContent {
    /// Keeps the items in their own bar at the top: a workspace half's agent,
    /// docs or ui app must not take the window's vertical bar from the
    /// workspace (D59).
    @ToolbarContentBuilder
    func horizontalOnly(_ on: Bool) -> some ToolbarContent {
        if on, #available(iOS 27.1, *) {
            axisBehavior(.horizontalOnly)
        } else {
            self
        }
    }
}
