import Foundation
import GrokGaugeCore
import UserNotifications

/// Posts one local notification per usage period when a pool crosses 80% and 90%.
/// Grok and Grok Bot are tracked independently.
@MainActor
final class UsageNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let thresholds = [90, 80]   // highest first

    private struct Source {
        let name: String
        let periodKey: String
        let levelKey: String
    }

    // Grok keeps its v0.1/v0.2 keys so an alert already sent this week isn't repeated.
    private static let grok = Source(name: "SuperGrok", periodKey: "notifications.periodKey",
                                     levelKey: "notifications.highestThreshold")
    private static let grokBot = Source(name: "Grok Bot", periodKey: "notifications.grokbot.periodKey",
                                        levelKey: "notifications.grokbot.highestThreshold")

    private let defaults = UserDefaults.standard
    private var center: UNUserNotificationCenter { .current() }

    func requestAuthorization() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func evaluate(_ snapshot: UsageSnapshot) {
        evaluate(Self.grok, percent: snapshot.percent, rounded: snapshot.roundedPercent,
                 period: snapshot.periodKey, poolName: "this \(snapshot.period.label.lowercased()) pool",
                 reset: snapshot.periodEnd)
    }

    func evaluate(_ snapshot: GrokBotSnapshot) {
        evaluate(Self.grokBot, percent: snapshot.percent, rounded: snapshot.roundedPercent,
                 period: snapshot.periodKey, poolName: "Grok Bot's weekly usage", reset: snapshot.nextReset)
    }

    private func evaluate(_ source: Source, percent: Double, rounded: Int, period: String, poolName: String, reset: Date?) {
        if defaults.string(forKey: source.periodKey) != period {
            defaults.set(period, forKey: source.periodKey)
            defaults.set(0, forKey: source.levelKey)
        }
        let alreadySent = defaults.integer(forKey: source.levelKey)
        guard let crossed = Self.thresholds.first(where: { percent >= Double($0) }),
              crossed > alreadySent else { return }
        defaults.set(crossed, forKey: source.levelKey)

        let content = UNMutableNotificationContent()
        content.title = crossed >= 90 ? "\(source.name) usage above 90%" : "\(source.name) usage passed 80%"
        var body = "You've used \(rounded)% of \(poolName)."
        if let reset { body += " It resets \(UsageFormat.resetDate(reset))." }
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "grokgauge.\(period).\(crossed)", content: content, trigger: nil)
        center.add(request)
    }

    // Show banners even though GrokGauge is technically "frontmost" while its popover is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
