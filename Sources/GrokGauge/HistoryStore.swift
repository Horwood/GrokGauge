import AppKit
import CryptoKit
import GrokGaugeCore
import IOKit
import SystemConfiguration

/// The 7-day usage samples behind the history graphs.
///
/// This Mac's own samples live in Application Support (`history.json`). With "Sync history across Macs" on
/// and a sync folder available, this Mac also writes them to `<folder>/GrokGauge/history/<machine-id>.json`
/// and the graphs show every Mac's file merged (MAX per time bucket, since usage is account-wide).
/// Only percentages, timestamps and the Mac's name are written there — never tokens or anything from ~/.grok.
@MainActor
final class HistoryStore: ObservableObject {
    struct SyncStatus: Equatable {
        var enabled = true
        /// The sync folder in use (nil = local only).
        var folder: URL?
        var origin: HistoryFolderOrigin?
        /// This Mac's file in the folder.
        var ownFile: URL?
        var machineCount = 0
        var machineNames: [String] = []
        var lastSync: Date?
        var skipped: [HistorySyncSkip] = []
        var conflictCopies: [String] = []
        var lastError: String?
        /// Every folder read (the primary first). Only the primary is written; the rest are older folders that
        /// still hold history (e.g. "MacSyncing/xAI" from before 0.9.5), so Macs on older versions merge in.
        var folders: [URL] = []
        /// When this Mac's file was last written successfully, and the last write failure (kept until a
        /// write succeeds, so a read-only refresh can't hide it).
        var lastWrite: Date?
        var writeError: String?
        var writeErrorAt: Date?
        /// Saving `history.json` in Application Support failed.
        var localSaveError: String?
        /// `folders` minus the primary: read, never written.
        var readOnlyFolders: [URL] = []

        var isActive: Bool { enabled && folder != nil }
    }

    /// What the graphs show: this Mac's samples merged with the other Macs'.
    @Published private(set) var history: UsageHistory
    @Published private(set) var sync = SyncStatus()

    /// This Mac's own samples (what's saved locally and written to its sync file).
    private(set) var local: UsageHistory
    private var others: [UsageHistory] = []
    private let url: URL?
    private let defaults: UserDefaults?
    let machineID: String
    let machineName: String
    private var chosenFolder: URL?
    private var primaryFolder: URL?
    private var readOnlyFolders: [URL] = []
    private var pendingSave: DispatchWorkItem?
    private var pendingSync: DispatchWorkItem?
    private var watcher: FolderWatcher?
    /// Extra folder watchers (when history uses more than one folder).
    private var watchers: [FolderWatcher] = []
    private var generation = 0

    static let enabledKey = "history.syncEnabled"
    static let folderKey = "history.folderPath"
    static let machineIDKey = "history.machineID"

    init(url: URL? = UsageHistory.defaultURL, defaults: UserDefaults? = .standard) {
        self.url = url
        self.defaults = defaults
        var h = url.map { UsageHistory.load(from: $0) } ?? UsageHistory()
        h.prune()
        local = h
        history = h
        machineID = defaults.map(Self.machineID(defaults:)) ?? "preview"
        machineName = Self.computerName()
        if let defaults {
            sync.enabled = HistorySyncFolder.isEnabled(stored: defaults.object(forKey: Self.enabledKey) as? Bool)
            chosenFolder = defaults.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
    }

    static func preview(_ h: UsageHistory, sync: SyncStatus = SyncStatus(enabled: true)) -> HistoryStore {
        let s = HistoryStore(url: nil, defaults: nil)
        s.local = h
        s.history = h
        s.sync = sync
        return s
    }

    // MARK: Recording

    func record(_ source: HistorySource, percent: Double, at time: Date, shared: Bool? = nil) {
        var h = local
        h.record(source, percent: percent, at: time, shared: shared)
        h.prune()
        guard h != local else { return }
        local = h
        recompute()
        scheduleSave()
        if sync.isActive { scheduleSync(write: true, after: 3) }
    }

    // MARK: Current usage file (widgets, other devices)

    /// Last document written, so an unchanged reading doesn't rewrite the file (and a cloud folder doesn't churn).
    private var lastUsageNow: Data?
    private var lastUsageNowDest: String?
    private let usageNowQueue = DispatchQueue(label: "GrokGauge.usageNow", qos: .utility)

    /// Writes the ring split `PoolBreakdown` already computed: locally always, and into the sync folder
    /// (`GrokGauge/now/<this Mac>.json`) while history sync is on. Percents and times only.
    /// `grokUnavailable` is set once a pool reading has been thrown out, so the file stops claiming it.
    func publishUsageNow(pool: UsageSnapshot?, bot: BotRingReading?, grokUnavailable: Bool = false, now: Date = Date()) {
        guard let file = UsageNowFile.make(machineID: machineID, machineName: machineName, pool: pool, bot: bot,
                                          grokUnavailable: grokUnavailable, now: now) else { return }
        writeUsageNow(file)
    }

    private func writeUsageNow(_ file: UsageNowFile) {
        guard let url else { return }
        let data: Data
        do { data = try UsageNowSync.encode(file) } catch { return }
        let local = url.deletingLastPathComponent().appendingPathComponent(UsageNowSync.localFileName)
        let synced: URL? = sync.isActive ? primaryFolder.map { UsageNowSync.fileURL(inSyncFolder: $0, machineID: machineID) } : nil
        let dest = local.path + "|" + (synced?.path ?? "")
        guard data != lastUsageNow || dest != lastUsageNowDest else { return }
        lastUsageNow = data
        lastUsageNowDest = dest
        usageNowQueue.async { [weak self] in
            var ok = true
            do { try UsageNowSync.write(data, to: local) } catch { ok = false }
            if let synced {
                do { try UsageNowSync.write(data, to: synced) } catch { ok = false }
            }
            guard !ok else { return }
            Task { @MainActor in
                // A failed write is retried the next time the numbers are published.
                if self?.lastUsageNow == data {
                    self?.lastUsageNow = nil
                    self?.lastUsageNowDest = nil
                }
            }
        }
    }

    private func recompute(now: Date = Date()) {
        var merged = others.isEmpty || !sync.isActive ? local : HistorySync.merge(local: local, others: others, now: now)
        merged.prune(now: now)
        if merged != history { history = merged }
    }

    private func scheduleSave() {
        guard let url else { return }
        pendingSave?.cancel()
        let snapshot = local
        let work = DispatchWorkItem { [weak self] in
            let failure: String?
            do { try snapshot.save(to: url); failure = nil } catch { failure = Self.describe(error) }
            Task { @MainActor in
                if self?.sync.localSaveError != failure { self?.sync.localSaveError = failure }
            }
        }
        pendingSave = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: Sync configuration

    /// The one sync folder (written and read) and any older folders that still hold history (read only).
    func updateFolders(primary: URL?, readOnly: [URL]) {
        guard primary != primaryFolder || readOnly != readOnlyFolders else { return }
        primaryFolder = primary
        readOnlyFolders = readOnly
        reconfigure()
    }

    func setEnabled(_ on: Bool) {
        guard on != sync.enabled else { return }
        sync.enabled = on
        defaults?.set(on, forKey: Self.enabledKey)
        reconfigure()
    }

    /// A history-only folder picked in 0.9.2–0.9.4 (Settings › Sync › Usage history). It's no longer offered,
    /// but its files are still read so nothing in it is lost.
    var legacyChosenFolder: URL? { chosenFolder }

    private func reconfigure() {
        watcher?.stop()
        watcher = nil
        pendingSync?.cancel()
        generation += 1
        sync.folder = primaryFolder
        sync.origin = primaryFolder == nil ? nil : .settingsSync
        var all: [URL] = primaryFolder.map { [$0] } ?? []
        for f in readOnlyFolders where !all.contains(where: { SyncFolderPlan.same($0, f) }) { all.append(f) }
        sync.folders = all
        sync.readOnlyFolders = Array(all.dropFirst())
        sync.ownFile = primaryFolder.map { HistorySync.fileURL(inSyncFolder: $0, machineID: machineID) }
        sync.writeError = nil
        sync.writeErrorAt = nil
        watchers.forEach { $0.stop() }
        watchers = []
        if !sync.isActive {
            sync.folders = []
            sync.readOnlyFolders = []
            others = []
            sync.machineCount = 0
            sync.machineNames = []
            sync.skipped = []
            sync.conflictCopies = []
            sync.lastError = nil
            recompute()
            flushUsageNow()
            return
        }
        syncNow(write: true)
        flushUsageNow()
    }

    /// The sync folder changed (or sync was turned off): write the same reading to the new place.
    private func flushUsageNow() {
        guard let data = lastUsageNow else { return }
        lastUsageNow = nil
        lastUsageNowDest = nil
        guard let file = try? UsageNowSync.decode(data) else { return }
        writeUsageNow(file)
    }

    // MARK: Syncing

    private func scheduleSync(write: Bool, after delay: TimeInterval) {
        pendingSync?.cancel()
        let work = DispatchWorkItem { [weak self] in Task { @MainActor in self?.syncNow(write: write) } }
        pendingSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Re-reads the other Macs' files (e.g. when the dropdown opens). Cheap: a few small JSON files.
    func refreshFromFolder() {
        guard sync.isActive else { return }
        syncNow(write: false)
    }

    /// Writes this Mac's file (atomically), then reads and merges every file in the folder. File work runs
    /// off the main thread; bad files are skipped and listed in Diagnostics.
    func syncNow(write: Bool = true) {
        guard sync.isActive, !sync.folders.isEmpty else { return }
        generation += 1
        let gen = generation
        let folders = sync.folders
        let payload = MachineHistoryFile(machineID: machineID, machineName: machineName, history: local)
        let id = machineID
        Task.detached(priority: .utility) {
            var writeErrors: [String] = []
            // Only the one sync folder is written; older folders are read so their Macs still merge in.
            if write, let folder = folders.first {
                do {
                    try HistorySync.write(payload, to: HistorySync.fileURL(inSyncFolder: folder, machineID: id))
                } catch {
                    writeErrors.append(Self.describe(error))
                }
            }
            var read = HistorySyncRead()
            for folder in folders {
                let r = HistorySync.readAll(directory: HistorySync.directory(inSyncFolder: folder))
                read.files += r.files
                read.skipped += r.skipped
                read.conflictCopies += r.conflictCopies
            }
            let result = read
            let writeError = writeErrors.isEmpty ? nil : writeErrors.joined(separator: "; ")
            await MainActor.run { [weak self] in
                guard let self, self.sync.folders == folders else { return }
                // Write results always land (a newer read-only refresh must not hide a failed write).
                if write { self.noteWrite(error: writeError) }
                guard gen == self.generation else { return }
                self.apply(result)
            }
        }
    }

    private func noteWrite(error: String?) {
        if let error {
            sync.writeError = error
            sync.writeErrorAt = Date()
        } else {
            sync.writeError = nil
            sync.writeErrorAt = nil
            sync.lastWrite = Date()
        }
        sync.lastError = sync.writeError
    }

    private func apply(_ read: HistorySyncRead) {
        others = read.files.map(\.history)
        sync.machineCount = read.machineCount
        sync.machineNames = read.machineNames
        sync.skipped = read.skipped
        sync.conflictCopies = read.conflictCopies
        sync.lastError = sync.writeError
        if sync.writeError == nil { sync.lastSync = Date() }
        recompute()
        if watcher == nil, let folder = sync.folder {
            let dir = HistorySync.directory(inSyncFolder: folder)
            let w = FolderWatcher(directory: dir, file: nil, pollInterval: 60) { [weak self] in
                Task { @MainActor in self?.refreshFromFolder() }
            }
            w.start()
            watcher = w
            for extra in sync.folders.dropFirst() {
                let w2 = FolderWatcher(directory: HistorySync.directory(inSyncFolder: extra), file: nil, pollInterval: 60) { [weak self] in
                    Task { @MainActor in self?.refreshFromFolder() }
                }
                w2.start()
                watchers.append(w2)
            }
        }
    }

    nonisolated private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return "No permission to write to the sync folder"
            case NSFileWriteOutOfSpaceError: return "Disk is full"
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError, NSFileWriteFileExistsError: return "Sync folder not found"
            default: break
            }
        }
        return "Couldn't write this Mac's history file"
    }

    // MARK: This Mac

    /// A stable, anonymous id for this Mac: a hash of the hardware UUID (so a Mac restored with Migration
    /// Assistant gets its own id), or a random UUID saved in UserDefaults if that isn't available.
    static func machineID(defaults: UserDefaults) -> String {
        if let hw = hardwareUUID() {
            let digest = SHA256.hash(data: Data("GrokGauge-history:\(hw)".utf8))
            return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        }
        if let saved = defaults.string(forKey: machineIDKey), !saved.isEmpty { return saved }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: machineIDKey)
        return fresh
    }

    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? String
    }

    /// The name in System Settings › General › Sharing (e.g. "Steven's Mac Studio").
    static func computerName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        return ProcessInfo.processInfo.hostName
    }

    /// Synthetic week for --render-preview --demo.
    /// `botShared`: Grok Bot is on the shared pool, so its share resets with the pool.
    static func demoHistory(grokNow: Double, botNow: Double, botShared: Bool = false, now: Date = Date()) -> UsageHistory {
        var h = UsageHistory()
        let start = now.addingTimeInterval(-7 * 86_400)
        for i in 0...56 {
            let t = start.addingTimeInterval(Double(i) * 3 * 3600)
            let f = Double(i) / 56
            // Grok: resets ~4.2 days ago, then climbs. Grok Bot: steady climb with a busy evening.
            let grokReset = now.addingTimeInterval(-4.2 * 86_400)
            let g: Double = t < grokReset
                ? 55 + 35 * (t.timeIntervalSince(start) / grokReset.timeIntervalSince(start))
                : grokNow * pow(t.timeIntervalSince(grokReset) / now.timeIntervalSince(grokReset), 0.9)
            // Usage only rises within a week, so the wobble never takes a value below the previous one
            // (a drop would read as a reset).
            let wobble = sin(Double(i) * 0.9) * 2.5
            let previousGrok = h.grok.last.flatMap { ($0.t < grokReset) == (t < grokReset) ? $0.p : nil } ?? 0
            h.record(.grok, percent: max(previousGrok, g + wobble * 0.4), at: t)
            if botShared {
                let b: Double = t < grokReset
                    ? 20 + 18 * (t.timeIntervalSince(start) / grokReset.timeIntervalSince(start))
                    : botNow * pow(t.timeIntervalSince(grokReset) / now.timeIntervalSince(grokReset), 1.1)
                let previousBot = h.grokBot.last.flatMap { ($0.t < grokReset) == (t < grokReset) ? $0.p : nil } ?? 0
                h.record(.grokBot, percent: max(previousBot, b + wobble * 0.3), at: t, shared: true)
            } else {
                h.record(.grokBot, percent: max(h.grokBot.last?.p ?? 0, botNow * pow(f, 1.15) + wobble), at: t)
            }
        }
        h.record(.grok, percent: grokNow, at: now)
        h.record(.grokBot, percent: botNow, at: now, shared: botShared ? true : nil)
        return h
    }
}
