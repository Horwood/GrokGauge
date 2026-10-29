import Foundation

// MARK: - Recent burn
//
// `Pace.project` divides the percent by the whole week so far. A heavy Monday then keeps warning that
// you'll run out on Thursday, and a binge that starts Friday night stays quiet until that average catches up.
// The history samples already know better. This is the slope over the last day and a half, measured after
// the last real drop (a weekly reset), and only when the two ends are a few hours apart. Callers that
// don't have samples yet keep the week-average projection.

public struct BurnRate: Equatable, Sendable {
    /// Percent per second. Zero or negative: the pool wasn't climbing in the window.
    public var perSecond: Double
    public var span: TimeInterval
    /// Last reading minus the first, over `span`.
    public var climbed: Double
    /// Fraction of `climbed` (0...1). Nil when that slice couldn't be measured against the pool.
    public var grok: Double?
    public var grokBot: Double?
    public var cursor: Double?
    /// One slice accounted for at least half the climb. Nil on a tie or when the split isn't trustworthy.
    public var leader: String?

    public init(perSecond: Double, span: TimeInterval, climbed: Double, grok: Double? = nil,
                grokBot: Double? = nil, cursor: Double? = nil, leader: String? = nil) {
        self.perSecond = perSecond
        self.span = span
        self.climbed = climbed
        self.grok = grok
        self.grokBot = grokBot
        self.cursor = cursor
        self.leader = leader
    }
}

public enum Burn {
    /// Long enough that one sitting doesn't decide the week, short enough that Monday doesn't.
    public static let window: TimeInterval = 36 * 3600
    /// Two refreshes an hour apart aren't a slope.
    public static let minimumSpan: TimeInterval = 3 * 3600
    /// Smaller climbs are noise; don't name a culprit.
    public static let minimumClimb = 1.0
    /// Bigger than a wobble, smaller than a normal afternoon. A drop past this starts a new segment.
    public static let resetDrop = 15.0

    /// - `current`: the live pool percent, counted even if it hasn't been written into history yet.
    public static func recent(history: UsageHistory, periodStart: Date, now: Date = Date(), current: Double? = nil,
                             window: TimeInterval = Burn.window, minimumSpan: TimeInterval = Burn.minimumSpan) -> BurnRate? {
        var samples = history.grok.filter { $0.t >= periodStart && $0.t <= now.addingTimeInterval(120) && $0.p.isFinite }
        if let current, current.isFinite {
            samples.append(UsageSample(t: now, p: max(0, current)))
        }
        samples.sort { $0.t < $1.t }
        let segment = latestSegment(samples)
        let cutoff = now.addingTimeInterval(-window)
        let inWindow = segment.filter { $0.t >= cutoff }
        guard let first = inWindow.first, let last = inWindow.last else { return nil }
        let span = last.t.timeIntervalSince(first.t)
        guard span >= minimumSpan else { return nil }
        let climbed = last.p - first.p
        let perSecond = climbed / span

        var grok: Double?
        var grokBot: Double?
        var cursor: Double?
        if climbed >= minimumClimb {
            grokBot = fraction(rise(history.grokBot.filter(\.isShare), from: first.t, to: last.t), of: climbed)
            cursor = fraction(rise(history.cursor, from: first.t, to: last.t), of: climbed)
            if let grokBot, let cursor {
                grok = max(0, min(1, 1 - grokBot - cursor))
            }
        }
        return BurnRate(perSecond: perSecond, span: span, climbed: climbed, grok: grok, grokBot: grokBot,
                        cursor: cursor, leader: leader(grok: grok, grokBot: grokBot, cursor: cursor))
    }

    /// Everything before the last big drop is the previous week.
    static func latestSegment(_ samples: [UsageSample]) -> [UsageSample] {
        guard !samples.isEmpty else { return [] }
        var start = 0
        for i in 1..<samples.count where samples[i - 1].p - samples[i].p > resetDrop {
            start = i
        }
        return Array(samples[start...])
    }

    /// How many points this slice rose between the same two moments as the pool. Nil if it didn't have
    /// two readings, or rose by more than the pool (then it isn't the same measurement).
    static func rise(_ samples: [UsageSample], from: Date, to: Date) -> Double? {
        let list = latestSegment(samples.filter { $0.t >= from && $0.t <= to && $0.p.isFinite }.sorted { $0.t < $1.t })
        guard let a = list.first, let b = list.last, b.t > a.t else { return nil }
        return max(0, b.p - a.p)
    }

    static func fraction(_ rise: Double?, of climb: Double) -> Double? {
        guard let rise, climb > 0, rise <= climb * 1.15 else { return nil }
        return min(1, rise / climb)
    }

    static func leader(grok: Double?, grokBot: Double?, cursor: Double?) -> String? {
        let known: [(String, Double)] = [("Grok", grok), ("Grok Bot", grokBot), ("Cursor", cursor)].compactMap { name, value in
            value.map { (name, $0) }
        }
        guard let top = known.max(by: { $0.1 < $1.1 }), top.1 >= 0.5 else { return nil }
        let ties = known.filter { $0.1 >= 0.5 && abs($0.1 - top.1) < 0.02 }
        return ties.count == 1 ? top.0 : nil
    }
}
