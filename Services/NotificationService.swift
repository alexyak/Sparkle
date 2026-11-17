import Foundation
import UserNotifications
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Local notifications for chat turns that finish (or get cut off) while the
/// app is in the background.
@MainActor
enum NotificationService {
    /// Asks for permission the first time; a no-op once the user has answered.
    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Posts immediately, but only when the app isn't in the foreground.
    static func notifyIfBackgrounded(title: String, body: String) {
        #if os(macOS)
        guard !NSApplication.shared.isActive else { return }
        #else
        guard UIApplication.shared.applicationState != .active else { return }
        #endif
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(200))
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
