import Foundation
import UserNotifications

/// Lokala notiser: coachens fråga efter ett pass och påminnelse om söndagens veckoplan.
enum Notifications {
    /// Nyckel i `userInfo` som anger vilken flik notisen ska öppna.
    static let tabKey = "tab"
    private static let weeklyPlanID = "weekly-plan"

    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func notifyCoachCheckin() async {
        let content = UNMutableNotificationContent()
        content.title = "Snyggt pass!"
        content.body = "Coachen har en fråga om hur det kändes."
        content.sound = .default
        content.userInfo = [tabKey: AppTab.coach.rawValue]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Söndagar 19:30 – planen skapas på servern strax innan (18:00 vintertid, 19:00 sommartid).
    static func updateWeeklyPlanReminder(enabled: Bool) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [weeklyPlanID])
        guard enabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "Ny veckoplan"
        content.body = "Din plan för nästa vecka är klar – ta en titt."
        content.sound = .default
        content.userInfo = [tabKey: AppTab.plan.rawValue]

        var components = DateComponents()
        components.weekday = 1 // söndag
        components.hour = 19
        components.minute = 30
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        try? await center.add(UNNotificationRequest(identifier: weeklyPlanID, content: content, trigger: trigger))
    }
}
