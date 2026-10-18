import SwiftUI
import UserNotifications

/// Terrarium: a native SwiftUI app (D31). Python and code analysis run in a
/// web view without UI (the engine page), the editor is CodeMirror in one web
/// view per pane, and ui apps are native views (D30).
@main
struct TerrariumApp: App {
    init() {
        // Before launch finishes, so a tap on a notification that launched the app arrives (D40).
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
