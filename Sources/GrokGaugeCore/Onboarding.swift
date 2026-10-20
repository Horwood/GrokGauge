import Foundation

/// The first-run welcome tour: its steps, when it shows, and the copy that depends on the user's settings.
public enum OnboardingStep: Int, CaseIterable, Sendable, Identifiable {
    case welcome, connect, rings, sharedPool, menuBar, settingsSync, historyPace, thanks

    public var id: Int { rawValue }
    public static var count: Int { allCases.count }
    /// 1-based, for "Step 3 of 8".
    public var number: Int { rawValue + 1 }
    public var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    public var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
    public var isFirst: Bool { previous == nil }
    public var isLast: Bool { next == nil }
    public var progressLabel: String { "Step \(number) of \(Self.count)" }

    public var title: String {
        switch self {
        case .welcome: return "Welcome to GrokGauge"
        case .connect: return "Connect to Grok"
        case .rings: return "The rings"
        case .sharedPool: return "The shared pool"
        case .menuBar: return "In your menu bar"
        case .settingsSync: return "Settings & sync"
        case .historyPace: return "History & pace"
        case .thanks: return OnboardingCopy.tipTitle
        }
    }

    /// SF Symbol shown at the top of the card.
    public var symbol: String {
        switch self {
        case .welcome: return "hand.wave.fill"
        case .connect: return "person.crop.circle.badge.checkmark"
        case .rings: return "circle.circle"
        case .sharedPool: return "chart.pie.fill"
        case .menuBar: return "menubar.rectangle"
        case .settingsSync: return "gearshape.2.fill"
        case .historyPace: return "chart.bar.xaxis"
        case .thanks: return "heart.fill"
        }
    }
}

/// When the tour opens by itself. It's stored per Mac (local UserDefaults, never the synced settings file),
/// so each Mac shows it once.
public enum OnboardingPolicy {
    public static let seenRevisionKey = "onboarding.seenRevision"
    /// Bump only when the tour changes enough to be worth one more automatic showing. Everything else
    /// (including app updates) leaves it alone; "Show Welcome Tour…" in the gear menu replays it anytime.
    public static let currentRevision = 1

    public static func shouldShowAutomatically(seenRevision: Int?, current: Int = currentRevision) -> Bool {
        guard let seen = seenRevision else { return true }
        return seen < current
    }

    /// Stored the moment the tour opens, so a quit or crash mid-tour never brings it back.
    public static func markSeen(in defaults: UserDefaults, revision: Int = currentRevision) {
        let old = defaults.object(forKey: seenRevisionKey) as? Int ?? 0
        if revision > old { defaults.set(revision, forKey: seenRevisionKey) }
    }
}

public enum OnboardingCopy {
    public static let tipTitle = "Enjoying GrokGauge?"
    public static let tipBody = "It's free, open source, and built in my spare time with plenty of AI tokens along the way. If it saves you a surprise or two, a small tip helps cover those costs and keeps the updates coming."
    public static let tipButton = "🙏 Tip on PayPal"
    public static let tipButtonSpoken = "Tip on PayPal"
    public static let laterButton = "Maybe later"
    public static let tipFootnote = "No pressure — GrokGauge stays free either way."

    /// The three color bands, from the user's own thresholds, e.g. "0–80%", "81–90%", "Above 90%".
    public static func levelRanges(_ t: LevelThresholds) -> [(level: UsageLevel, range: String)] {
        [(.normal, "0–\(t.warningAbove)%"),
         (.warning, "\(t.warningAbove + 1)–\(t.criticalAbove)%"),
         (.critical, "Above \(t.criticalAbove)%")]
    }

    /// VoiceOver wording for one band, e.g. "Warning: 81 to 90 percent".
    public static func spokenRange(_ level: UsageLevel, _ t: LevelThresholds) -> String {
        switch level {
        case .normal: return "Normal: up to \(t.warningAbove) percent"
        case .warning: return "Warning: \(t.warningAbove + 1) to \(t.criticalAbove) percent"
        case .critical: return "Critical: above \(t.criticalAbove) percent"
        }
    }

    public static func levelName(_ level: UsageLevel) -> String {
        switch level {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }

    /// The menu bar text for the user's current mode. Uses sample numbers when there's no reading yet.
    public static func menuBarExample(mode: MenuBarMode, grok: Int?, bot: Int?, hasGrokBot: Bool,
                                      thresholds: LevelThresholds, showDays: Bool = false,
                                      grokDays: Int? = nil, botDays: Int? = nil) -> [MenuBarSegment] {
        let g = grok ?? 42
        let b = hasGrokBot ? (bot ?? 27) : nil
        let effective = MenuBarLayout.effectiveMode(mode, hasGrokBot: hasGrokBot)
        return MenuBarLayout.segments(grok: g, bot: b, grokDays: grokDays ?? 3, botDays: botDays ?? 3,
                                      mode: effective, thresholds: thresholds, showDays: showDays)
    }
}
