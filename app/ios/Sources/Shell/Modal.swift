import UIKit
import ObjectiveC

/// Presents and dismisses UIKit controllers without losing either to a
/// transition. UIKit ignores `present` on a controller that is being
/// presented or dismissed (or not in a window, as while a scene moves between
/// an iPhone Duo's screens), and `dismiss` while the controller is still
/// coming up: the dialog never shows, or never goes and takes every touch.
/// Seen with a program's dialogs answered right after they appeared. So both
/// wait for the transition to end, and a dismissal before the presentation
/// happened cancels it.
@MainActor
enum Modal {
    /// How long to wait for a place to present from (a window, no transition).
    static let patience: TimeInterval = 10

    /// Presents `controller` over the top-most controller of `presenter()`
    /// once nothing is moving there. `failed` is called if that never happens
    /// within `patience` (or the controller was dismissed before it showed).
    static func present(_ controller: UIViewController, from presenter: @escaping () -> UIViewController?,
                        failed: (() -> Void)? = nil) {
        state(controller).requested = Date()
        attempt(controller, presenter, failed)
    }

    /// Dismisses `controller` (and what it presents), now or when its
    /// transition ends; one that has not been presented yet never will be.
    static func dismiss(_ controller: UIViewController) {
        let s = state(controller)
        s.dismissRequested = true
        guard controller.presentingViewController != nil else { return }
        if controller.isBeingDismissed { return }
        if busy(controller) {
            afterTransition(of: controller) { dismiss(controller) }
            return
        }
        controller.dismiss(animated: true)
    }

    private static func attempt(_ controller: UIViewController, _ presenter: @escaping () -> UIViewController?, _ failed: (() -> Void)?) {
        let s = state(controller)
        if controller.presentingViewController != nil { return }
        if s.dismissRequested { failed?(); return }
        let waited = Date().timeIntervalSince(s.requested ?? Date())
        guard let top = presenter(), !busy(top), top.viewIfLoaded?.window != nil else {
            if waited > patience {
                Diagnostics.log.error("gave up presenting \(String(describing: type(of: controller)), privacy: .public) after \(Int(waited), privacy: .public) s")
                failed?()
                return
            }
            if let top = presenter(), top.transitionCoordinator != nil {
                afterTransition(of: top) { attempt(controller, presenter, failed) }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { attempt(controller, presenter, failed) }
            }
            return
        }
        if let popover = controller.popoverPresentationController, popover.sourceView == nil, popover.barButtonItem == nil {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true) {
            // Dismissed while it came up: now it can go.
            if state(controller).dismissRequested { dismiss(controller) }
        }
    }

    private static func busy(_ controller: UIViewController) -> Bool {
        controller.isBeingPresented || controller.isBeingDismissed || controller.transitionCoordinator != nil
            || controller.presentedViewController?.isBeingDismissed == true
    }

    private static func afterTransition(of controller: UIViewController, _ then: @escaping @MainActor () -> Void) {
        if let coordinator = controller.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { _ in DispatchQueue.main.async { then() } }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { then() }
        }
    }

    // MARK: per-controller state

    private final class State {
        var requested: Date?
        var dismissRequested = false
    }

    nonisolated(unsafe) private static var key: UInt8 = 0

    private static func state(_ controller: UIViewController) -> State {
        if let s = objc_getAssociatedObject(controller, &key) as? State { return s }
        let s = State()
        objc_setAssociatedObject(controller, &key, s, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return s
    }
}
