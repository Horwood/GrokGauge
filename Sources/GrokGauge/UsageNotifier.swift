import Foundation
import GrokGaugeCore
import UserNotifications

/// Posts one local notification per usage period when the pool crosses 80% and 90%.
@MainActor
final class UsageNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let thresholds = [90, 80]   // highest first

    private let defaults = UserDefaults.standard
    private let periodKey = "notifications.periodKey"
    private let levelKey = "notifications.highestThreshold"

    private var center: UNUserNotificationCenter { .current() }

    func requestAuthorization() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func evaluate(_ snapshot: UsageSnapshot) {
        if defaults.string(forKey: periodKey) != snapshot.periodKey {
            defaults.set(snapshot.periodKey, forKey: periodKey)
            defaults.set(0, forKey: levelKey)
        }
        let alreadySent = defaults.integer(forKey: levelKey)
        guard let crossed = Self.thresholds.first(where: { snapshot.percent >= Double($0) }),
              crossed > alreadySent else { return }
        defaults.set(crossed, forKey: levelKey)
        post(threshold: crossed, snapshot: snapshot)
    }

    private func post(threshold: Int, snapshot: UsageSnapshot) {
        let content = UNMutableNotificationContent()
        content.title = threshold >= 90 ? "SuperGrok usage above 90%" : "SuperGrok usage passed 80%"
        var body = "You've used \(snapshot.roundedPercent)% of this \(snapshot.period.label.lowercased()) pool."
        if let end = snapshot.periodEnd {
            body += " It resets \(UsageFormat.resetDate(end))."
        }
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "grokgauge.\(snapshot.periodKey).\(threshold)", content: content, trigger: nil)
        center.add(request)
    }

    // Show banners even though GrokGauge is technically "frontmost" while its popover is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
