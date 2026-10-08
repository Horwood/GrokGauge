import Foundation

public enum HistorySource: String, Codable, CaseIterable, Sendable {
    case grok, grokBot
}

public struct UsageSample: Codable, Equatable, Sendable {
    public var t: Date
    public var p: Double
    public init(t: Date, p: Double) {
        self.t = t
        self.p = p
    }
}

/// Local usage samples for the 7-day sparklines. Stored in
/// `~/Library/Application Support/GrokGauge/history.json`. Never synced.
public struct UsageHistory: Codable, Equatable, Sendable {
    public static let keep: TimeInterval = 8 * 86_400
    public static let maxSamplesPerSource = 1_500
    /// A new sample with the same value is skipped unless this much time passed.
    public static let minSpacing: TimeInterval = 30 * 60

    public var schema = 1
    public var grok: [UsageSample] = []
    public var grokBot: [UsageSample] = []

    public init() {}

    public func samples(_ source: HistorySource) -> [UsageSample] {
        source == .grok ? grok : grokBot
    }

    private mutating func set(_ source: HistorySource, _ value: [UsageSample]) {
        if source == .grok { grok = value } else { grokBot = value }
    }

    /// Adds a sample, keeping the list sorted and skipping redundant points.
    public mutating func record(_ source: HistorySource, percent: Double, at time: Date) {
        guard percent.isFinite else { return }
        var list = samples(source)
        if let last = list.last {
            if time == last.t { return }
            if time > last.t, abs(last.p - percent) < 0.005, time.timeIntervalSince(last.t) < Self.minSpacing { return }
        }
        let sample = UsageSample(t: time, p: max(0, percent))
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
