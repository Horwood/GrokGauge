import Foundation
import GrokGaugeCore
import UserNotifications

/// Posts one local notification per usage period when a pool enters the warning and critical
/// levels. Levels follow the color boundaries unless notifications are unlinked in Settings.
/// Grok and Grok Bot are tracked independently.
@MainActor
final class UsageNotifier: NSObject, UNUserNotificationCenterDelegate {
    private struct Source {
        let name: String
        let periodKey: String
        let rankKey: String
        /// 0.1–0.3 stored the highest threshold sent (80 / 90) under this key.
        let legacyLevelKey: String
    }

    private static let grok = Source(name: "SuperGrok", periodKey: "notifications.periodKey",
                                     rankKey: "notifications.levelSent",
                                     legacyLevelKey: "notifications.highestThreshold")
    private static let grokBot = Source(name: "Grok Bot", periodKey: "notifications.grokbot.periodKey",
                                        rankKey: "notifications.grokbot.levelSent",
                                        legacyLevelKey: "notifications.grokbot.highestThreshold")

    private let defaults = UserDefaults.standard
    private var center: UNUserNotificationCenter { .current() }

    override init() {
        super.init()
        // Carry over "already alerted this period" from 0.3 so nobody gets a repeat after upgrading.
        for s in [Self.grok, Self.grokBot] where defaults.object(forKey: s.rankKey) == nil {
            let legacy = defaults.integer(forKey: s.legacyLevelKey)
            defaults.set(legacy >= 90 ? 2 : legacy >= 80 ? 1 : 0, forKey: s.rankKey)
        }
    }

    func requestAuthorization() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// One summary per What's new check (only when the user turned What's new notifications on).
    func postWhatsNew(_ items: [NewsItem]) {
        guard let first = items.first else { return }
        let content = UNMutableNotificationContent()
        content.title = "What's new from xAI"
        if items.count == 1 {
            content.body = first.title
        } else {
            let names = items.prefix(3).map(\.title).joined(separator: " · ")
            content.body = "\(items.count) updates: \(names)\(items.count > 3 ? " …" : "")"
        }
        let request = UNNotificationRequest(identifier: "grokgauge.whatsnew.\(first.id)", content: content, trigger: nil)
        center.add(request)
    }

    func evaluate(_ snapshot: UsageSnapshot, thresholds: LevelThresholds) {
        evaluate(Self.grok, rounded: snapshot.roundedPercent, thresholds: thresholds,
                 period: snapshot.periodKey, poolName: "this \(snapshot.period.label.lowercased()) pool",
                 reset: snapshot.periodEnd)
    }

    func evaluate(_ snapshot: GrokBotSnapshot, thresholds: LevelThresholds) {
        evaluate(Self.grokBot, rounded: snapshot.roundedPercent, thresholds: thresholds,
                 period: snapshot.periodKey, poolName: "Grok Bot's weekly usage", reset: snapshot.nextReset)
    }

    private func evaluate(_ source: Source, rounded: Int, thresholds: LevelThresholds, period: String,
                          poolName: String, reset: Date?) {
        if defaults.string(forKey: source.periodKey) != period {
            defaults.set(period, forKey: source.periodKey)
            defaults.set(0, forKey: source.rankKey)
        }
        let rank: Int
        switch thresholds.level(forRoundedPercent: rounded) {
        case .critical: rank = 2
        case .warning: rank = 1
        case .normal: rank = 0
        }
        guard rank > defaults.integer(forKey: source.rankKey) else { return }
        defaults.set(rank, forKey: source.rankKey)

        let content = UNMutableNotificationContent()
        content.title = rank == 2
            ? "\(source.name) usage above \(thresholds.criticalAbove)%"
            : "\(source.name) usage passed \(thresholds.warningAbove)%"
        var body = "You've used \(rounded)% of \(poolName)."
        if let reset { body += " It resets \(UsageFormat.resetDate(reset))." }
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "grokgauge.\(source.name).\(period).\(rank)", content: content, trigger: nil)
        center.add(request)
    }

    // Show banners even though GrokGauge is technically "frontmost" while its popover is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
