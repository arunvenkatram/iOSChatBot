import SwiftUI
import UserNotifications

private final class ReplyNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReplyNotificationDelegate()

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@main
struct MyApp: App {
    init() {
        UNUserNotificationCenter.current().delegate = ReplyNotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
