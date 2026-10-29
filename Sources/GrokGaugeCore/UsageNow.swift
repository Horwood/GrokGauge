import Foundation

// MARK: - Current usage, as a file other programs can read
//
// The rings already agree on one split of the SuperGrok pool (`PoolBreakdown`). History files are not that
// split: `history.json` stores the whole pool under "grok", then Grok Bot and Cursor beside it, and merges
// two Macs by taking the higher percent. A widget that did the same after a weekly reset would keep showing
// yesterday's 96% until every Mac had caught up.
//
// This file is the other contract. It is one reading of *right now* — the same numbers the rings draw — and
// nothing else. No tokens, no emails, no account ids, no dollar balances, nothing from `~/.grok`.
//
// Two places get a copy:
//   ~/Library/Application Support/GrokGauge/usage.json          this Mac, always (Shortcuts, a menu widget, …)
//   <sync folder>/GrokGauge/now/<machine-id>.json              only while history sync is on
//
// Each Mac writes only its own sync file, same as history, so Insync / Drive / iCloud never have to merge one
// shared document. A reader picks the file with the newest `updatedAt` (`UsageNowSync.freshest`). That is the
// opposite of the history merge on purpose: after a reset the true number is smaller, and the Mac that read
// it last is the one to believe.
//
// Dates are seconds since 1970. `schema` only goes up; new fields are optional, so an older reader still works.

public struct UsageNowReading: Codable, Equatable, Sendable {
    public var percent: Double
    /// Whole percent, rounded the way that ring draws it.
    public var rounded: Int
    /// `normal` (≤80), `warning` (81–90) or `critical` (>90), from the rounded number.
    public var level: String
    public var readAt: Date

    public init(percent: Double, rounded: Int, level: String, readAt: Date) {
        self.percent = percent
        self.rounded = rounded
        self.level = level
        self.readAt = readAt
    }
}

public struct UsageNowProduct: Codable, Equatable, Sendable {
    public var key: String
    public var name: String
    public var percent: Double

    public init(key: String, name: String, percent: Double) {
        self.key = key
        self.name = name
        self.percent = percent
    }
}

public struct UsageNowFile: Codable, Equatable, Sendable {
    public static let appName = "GrokGauge"
    public static let kindName = "usageNow"
    public static let currentSchema = 1

    public var app: String
    public var kind: String
    public var schema: Int
    public var machineID: String
    public var machineName: String
    /// When the newest number in this file was read. Not "when the file was rewritten".
    public var updatedAt: Date
    /// `weekly` / `monthly` / `daily` / `unknown`, from the Grok billing reply.
    public var period: String?
    public var periodStart: Date?
    public var periodEnd: Date?
    /// The Total ring: the whole pool.
    public var total: UsageNowReading?
    /// Regular Grok use (Total − Grok Bot − Cursor). Nil while a slice isn't known yet.
    public var grok: UsageNowReading?
    /// The Grok Bot ring. On a shared pool this is Grok Bot's *share*, not its own whole-pool reading.
    public var grokBot: UsageNowReading?
    /// `shared` or `separate`. Present even while the share itself isn't known yet, so a reader doesn't
    /// fall back to Grok Bot's own reading (that number is the whole pool).
    public var grokBotMode: String?
    public var cursor: UsageNowReading?
    /// Same text as the Grok ring's tooltip, e.g. "Grok 8% + Grok Bot 70% + Cursor 18% = Total 96%".
    public var equation: String?
    /// Per-product rows from the billing reply (Chat, Imagine, …). Not the ring split.
    public var products: [UsageNowProduct]?
    /// `unavailable` when the pool reading was dropped on purpose (signed out, or a reply GrokGauge
    /// won't guess at). Absent while the number just hasn't arrived yet — readers should keep the
    /// previous file in that case, and this file is only written once the state is real.
    public var grokGap: String?

    public init(machineID: String, machineName: String, updatedAt: Date, period: String? = nil,
                periodStart: Date? = nil, periodEnd: Date? = nil, total: UsageNowReading? = nil,
                grok: UsageNowReading? = nil, grokBot: UsageNowReading? = nil, grokBotMode: String? = nil,
                cursor: UsageNowReading? = nil, equation: String? = nil, products: [UsageNowProduct]? = nil,
                grokGap: String? = nil) {
        app = Self.appName
        kind = Self.kindName
        schema = Self.currentSchema
        self.machineID = machineID
        self.machineName = machineName
        self.updatedAt = updatedAt
        self.period = period
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.total = total
        self.grok = grok
        self.grokBot = grokBot
        self.grokBotMode = grokBotMode
        self.cursor = cursor
        self.equation = equation
        self.products = products
        self.grokGap = grokGap
    }

    /// The document the rings would draw from `pool` and `bot`.
    /// - `grokUnavailable`: the pool reading was thrown out (signed out, login expired, reply changed shape).
    ///   Without it, a nil pool just means "still loading" and this returns nil so the previous file stays.
    public static func make(machineID: String, machineName: String, pool: UsageSnapshot?, bot: BotRingReading?,
                            grokUnavailable: Bool = false, now: Date = Date()) -> UsageNowFile? {
        let id = machineID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        let breakdown = pool.map { PoolBreakdown.make(pool: $0, bot: bot) }
        let total = pool.map { reading($0.percent, rounded: PoolBreakdown.whole($0.percent), at: $0.fetchedAt) }
        let grok: UsageNowReading? = {
            guard let pool, let breakdown, let value = breakdown.grok, let rounded = breakdown.roundedGrok else { return nil }
            return reading(value, rounded: rounded, at: pool.fetchedAt)
        }()
        let grokBot: UsageNowReading? = bot.flatMap { b in
            guard let p = b.percent, let rounded = b.roundedPercent else { return nil }
            return reading(p, rounded: rounded, at: b.readAt)
        }
        let mode: String? = bot.map { $0.isShared ? "shared" : "separate" }
        let cursor: UsageNowReading? = {
            // Present whenever the pool was read, including 0, so a widget doesn't treat "no key" as "unknown".
            guard let pool, let breakdown else { return nil }
            return reading(breakdown.cursor, rounded: PoolBreakdown.whole(breakdown.cursor), at: pool.fetchedAt)
        }()
        let products: [UsageNowProduct]? = {
            guard let pool, !pool.products.isEmpty else { return nil }
            return pool.products.prefix(32).map { UsageNowProduct(key: $0.key, name: $0.name, percent: $0.percent) }
        }()
        // A shared week with no share yet is still worth writing: the mode tells a reader not to invent one.
        // `grokGap` is worth writing even with no numbers, so a widget doesn't keep showing a login that died.
        let gap: String? = (pool == nil && grokUnavailable) ? "unavailable" : nil
        guard total != nil || grokBot != nil || mode == "shared" || gap != nil else { return nil }
        var times: [Date] = []
        if let pool { times.append(pool.fetchedAt) }
        if let bot { times.append(bot.readAt) }
        let updated = times.max() ?? now
        return UsageNowFile(
            machineID: id,
            machineName: String(machineName.prefix(80)),
            updatedAt: updated,
            period: pool?.period.rawValue,
            periodStart: pool?.periodStart,
            periodEnd: pool?.periodEnd ?? bot?.nextReset,
            total: total,
            grok: grok,
            grokBot: grokBot,
            grokBotMode: mode,
            cursor: cursor,
            equation: breakdown?.equation,
            products: products,
            grokGap: gap
        )
    }

    private static func reading(_ percent: Double, rounded: Int, at: Date) -> UsageNowReading {
        UsageNowReading(percent: percent, rounded: rounded, level: UsageLevel.forPercent(rounded).rawValue, readAt: at)
    }
}

public enum UsageNowError: Error, Equatable {
    case notAUsageFile
    case newerSchema(Int)
    case missingMachineID
    case tooLarge
}

public struct UsageNowDiskFile: Equatable, Sendable {
    public var fileName: String
    public var file: UsageNowFile
    public init(fileName: String, file: UsageNowFile) {
        self.fileName = fileName
        self.file = file
    }
}

public struct UsageNowRead: Equatable, Sendable {
    public var files: [UsageNowDiskFile] = []
    public var skipped: [HistorySyncSkip] = []
    public init(files: [UsageNowDiskFile] = [], skipped: [HistorySyncSkip] = []) {
        self.files = files
        self.skipped = skipped
    }
}

/// The reading a widget should show. `stale` means every Mac's file is older than `staleAfter`.
public struct UsageNowPick: Equatable, Sendable {
    public var file: UsageNowFile
    public var fileName: String
    public var stale: Bool
    /// Distinct Macs with a usable file (a conflict copy of the same Mac doesn't count twice).
    public var machineCount: Int

    public init(file: UsageNowFile, fileName: String, stale: Bool, machineCount: Int) {
        self.file = file
        self.fileName = fileName
        self.stale = stale
        self.machineCount = machineCount
    }
}

public enum UsageNowSync {
    public static let folderName = "now"
    public static let localFileName = "usage.json"
    /// One reading is a few KB. Anything larger isn't this file.
    public static let maxFileSize = 256 * 1024
    /// A Mac asleep or quit past this is "stale" for a widget. Refreshes are 2–15 minutes.
    public static let staleAfter: TimeInterval = 3 * 60 * 60
    /// A file dated further ahead than this is a clock that's wrong, not a newer reading.
    public static let futureSkew: TimeInterval = 5 * 60

    /// `<sync folder>/GrokGauge/now`
    public static func directory(inSyncFolder folder: URL) -> URL {
        folder.appendingPathComponent(SettingsSync.folderName, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// `<sync folder>/GrokGauge/now/<machine-id>.json`
    public static func fileURL(inSyncFolder folder: URL, machineID: String) -> URL {
        directory(inSyncFolder: folder).appendingPathComponent(HistorySync.safeFileStem(machineID) + ".json")
    }

    /// `~/Library/Application Support/GrokGauge/usage.json` (next to `history.json`).
    public static func localFileURL() -> URL {
        UsageHistory.defaultURL.deletingLastPathComponent().appendingPathComponent(localFileName)
    }

    public static func encode(_ file: UsageNowFile) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return try e.encode(file)
    }

    public static func decode(_ data: Data) throws -> UsageNowFile {
        guard data.count <= maxFileSize else { throw UsageNowError.tooLarge }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        var f = try d.decode(UsageNowFile.self, from: data)
        guard f.app == UsageNowFile.appName, f.kind == UsageNowFile.kindName else { throw UsageNowError.notAUsageFile }
        guard f.schema <= UsageNowFile.currentSchema else { throw UsageNowError.newerSchema(f.schema) }
        guard !f.machineID.trimmingCharacters(in: .whitespaces).isEmpty else { throw UsageNowError.missingMachineID }
        f.machineName = String(f.machineName.prefix(80))
        f.total = sane(f.total)
        f.grok = sane(f.grok)
        f.grokBot = sane(f.grokBot)
        f.cursor = sane(f.cursor)
        if let mode = f.grokBotMode, mode != "shared", mode != "separate" { f.grokBotMode = nil }
        if f.grokGap != "unavailable" { f.grokGap = nil }
        f.products = f.products?.filter { $0.percent.isFinite && $0.percent >= 0 && $0.percent <= 1_000 && !$0.key.isEmpty }
        if f.products?.isEmpty == true { f.products = nil }
        return f
    }

    /// Drops a reading that can't be a percent. A damaged file loses that number instead of being thrown out.
    static func sane(_ r: UsageNowReading?) -> UsageNowReading? {
        guard let r, r.percent.isFinite, r.percent >= 0, r.percent <= 1_000, r.readAt.timeIntervalSince1970 > 0 else { return nil }
        return r
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case UsageNowError.notAUsageFile: return "not a GrokGauge usage file"
        case UsageNowError.newerSchema(let s): return "written by a newer GrokGauge (schema \(s))"
        case UsageNowError.missingMachineID: return "no machine id"
        case UsageNowError.tooLarge: return "too large"
        case is DecodingError: return "unreadable or partial JSON"
        default: return "couldn't be read"
        }
    }

    /// Writes atomically (temp file + rename) so a widget never reads half a file.
    public static func write(_ data: Data, to url: URL) throws {
        guard data.count <= maxFileSize else { throw UsageNowError.tooLarge }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    public static func write(_ file: UsageNowFile, to url: URL) throws {
        try write(try encode(file), to: url)
    }

    /// Reads every `*.json` in a `now` folder. Bad files are listed, never thrown. A missing folder is empty.
    public static func readAll(directory: URL) -> UsageNowRead {
        var out = UsageNowRead()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return out }
        for name in names.sorted() {
            guard !name.hasPrefix("."), !name.hasPrefix("~"), name.lowercased().hasSuffix(".json") else { continue }
            let url = directory.appendingPathComponent(name)
            do {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= maxFileSize else { throw UsageNowError.tooLarge }
                out.files.append(UsageNowDiskFile(fileName: name, file: try decode(try Data(contentsOf: url, options: [.uncached]))))
            } catch {
                out.skipped.append(HistorySyncSkip(fileName: name, reason: describe(error)))
            }
        }
        return out
    }

    /// The reading to show. Newest `updatedAt` wins — not the highest percent. Conflict copies of one Mac
    /// count as that Mac. Files dated more than `futureSkew` ahead of `now` are ignored.
    public static func freshest(_ read: UsageNowRead, now: Date = Date(),
                                staleAfter: TimeInterval = UsageNowSync.staleAfter) -> UsageNowPick? {
        let horizon = now.addingTimeInterval(futureSkew)
        var byID: [String: UsageNowDiskFile] = [:]
        for item in read.files where item.file.updatedAt <= horizon {
            guard let cur = byID[item.file.machineID] else { byID[item.file.machineID] = item; continue }
            if item.file.updatedAt > cur.file.updatedAt
                || (item.file.updatedAt == cur.file.updatedAt && prefers(item, over: cur)) {
                byID[item.file.machineID] = item
            }
        }
        guard let winner = byID.values.max(by: { lhs, rhs in
            if lhs.file.updatedAt != rhs.file.updatedAt { return lhs.file.updatedAt < rhs.file.updatedAt }
            if lhs.file.schema != rhs.file.schema { return lhs.file.schema < rhs.file.schema }
            return lhs.file.machineID > rhs.file.machineID
        }) else { return nil }
        return UsageNowPick(file: winner.file, fileName: winner.fileName,
                            stale: now.timeIntervalSince(winner.file.updatedAt) > staleAfter,
                            machineCount: byID.count)
    }

    /// A real file beats a sync-client conflict copy of the same moment.
    private static func prefers(_ item: UsageNowDiskFile, over current: UsageNowDiskFile) -> Bool {
        !HistorySync.isConflictCopy(item.fileName) && HistorySync.isConflictCopy(current.fileName)
    }
}
