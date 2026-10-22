import UIKit
import UserNotifications

/// Tar emot notiser: visar dem även när appen är öppen och öppnar rätt flik vid tryck.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let raw = response.notification.request.content.userInfo[Notifications.tabKey] as? String
        guard let tab = raw.flatMap(AppTab.init(rawValue:)) else { return }
        await MainActor.run { AppRouter.shared.selectedTab = tab }
    }
}
