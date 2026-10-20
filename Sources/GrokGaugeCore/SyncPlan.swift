import Foundation

// MARK: - One sync folder for settings and history (0.9.5)
//
// Settings and the 7-day history used to have separate folder pickers, and a Mac could end up syncing
// through a different folder than its other Macs (e.g. "MacSyncing/xAI" vs "MacSyncing"). Now there's one
// folder. GrokGauge looks for GrokGauge data in nearby candidate folders, picks the one the other Macs use,
// and keeps reading history from the rest (read-only) so Macs still on older versions merge in.

/// What's in one candidate folder's `GrokGauge` subfolder.
public struct SyncFolderSurvey: Equatable, Sendable {
    public var folder: URL
    /// Macs with a readable history file in `<folder>/GrokGauge/history`.
    public var machineIDs: Set<String>
    public var hasSettingsFile: Bool

    public init(folder: URL, machineIDs: Set<String> = [], hasSettingsFile: Bool = false) {
        self.folder = folder
        self.machineIDs = machineIDs
        self.hasSettingsFile = hasSettingsFile
    }

    public var hasHistory: Bool { !machineIDs.isEmpty }
    public var hasData: Bool { hasSettingsFile || hasHistory }

    public func otherMacs(excluding machineID: String) -> Int {
        machineIDs.subtracting([machineID]).count
    }

    /// Reads the folder (directory listings and the small history files only; nothing is written).
    public static func read(_ folder: URL) -> SyncFolderSurvey {
        let history = HistorySync.readAll(directory: HistorySync.directory(inSyncFolder: folder))
        let settings = FileManager.default.fileExists(atPath: SettingsSync.fileURL(inSyncFolder: folder).path)
        return SyncFolderSurvey(folder: folder, machineIDs: history.machineIDs, hasSettingsFile: settings)
    }
}

public enum SyncFolderPlan {
    public enum Recommendation: Equatable, Sendable {
        /// The current folder is the right one (or there's nothing better).
        case keep
        /// Switch without asking: this Mac's folder has no other Mac in it, so nobody else is reading it.
        case autoSwitch(URL)
        /// Another folder has more of your Macs, but other Macs use this one too: offer it, don't move.
        case suggest(URL, otherMacs: Int)
    }

    static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    public static func same(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return key(a) == key(b)
    }

    /// Folders worth looking in: the current folder, its parent, the MacSyncing folder found automatically,
    /// any older folders (e.g. a separate history folder from 0.9.2–0.9.4), and the immediate subfolders of
    /// the current, parent and found folders. Duplicates are dropped; the order is kept.
    /// `subfolders` should return only subfolders that contain a `GrokGauge` folder.
    public static func candidateFolders(current: URL?, detected: URL?, legacy: [URL],
                                        subfolders: (URL) -> [URL]) -> [URL] {
        var out: [URL] = []
        func add(_ u: URL?) {
            guard let u else { return }
            if !out.contains(where: { same($0, u) }) { out.append(u) }
        }
        let parent = current.map { $0.deletingLastPathComponent() }
        add(current)
        add(detected)
        legacy.forEach { add($0) }
        add(parent)
        for root in [current, detected, parent].compactMap({ $0 }) {
            subfolders(root).forEach { add($0) }
        }
        return out
    }

    /// Which folder this Mac should sync through.
    ///
    /// The canonical folder is the one with the most of your *other* Macs' history in it (ties: the folder
    /// found automatically, then the current one). With no folder yet, the canonical one (or the found
    /// folder) is used. With a folder, GrokGauge only moves on its own if no other Mac uses the current one.
    public static func recommend(current: URL?, detected: URL?, surveys: [SyncFolderSurvey],
                                 machineID: String) -> Recommendation {
        let best = canonical(surveys: surveys, detected: detected, current: current, machineID: machineID)
        guard let current else {
            if let best, best.otherMacs(excluding: machineID) > 0 { return .autoSwitch(best.folder) }
            if let detected { return .autoSwitch(detected) }
            return .keep
        }
        guard let best, !same(best.folder, current) else { return .keep }
        let mine = surveys.first(where: { same($0.folder, current) })?.otherMacs(excluding: machineID) ?? 0
        let theirs = best.otherMacs(excluding: machineID)
        guard theirs > mine else { return .keep }
        return mine == 0 ? .autoSwitch(best.folder) : .suggest(best.folder, otherMacs: theirs)
    }

    static func canonical(surveys: [SyncFolderSurvey], detected: URL?, current: URL?, machineID: String) -> SyncFolderSurvey? {
        func rank(_ s: SyncFolderSurvey) -> (Int, Int, Int) {
            (s.otherMacs(excluding: machineID), same(s.folder, detected) ? 1 : 0, same(s.folder, current) ? 1 : 0)
        }
        return surveys.filter(\.hasData).max { rank($0) < rank($1) }
    }

    /// Other folders that hold GrokGauge history: read (never written) so their Macs still merge in.
    public static func readOnlyFolders(primary: URL?, surveys: [SyncFolderSurvey]) -> [URL] {
        guard let primary else { return [] }
        return surveys.filter { $0.hasHistory && !same($0.folder, primary) }.map(\.folder)
    }
}

// MARK: - The one Status line on the Sync tab

public enum SyncSummary {
    public enum SettingsPart: Equatable, Sendable {
        case off, waiting, synced(Date), failed(String)
    }

    public struct HistoryPart: Equatable, Sendable {
        public var enabled: Bool
        public var machineCount: Int
        public var machineNames: [String]
        public var lastSync: Date?
        public var error: String?
        public var skipped: Int

        public init(enabled: Bool, machineCount: Int = 0, machineNames: [String] = [], lastSync: Date? = nil,
                    error: String? = nil, skipped: Int = 0) {
            self.enabled = enabled
            self.machineCount = machineCount
            self.machineNames = machineNames
            self.lastSync = lastSync
            self.error = error
            self.skipped = skipped
        }
    }

    /// e.g. "In sync · 3 Macs (Air-M4, MacBook Pro, Studio) · synced 11:38 PM".
    public static func line(settings: SettingsPart, history: HistoryPart, time: (Date) -> String) -> String {
        if settings == .off && !history.enabled { return "Off · turn on Settings or 7-day usage history below" }
        var warnings: [String] = []
        if case .failed(let m) = settings { warnings.append("⚠︎ Settings: \(m)") }
        if history.enabled, let e = history.error { warnings.append("⚠︎ History: \(e)") }
        var parts: [String] = warnings
        if warnings.isEmpty {
            let waiting = settings == .waiting || (history.enabled && history.lastSync == nil)
            parts.append(waiting ? "Syncing…" : "In sync")
        }
        if history.enabled, history.machineCount > 0 {
            var macs = history.machineCount == 1 ? "1 Mac" : "\(history.machineCount) Macs"
            if !history.machineNames.isEmpty { macs += " (\(history.machineNames.joined(separator: ", ")))" }
            parts.append(macs)
        }
        var latest: Date?
        if case .synced(let d) = settings { latest = d }
        if history.enabled, let h = history.lastSync { latest = max(latest ?? h, h) }
        if let latest { parts.append("synced \(time(latest))") }
        if history.enabled, history.skipped > 0 {
            parts.append("⚠︎ skipped \(history.skipped) bad file\(history.skipped == 1 ? "" : "s") (see Diagnostics)")
        }
        return parts.joined(separator: " · ")
    }
}
