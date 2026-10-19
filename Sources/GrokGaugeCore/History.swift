import Foundation

public enum HistorySource: String, Codable, CaseIterable, Sendable {
    /// The Grok ring (the whole SuperGrok weekly pool).
    case grok
    /// The Grok Bot ring: Grok Bot's own allowance, or its share of the shared pool (see `UsageSample.s`).
    case grokBot
    /// The optional Cursor ring: Cursor's share of the Grok pool (added in 0.9.3).
    case cursor
}

public struct UsageSample: Codable, Equatable, Sendable {
    public var t: Date
    public var p: Double
    /// Grok Bot samples only (0.9.3+): true when `p` is Grok Bot's share of the shared Grok pool, false when
    /// it's Grok Bot's own allowance. nil for older files and other sources (read as "own allowance").
    public var s: Bool?
    public init(t: Date, p: Double, s: Bool? = nil) {
        self.t = t
        self.p = p
        self.s = s
    }

    var isShare: Bool { s ?? false }
}

/// This Mac's usage samples for the 7-day graphs. Stored in
/// `~/Library/Application Support/GrokGauge/history.json`. With "Sync history across Macs" on, a copy goes to
/// `<sync folder>/GrokGauge/history/<machine-id>.json` and the graphs show every Mac's samples merged
/// (see `HistorySync`).
public struct UsageHistory: Codable, Equatable, Sendable {
    public static let keep: TimeInterval = 8 * 86_400
    public static let maxSamplesPerSource = 1_500
    /// A new sample with the same value is skipped unless this much time passed.
    public static let minSpacing: TimeInterval = 30 * 60

    public var schema = 1
    public var grok: [UsageSample] = []
    public var grokBot: [UsageSample] = []
    /// Added in 0.9.3; missing from older files (read as empty).
    public var cursor: [UsageSample] = []

    public init() {}

    enum CodingKeys: String, CodingKey { case schema, grok, grokBot, cursor }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = (try? c.decodeIfPresent(Int.self, forKey: .schema)) ?? 1
        grok = try c.decodeIfPresent([UsageSample].self, forKey: .grok) ?? []
        grokBot = try c.decodeIfPresent([UsageSample].self, forKey: .grokBot) ?? []
        cursor = (try? c.decodeIfPresent([UsageSample].self, forKey: .cursor)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(grok, forKey: .grok)
        try c.encode(grokBot, forKey: .grokBot)
        if !cursor.isEmpty { try c.encode(cursor, forKey: .cursor) }
    }

    public func samples(_ source: HistorySource) -> [UsageSample] {
        switch source {
        case .grok: return grok
        case .grokBot: return grokBot
        case .cursor: return cursor
        }
    }

    private mutating func set(_ source: HistorySource, _ value: [UsageSample]) {
        switch source {
        case .grok: grok = value
        case .grokBot: grokBot = value
        case .cursor: cursor = value
        }
    }

    /// Adds a sample, keeping the list sorted and skipping redundant points.
    /// `shared` (Grok Bot only): whether the percent is Grok Bot's share of the shared pool.
    public mutating func record(_ source: HistorySource, percent: Double, at time: Date, shared: Bool? = nil) {
        guard percent.isFinite else { return }
        var list = samples(source)
        if let last = list.last {
            if time == last.t { return }
            if time > last.t, abs(last.p - percent) < 0.005, last.s == shared,
               time.timeIntervalSince(last.t) < Self.minSpacing { return }
        }
        let sample = UsageSample(t: time, p: max(0, percent), s: shared)
        if let i = list.firstIndex(where: { $0.t > time }) { list.insert(sample, at: i) } else { list.append(sample) }
        set(source, list)
    }

    /// Drops samples older than `keep` (and anything from the future), and caps the count.
    public mutating func prune(now: Date = Date()) {
        for source in HistorySource.allCases {
            var list = samples(source).filter { $0.t >= now.addingTimeInterval(-Self.keep) && $0.t <= now.addingTimeInterval(300) }
            if list.count > Self.maxSamplesPerSource { list.removeFirst(list.count - Self.maxSamplesPerSource) }
            set(source, list)
        }
    }

    /// Samples inside the last `window` seconds, for drawing.
    public func series(_ source: HistorySource, now: Date = Date(), window: TimeInterval = 7 * 86_400) -> [UsageSample] {
        samples(source).filter { $0.t >= now.addingTimeInterval(-window) && $0.t <= now.addingTimeInterval(300) }
    }

    /// One entry per calendar day for the bar graph, oldest first, ending with today.
    /// - `current`: the live reading, counted for today even if it wasn't recorded yet.
    /// - `knownResets`: reset times the app knows (e.g. the current period's start).
    public func daily(_ source: HistorySource, days: Int = 7, now: Date = Date(), current: Double? = nil,
                      currentShared: Bool? = nil, knownResets: [Date] = [], calendar: Calendar = .current) -> [DailyUsage] {
        var list = series(source, now: now, window: Double(days + 1) * 86_400)
        if let current, current.isFinite { list.append(UsageSample(t: now, p: max(0, current), s: currentShared)) }
        return DailyUsage.aggregate(list, days: days, now: now, knownResets: knownResets, calendar: calendar)
    }

    // MARK: Disk

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("GrokGauge", isDirectory: true).appendingPathComponent("history.json")
    }

    public static func load(from url: URL = defaultURL) -> UsageHistory {
        guard let data = try? Data(contentsOf: url) else { return UsageHistory() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return (try? d.decode(UsageHistory.self, from: data)) ?? UsageHistory()
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        try e.encode(self).write(to: url, options: [.atomic])
    }
}

/// The peak usage reached on one calendar day.
public struct DailyUsage: Equatable, Sendable {
    /// Start of the day (in the calendar's time zone).
    public var day: Date
    /// Highest percent recorded that day; nil when there's no reading for the day.
    public var peak: Double?
    /// The weekly allowance reset during this day (the bar still shows the highest % reached that day).
    public var reset: Bool
    public var isToday: Bool

    public init(day: Date, peak: Double?, reset: Bool, isToday: Bool) {
        self.day = day
        self.peak = peak
        self.reset = reset
        self.isToday = isToday
    }

    public var roundedPeak: Int? { peak.map { Int($0.rounded()) } }

    /// Usage only ever rises within a week, so a drop of more than this many points means a reset.
    public static let resetDrop = 1.0

    public static func aggregate(_ samples: [UsageSample], days: Int, now: Date, knownResets: [Date] = [],
                                 calendar: Calendar = .current) -> [DailyUsage] {
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        let starts: [Date] = (0..<days).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let sorted = samples.filter { $0.p.isFinite }.sorted { $0.t < $1.t }

        // Moments where the value fell: that's a reset (attributed to the day of the lower reading).
        // A drop where Grok Bot switched between its own allowance and its share of the shared pool is a
        // change of what's measured, not a reset.
        var resets = knownResets
        for (a, b) in zip(sorted, sorted.dropFirst()) where a.p - b.p > resetDrop && a.isShare == b.isShare {
            resets.append(b.t)
        }

        return starts.map { start in
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            let inDay = sorted.filter { $0.t >= start && $0.t < end }
            return DailyUsage(day: start,
                              peak: inDay.map(\.p).max(),
                              reset: resets.contains { $0 >= start && $0 < end },
                              isToday: start == today)
        }
    }
}
