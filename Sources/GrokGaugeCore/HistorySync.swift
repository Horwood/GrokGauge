import Foundation

/// One Mac's usage history as shared through a synced folder:
/// `<sync folder>/GrokGauge/history/<machine-id>.json`.
///
/// Each Mac writes only its own file. It holds usage percentages, timestamps, a random per-Mac id and
/// the Mac's name — never tokens, emails, account ids, or anything from `~/.grok`.
public struct MachineHistoryFile: Codable, Equatable, Sendable {
    public static let appName = "GrokGauge"
    public static let kindName = "usageHistory"
    public static let currentSchema = 1

    public var app: String
    public var kind: String
    public var schema: Int
    public var machineID: String
    public var machineName: String
    public var updatedAt: Date
    public var grok: [UsageSample]
    public var grokBot: [UsageSample]
    /// Added in 0.9.3 (optional, so 0.9.2 files still read and 0.9.2 ignores it).
    public var cursor: [UsageSample]?

    public init(machineID: String, machineName: String, updatedAt: Date = Date(), history: UsageHistory) {
        app = Self.appName
        kind = Self.kindName
        schema = Self.currentSchema
        self.machineID = machineID
        self.machineName = machineName
        self.updatedAt = updatedAt
        grok = history.grok
        grokBot = history.grokBot
        cursor = history.cursor.isEmpty ? nil : history.cursor
    }

    public var history: UsageHistory {
        var h = UsageHistory()
        h.grok = grok.sorted { $0.t < $1.t }
        h.grokBot = grokBot.sorted { $0.t < $1.t }
        h.cursor = (cursor ?? []).sorted { $0.t < $1.t }
        return h
    }
}

/// A file in the history folder that couldn't be used (shown on the Diagnostics tab).
public struct HistorySyncSkip: Equatable, Sendable {
    public var fileName: String
    public var reason: String
    public init(fileName: String, reason: String) {
        self.fileName = fileName
        self.reason = reason
    }
}

/// Everything read from the history folder in one pass.
public struct HistorySyncRead: Equatable, Sendable {
    public var files: [MachineHistoryFile] = []
    public var skipped: [HistorySyncSkip] = []
    /// Readable sync-client conflict copies (e.g. Insync's "… (1).json"); their data is merged too.
    public var conflictCopies: [String] = []

    public init(files: [MachineHistoryFile] = [], skipped: [HistorySyncSkip] = [], conflictCopies: [String] = []) {
        self.files = files
        self.skipped = skipped
        self.conflictCopies = conflictCopies
    }

    /// Distinct Macs (a conflict copy of a Mac's file doesn't count twice).
    public var machineIDs: Set<String> { Set(files.map(\.machineID)) }
    public var machineCount: Int { machineIDs.count }

    /// One friendly name per Mac (the newest file's name wins), sorted.
    public var machineNames: [String] {
        var byID: [String: MachineHistoryFile] = [:]
        for f in files where (byID[f.machineID]?.updatedAt ?? .distantPast) <= f.updatedAt { byID[f.machineID] = f }
        return byID.values.map(\.machineName).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

public enum HistorySyncError: Error, Equatable {
    case notAHistoryFile
    case newerSchema(Int)
    case missingMachineID
    case tooLarge
}

public enum HistorySync {
    public static let folderName = "history"
    /// Larger than any real file (1,500 samples × 2 sources is ~100 KB).
    public static let maxFileSize = 2 * 1024 * 1024
    /// Readings from different Macs that land in the same bucket are treated as the same reading (MAX wins).
    public static let bucket: TimeInterval = 10 * 60

    /// `<sync folder>/GrokGauge/history`
    public static func directory(inSyncFolder folder: URL) -> URL {
        folder.appendingPathComponent(SettingsSync.folderName, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// `<sync folder>/GrokGauge/history/<machine-id>.json`
    public static func fileURL(inSyncFolder folder: URL, machineID: String) -> URL {
        directory(inSyncFolder: folder).appendingPathComponent(safeFileStem(machineID) + ".json")
    }

    /// Letters, digits, "-" and "_" only, so an id can never escape the folder.
    public static func safeFileStem(_ id: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let s = String(id.map { allowed.contains($0) ? $0 : "_" }.prefix(64))
        return s.isEmpty ? "mac" : s
    }

    /// Insync, Google Drive, Dropbox and iCloud name conflict copies like "x (1).json",
    /// "x (conflicted copy 2026-10-17).json", "x-conflict-….json" or "x 2.json".
    public static func isConflictCopy(_ fileName: String) -> Bool {
        let stem = (fileName as NSString).deletingPathExtension
        if stem.range(of: "conflict", options: .caseInsensitive) != nil { return true }
        if stem.range(of: #"\(\d+\)$"#, options: .regularExpression) != nil { return true }
        if stem.range(of: #" \d+$"#, options: .regularExpression) != nil { return true }
        return false
    }

    // MARK: Encode / decode

    public static func encode(_ file: MachineHistoryFile) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return try e.encode(file)
    }

    public static func decode(_ data: Data) throws -> MachineHistoryFile {
        guard data.count <= maxFileSize else { throw HistorySyncError.tooLarge }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        var f = try d.decode(MachineHistoryFile.self, from: data)
        guard f.app == MachineHistoryFile.appName, f.kind == MachineHistoryFile.kindName else {
            throw HistorySyncError.notAHistoryFile
        }
        guard f.schema <= MachineHistoryFile.currentSchema else { throw HistorySyncError.newerSchema(f.schema) }
        guard !f.machineID.trimmingCharacters(in: .whitespaces).isEmpty else { throw HistorySyncError.missingMachineID }
        // Hand-edited or damaged values are dropped rather than trusted.
        let sane: (UsageSample) -> Bool = { $0.p.isFinite && $0.p >= 0 && $0.p <= 1_000 && $0.t.timeIntervalSince1970 > 0 }
        f.grok = f.grok.filter(sane)
        f.grokBot = f.grokBot.filter(sane)
        f.cursor = f.cursor?.filter(sane)
        f.machineName = String(f.machineName.prefix(80))
        return f
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case HistorySyncError.notAHistoryFile: return "not a GrokGauge history file"
        case HistorySyncError.newerSchema(let s): return "written by a newer GrokGauge (schema \(s))"
        case HistorySyncError.missingMachineID: return "no machine id"
        case HistorySyncError.tooLarge: return "too large"
        case is DecodingError: return "unreadable or partial JSON"
        default: return "couldn't be read"
        }
    }

    // MARK: Disk

    /// Writes atomically (temp file + rename) so other Macs and sync clients never see half a file.
    public static func write(_ file: MachineHistoryFile, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(file).write(to: url, options: [.atomic])
    }

    /// Reads every `*.json` in the history folder. Bad, partial or foreign files are skipped and listed,
    /// never thrown. A missing folder is just empty.
    public static func readAll(directory: URL) -> HistorySyncRead {
        var out = HistorySyncRead()
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return out }
        for name in names.sorted() {
            // Hidden files, sync-client temp/partial files and anything that isn't JSON.
            guard !name.hasPrefix("."), !name.hasPrefix("~"), name.lowercased().hasSuffix(".json") else { continue }
            let url = directory.appendingPathComponent(name)
            do {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= maxFileSize else { throw HistorySyncError.tooLarge }
                let data = try Data(contentsOf: url, options: [.uncached])
                let f = try decode(data)
                out.files.append(f)
                if isConflictCopy(name) { out.conflictCopies.append(name) }
            } catch {
                out.skipped.append(HistorySyncSkip(fileName: name, reason: describe(error)))
            }
        }
        return out
    }

    // MARK: Merge

    /// Combines this Mac's history with other Macs'.
    ///
    /// Usage is account-wide, so two Macs reading at about the same time see the same number: readings for
    /// the same source in the same `bucket` are de-duplicated by taking the MAX (never added). Samples outside
    /// the history window (or in the future) are dropped, Grok and Grok Bot stay separate, and a lone dip
    /// that recovers right away (one Mac's slightly stale reading) is removed so it isn't drawn as a reset.
    public static func merge(local: UsageHistory, others: [UsageHistory], now: Date = Date(),
                             bucket: TimeInterval = HistorySync.bucket) -> UsageHistory {
        var out = UsageHistory()
        out.grok = mergeSamples([local.grok] + others.map(\.grok), now: now, bucket: bucket)
        out.grokBot = mergeSamples(droppingOutdatedBotSamples([local.grokBot] + others.map(\.grokBot)),
                                   now: now, bucket: bucket)
        out.cursor = mergeSamples([local.cursor] + others.map(\.cursor), now: now, bucket: bucket)
        return out
    }

    /// Macs still on 0.9.2 keep recording Grok Bot's whole reading after a newer Mac has started recording
    /// what the 0.9.3 ring shows (tagged with `s`). Untagged samples newer than the first tagged one would mix
    /// two different measures in one graph, so they're dropped; everything before stays.
    static func droppingOutdatedBotSamples(_ lists: [[UsageSample]]) -> [[UsageSample]] {
        guard let firstTagged = lists.flatMap({ $0.filter { $0.s != nil } }).map(\.t).min() else { return lists }
        return lists.map { list in list.filter { $0.s != nil || $0.t < firstTagged } }
    }

    static func mergeSamples(_ lists: [[UsageSample]], now: Date, bucket: TimeInterval) -> [UsageSample] {
        let oldest = now.addingTimeInterval(-UsageHistory.keep)
        let newest = now.addingTimeInterval(300)
        var best: [Int64: UsageSample] = [:]
        for list in lists {
            for s in list where s.p.isFinite && s.p >= 0 && s.t >= oldest && s.t <= newest {
                let key = Int64((s.t.timeIntervalSince1970 / bucket).rounded(.down))
                if let cur = best[key] {
                    // Same bucket, different measure (share vs. allowance): the newer-style tagged sample wins.
                if cur.isShare != s.isShare {
                    if s.s != nil && (cur.s == nil || s.t > cur.t) { best[key] = s }
                } else if s.p > cur.p || (s.p == cur.p && s.t > cur.t) { best[key] = s }
                } else {
                    best[key] = s
                }
            }
        }
        var merged = best.values.sorted { $0.t < $1.t }
        merged = removingDips(merged)
        if merged.count > UsageHistory.maxSamplesPerSource {
            merged.removeFirst(merged.count - UsageHistory.maxSamplesPerSource)
        }
        return merged
    }

    /// Usage only rises within a week. A sample that falls below its predecessor (more than
    /// `DailyUsage.resetDrop`) while the next sample is back up is noise, not a reset.
    static func removingDips(_ samples: [UsageSample]) -> [UsageSample] {
        guard samples.count >= 3 else { return samples }
        var out: [UsageSample] = [samples[0]]
        for i in 1..<samples.count {
            let s = samples[i]
            if i + 1 < samples.count, let prev = out.last {
                let next = samples[i + 1]
                if prev.p - s.p > DailyUsage.resetDrop, prev.p - next.p <= DailyUsage.resetDrop,
                   prev.isShare == s.isShare { continue }
            }
            out.append(s)
        }
        return out
    }
}

// MARK: - Which folder history syncs through

public enum HistoryFolderOrigin: String, Equatable, Sendable {
    /// Picked on the Sync tab for history.
    case chosen
    /// The folder settings already sync through.
    case settingsSync
    /// Found automatically (a "MacSyncing" folder in a cloud drive).
    case detected

    public var label: String {
        switch self {
        case .chosen: return "chosen"
        case .settingsSync: return "same as settings sync"
        case .detected: return "found automatically"
        }
    }
}

public enum HistorySyncFolder {
    /// A folder picked for history wins, then the settings-sync folder, then an auto-detected one.
    /// nil means local-only history (exactly as before 0.9.2).
    public static func resolve(chosen: URL?, settingsSync: URL?, detected: URL?) -> (url: URL, origin: HistoryFolderOrigin)? {
        if let chosen { return (chosen, .chosen) }
        if let settingsSync { return (settingsSync, .settingsSync) }
        if let detected { return (detected, .detected) }
        return nil
    }

    /// Every folder history is written to and read from. A folder picked for history is used alone. Otherwise
    /// both the settings-sync folder and the auto-detected MacSyncing folder are used when they differ, so a
    /// Mac whose settings sync through a subfolder (e.g. "MacSyncing/xAI") still meets Macs that use the
    /// MacSyncing folder itself. The first entry is the primary folder (shown in Settings).
    public static func candidates(chosen: URL?, settingsSync: URL?, detected: URL?) -> [(url: URL, origin: HistoryFolderOrigin)] {
        if let chosen { return [(chosen, .chosen)] }
        var out: [(url: URL, origin: HistoryFolderOrigin)] = []
        for (url, origin) in [(settingsSync, HistoryFolderOrigin.settingsSync), (detected, .detected)] {
            guard let url else { continue }
            let key = url.standardizedFileURL.resolvingSymlinksInPath().path
            if out.contains(where: { $0.url.standardizedFileURL.resolvingSymlinksInPath().path == key }) { continue }
            out.append((url, origin))
        }
        return out
    }

    /// "Sync history across Macs" is on by default; it only does anything once there's a folder.
    public static func isEnabled(stored: Bool?) -> Bool { stored ?? true }
}
