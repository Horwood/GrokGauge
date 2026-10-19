import Foundation

// MARK: - Grok Bot on the shared SuperGrok pool
//
// Since mid-October 2026 Grok Bot's own "weekly usage" reading can describe the whole SuperGrok weekly pool
// (the same reset minute and about the same percent as the Grok billing reply). When that happens, showing
// Grok Bot's reading would just repeat the Grok ring, so the Grok Bot ring shows Grok Bot's *share* of the
// pool instead (the GrokBot product in "Grok by product"). If the two ever separate again, the ring goes back
// to Grok Bot's own allowance on its own.

/// How the Grok Bot ring gets its number.
public enum BotPoolMode: Equatable, Sendable {
    /// Grok Bot has its own allowance: the ring shows Grok Bot's own reading.
    case separate
    /// Grok Bot's reading is the shared Grok pool: the ring shows Grok Bot's share of it.
    case shared
}

public enum PoolSharing {
    /// Grok Bot's next reset and the pool's period end must be this close (seconds).
    public static let resetTolerance: TimeInterval = 120
    /// To start treating them as one pool, the two percents must be this close (points).
    public static let percentTolerance = 2.0
    /// Once a period is known to be shared, readings taken a few minutes apart may drift this far
    /// without flipping the ring back and forth.
    public static let stickyPercentTolerance = 6.0

    /// Product keys (normalized: lowercased, no "_"/spaces) for Grok Bot's and Cursor's share of the pool.
    public static let botProductKeys: Set<String> = ["grokbot", "bot"]
    public static let cursorProductKeys: Set<String> = ["cursor"]

    /// Whether Grok Bot's reading describes the same pool as the Grok billing reply.
    /// - `knownSharedEnd`: a pool end already seen as shared (keeps the decision steady within a week).
    public static func isShared(bot: GrokBotSnapshot, pool: UsageSnapshot, knownSharedEnd: Date? = nil) -> Bool {
        guard let botReset = bot.nextReset, let poolEnd = pool.periodEnd else { return false }
        guard abs(botReset.timeIntervalSince(poolEnd)) <= resetTolerance else { return false }
        let sticky = knownSharedEnd.map { abs($0.timeIntervalSince(poolEnd)) <= resetTolerance } ?? false
        let tolerance = sticky ? stickyPercentTolerance : percentTolerance
        return abs(bot.percent - pool.percent) <= tolerance
    }

    /// The pool's share for one of `keys` (nil when the reply has no such product).
    public static func share(_ keys: Set<String>, in pool: UsageSnapshot) -> ProductShare? {
        let matches = pool.products.filter { keys.contains(UsageParser.normalizedKey($0.key)) }
        guard let first = matches.first else { return nil }
        let total = matches.reduce(0) { $0 + $1.percent }
        return ProductShare(key: first.key, name: first.name, symbol: first.symbol, percent: total)
    }

    public static func botShare(in pool: UsageSnapshot) -> ProductShare? { share(botProductKeys, in: pool) }
    public static func cursorShare(in pool: UsageSnapshot) -> ProductShare? { share(cursorProductKeys, in: pool) }
}

/// What the Grok Bot ring shows right now, after deciding between Grok Bot's own allowance and its share
/// of the shared pool. `percent == nil` while the share isn't known yet.
public struct BotRingReading: Equatable, Sendable {
    public var mode: BotPoolMode
    public var percent: Double?
    public var nextReset: Date?
    /// When the number was read (Grok Bot's cache time, or the Grok fetch time for a share).
    public var readAt: Date
    /// Grok Bot's own reading (the whole pool when shared).
    public var own: GrokBotSnapshot

    public init(mode: BotPoolMode, percent: Double?, nextReset: Date?, readAt: Date, own: GrokBotSnapshot) {
        self.mode = mode
        self.percent = percent
        self.nextReset = nextReset
        self.readAt = readAt
        self.own = own
    }

    public var isShared: Bool { mode == .shared }

    public var roundedPercent: Int? {
        percent.map { p in
            let c = min(max(p, 0), 100)
            return c > 0 && c < 1 ? 1 : Int(c.rounded())
        }
    }

    public func timeUntilReset(now: Date = Date()) -> TimeInterval? {
        guard let end = nextReset else { return nil }
        return max(0, end.timeIntervalSince(now))
    }

    /// Alerts fire once per window; a share and an allowance never share a key.
    public var periodKey: String {
        let end = nextReset.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
        return (mode == .shared ? "botshare-" : "bot-") + end
    }

    /// Decides what the ring shows.
    /// - `pool`: the latest Grok billing snapshot (nil while loading or when Grok isn't signed in).
    /// - `knownSharedEnd`: the pool end last seen as shared (remembered across launches).
    /// - `poolLoading`: true while the first Grok fetch hasn't finished; with a remembered shared week the
    ///   ring waits for the share rather than briefly showing the whole pool.
    public static func make(bot: GrokBotSnapshot, pool: UsageSnapshot?, knownSharedEnd: Date?,
                            poolLoading: Bool = false) -> BotRingReading {
        if let pool, PoolSharing.isShared(bot: bot, pool: pool, knownSharedEnd: knownSharedEnd) {
            // No GrokBot product in the reply while the pool is shared means Grok Bot used none of it.
            let share = PoolSharing.botShare(in: pool)?.percent ?? 0
            return BotRingReading(mode: .shared, percent: share, nextReset: pool.periodEnd ?? bot.nextReset,
                                  readAt: pool.fetchedAt, own: bot)
        }
        if pool == nil, poolLoading, let known = knownSharedEnd, let reset = bot.nextReset,
           abs(known.timeIntervalSince(reset)) <= PoolSharing.resetTolerance {
            return BotRingReading(mode: .shared, percent: nil, nextReset: reset, readAt: bot.readAt, own: bot)
        }
        return BotRingReading(mode: .separate, percent: bot.percent, nextReset: bot.nextReset, readAt: bot.readAt, own: bot)
    }
}
