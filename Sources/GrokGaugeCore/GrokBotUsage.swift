import Foundation

// MARK: - Grok Bot weekly usage
//
// Grok Bot (the desktop app, bundle id com.anysphere.sand) keeps the result of its own
// "weekly usage" request in a small, unencrypted JSON cache inside its data folder:
//
//   ~/Library/Application Support/Grok Bot/sand-client-persistence/
//     <base32("sand.client.slice.client-meta.account-slot")>.blob       -> {"value":"grok|user_…"}
//     <base32("sand.client.slice.account.<slot>.weekly-usage.cache")>.blob
//        -> {"schemaVersion":2,"value":{"kind":"present","reading":{"usage":{"percentUsed":9.64,
//            "nextResetMs":…,…},"readAtMs":…},"expiresAtMs":…}}
//
// GrokGauge only ever *reads* those two files. It never touches Grok Bot's login, Keychain
// item, or encrypted secrets, never writes into its folder, and makes no network request for
// Grok Bot at all: the numbers are exactly what Grok Bot itself last fetched.

public struct GrokBotSnapshot: Equatable, Sendable {
    public var percent: Double
    public var nextReset: Date?
    public var readAt: Date
    /// Grok Bot's own time-to-live for this cached reading.
    public var expiresAt: Date?
    public var planLabel: String?
    public var isTrial: Bool
    public var onDemandUsedCents: Double?
    public var onDemandLimitCents: Double?

    public init(percent: Double, nextReset: Date?, readAt: Date, expiresAt: Date?, planLabel: String? = nil,
                isTrial: Bool = false, onDemandUsedCents: Double? = nil, onDemandLimitCents: Double? = nil) {
        self.percent = percent
        self.nextReset = nextReset
        self.readAt = readAt
        self.expiresAt = expiresAt
        self.planLabel = planLabel
        self.isTrial = isTrial
        self.onDemandUsedCents = onDemandUsedCents
        self.onDemandLimitCents = onDemandLimitCents
    }

    /// Rounded the same way Grok Bot's own Usage screen does (anything between 0 and 1 shows as 1%).
    public var roundedPercent: Int {
        let p = min(max(percent, 0), 100)
        return p > 0 && p < 1 ? 1 : Int(p.rounded())
    }
    public var level: UsageLevel { .forPercent(roundedPercent) }

    /// Stable identifier for the current weekly window (alerts fire once per window).
    public var periodKey: String {
        if let end = nextReset { return "bot-" + String(Int(end.timeIntervalSince1970)) }
        return "bot-unknown"
    }

    public func timeUntilReset(now: Date = Date()) -> TimeInterval? {
        guard let end = nextReset else { return nil }
        return max(0, end.timeIntervalSince(now))
    }

    /// The reading can't be trusted any more: Grok Bot's cache expired, or the week it
    /// describes has already reset.
    public func isStale(now: Date = Date()) -> Bool {
        if let exp = expiresAt, now >= exp { return true }
        if let end = nextReset, now >= end { return true }
        return false
    }
}

public enum GrokBotUsageError: Error, Equatable, Sendable {
    /// No Grok Bot data folder (app not installed or never opened).
    case notInstalled
    /// Grok Bot has no signed-in account, or hasn't cached a usage reading yet.
    case noReading
    /// Grok Bot reports no personal weekly limit (e.g. pooled enterprise allowance).
    case unavailable
    /// The cached reading is older than Grok Bot's own expiry, or its week already reset.
    case stale(GrokBotSnapshot)
    /// The cache file exists but isn't in the format GrokGauge understands.
    case unrecognized
}

public enum GrokBotUsageReader {
    static let slotName = "sand.client.slice.client-meta.account-slot"
    static let cacheSuffix = ".weekly-usage.cache"
    static let accountPrefix = "sand.client.slice.account."
    static let maxFileSize = 256 * 1024

    /// `GROKBOT_DATA_DIR` overrides the default `~/Library/Application Support/Grok Bot`.
    public static var dataDirectory: URL {
        if let env = ProcessInfo.processInfo.environment["GROKBOT_DATA_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grok Bot", isDirectory: true)
    }

    public static func persistenceDirectory(in dataDir: URL = dataDirectory) -> URL {
        dataDir.appendingPathComponent("sand-client-persistence", isDirectory: true)
    }

    /// Reads Grok Bot's cached weekly usage. Read-only; throws `GrokBotUsageError`.
    public static func read(dataDir: URL = dataDirectory, now: Date = Date()) throws -> GrokBotSnapshot {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dataDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw GrokBotUsageError.notInstalled
        }
        let dir = persistenceDirectory(in: dataDir)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { throw GrokBotUsageError.noReading }

        var slotFile: String?
        var caches: [(slot: String, file: String)] = []
        for file in names where file.hasSuffix(".blob") {
            guard let key = decodeBlobName(file) else { continue }
            if key == slotName {
                slotFile = file
            } else if key.hasPrefix(accountPrefix), key.hasSuffix(cacheSuffix) {
                let encoded = String(key.dropFirst(accountPrefix.count).dropLast(cacheSuffix.count))
                caches.append((encoded.removingPercentEncoding ?? encoded, file))
            }
        }
        guard !caches.isEmpty else { throw GrokBotUsageError.noReading }

        let activeSlot = slotFile.flatMap { try? readSmallFile(dir.appendingPathComponent($0)) }.flatMap(parseSlot)
        let candidates: [(slot: String, file: String)]
        if let activeSlot {
            candidates = caches.filter { $0.slot == activeSlot }
            // The signed-in account has no reading yet: don't show another account's numbers.
            guard !candidates.isEmpty else { throw GrokBotUsageError.noReading }
        } else {
            candidates = caches
        }

        var best: GrokBotSnapshot?
        var sawAbsent = false
        var sawUnrecognized = false
        for c in candidates {
            guard let data = try? readSmallFile(dir.appendingPathComponent(c.file)) else { continue }
            do {
                let s = try parseCache(data)
                if best == nil || s.readAt > best!.readAt { best = s }
            } catch GrokBotUsageError.unavailable {
                sawAbsent = true
            } catch {
                sawUnrecognized = true
            }
        }
        guard let snapshot = best else {
            if sawAbsent { throw GrokBotUsageError.unavailable }
            throw sawUnrecognized ? GrokBotUsageError.unrecognized : GrokBotUsageError.noReading
        }
        if snapshot.isStale(now: now) { throw GrokBotUsageError.stale(snapshot) }
        return snapshot
    }

    // MARK: Parsing (internal for tests)

    static func parseSlot(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = obj["value"] as? String, !v.isEmpty else { return nil }
        return v
    }

    static func parseCache(_ data: Data) throws -> GrokBotSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = root["value"] as? [String: Any],
              let kind = value["kind"] as? String else { throw GrokBotUsageError.unrecognized }
        if kind == "absent" { throw GrokBotUsageError.unavailable }
        guard kind == "present",
              let reading = value["reading"] as? [String: Any],
              let usage = reading["usage"] as? [String: Any],
              let percent = number(usage["percentUsed"]), percent.isFinite,
              let readAtMs = number(reading["readAtMs"]) else { throw GrokBotUsageError.unrecognized }

        let onDemand = usage["onDemand"] as? [String: Any]
        return GrokBotSnapshot(
            percent: max(0, percent),
            nextReset: date(ms: number(usage["nextResetMs"])),
            readAt: Date(timeIntervalSince1970: readAtMs / 1000),
            expiresAt: date(ms: number(value["expiresAtMs"])),
            planLabel: (usage["grokPlanLabel"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            isTrial: usage["isSandTrial"] as? Bool ?? false,
            onDemandUsedCents: onDemand.flatMap { number($0["usedCents"]) },
            onDemandLimitCents: onDemand.flatMap { number($0["limitCents"]) })
    }

    private static func number(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    private static func date(ms: Double?) -> Date? {
        guard let ms, ms.isFinite, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// Opens without following symlinks and refuses anything large.
    static func readSmallFile(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw GrokBotUsageError.noReading }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = try handle.read(upToCount: maxFileSize + 1) ?? Data()
        guard data.count <= maxFileSize else { throw GrokBotUsageError.unrecognized }
        return data
    }

    /// Blob file names are the storage key, lowercase RFC 4648 base32 without padding.
    static func decodeBlobName(_ file: String) -> String? {
        let stem = file.hasSuffix(".blob") ? String(file.dropLast(5)) : file
        guard let bytes = base32Decode(stem) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    static func base32Decode(_ text: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        var lookup = [UInt8: UInt8]()
        for (i, c) in alphabet.enumerated() { lookup[c] = UInt8(i) }
        var out = Data()
        var buffer: UInt32 = 0
        var bits = 0
        for ch in text.uppercased().utf8 where ch != UInt8(ascii: "=") {
            guard let v = lookup[ch] else { return nil }
            buffer = (buffer << 5) | UInt32(v)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        return out
    }

    static func base32Encode(_ data: Data) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var out = ""
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[Int((buffer >> UInt32(bits)) & 31)])
            }
        }
        if bits > 0 { out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)]) }
        return out
    }
}

// MARK: - Menu bar title

public enum MenuBarStyle: String, CaseIterable, Sendable {
    /// One number: whichever of Grok / Grok Bot is higher.
    case highest
    /// Both numbers: "G 0% · B 9%".
    case both
}

public struct MenuBarSegment: Equatable, Sendable {
    public let text: String
    /// nil = neutral (secondary label color).
    public let level: UsageLevel?

    public init(text: String, level: UsageLevel?) {
        self.text = text
        self.level = level
    }
}

public enum MenuBarTitle {
    /// `grok`/`bot` are rounded percents, or nil when that source has no current reading.
    public static func segments(grok: Int?, bot: Int?, style: MenuBarStyle) -> [MenuBarSegment] {
        switch style {
        case .highest:
            guard let top = [grok, bot].compactMap({ $0 }).max() else { return [] }
            return [MenuBarSegment(text: " \(top)%", level: .forPercent(top))]
        case .both:
            if grok == nil && bot == nil { return [] }
            return [
                MenuBarSegment(text: " G ", level: nil),
                MenuBarSegment(text: grok.map { "\($0)%" } ?? "–", level: grok.map(UsageLevel.forPercent)),
                MenuBarSegment(text: " · B ", level: nil),
                MenuBarSegment(text: bot.map { "\($0)%" } ?? "–", level: bot.map(UsageLevel.forPercent)),
            ]
        }
    }
}
