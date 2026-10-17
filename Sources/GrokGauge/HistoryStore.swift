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
    private var settingsFolder: URL?
    private var detectedFolder: URL?
    private var pendingSave: DispatchWorkItem?
    private var pendingSync: DispatchWorkItem?
    private var watcher: FolderWatcher?
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

    func record(_ source: HistorySource, percent: Double, at time: Date) {
        var h = local
        h.record(source, percent: percent, at: time)
        h.prune()
        guard h != local else { return }
        local = h
        recompute()
        scheduleSave()
        if sync.isActive { scheduleSync(write: true, after: 3) }
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
        let work = DispatchWorkItem { try? snapshot.save(to: url) }
        pendingSave = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: Sync configuration

    /// The settings-sync folder and the auto-detected folder changed (from SettingsStore).
    func updateFolders(settingsSync: URL?, detected: URL?) {
        guard settingsSync != settingsFolder || detected != detectedFolder else { return }
        settingsFolder = settingsSync
        detectedFolder = detected
        reconfigure()
    }

    func setEnabled(_ on: Bool) {
        guard on != sync.enabled else { return }
        sync.enabled = on
        defaults?.set(on, forKey: Self.enabledKey)
        reconfigure()
    }

    /// nil goes back to the settings-sync / auto-detected folder.
    func setChosenFolder(_ folder: URL?) {
        chosenFolder = folder
        if let folder { defaults?.set(folder.path, forKey: Self.folderKey) } else { defaults?.removeObject(forKey: Self.folderKey) }
        reconfigure()
    }

    var hasChosenFolder: Bool { chosenFolder != nil }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder all your Macs sync (Google Drive, Insync, iCloud Drive, Dropbox…). "
            + "Each Mac keeps one small file in GrokGauge/history."
        panel.directoryURL = sync.folder ?? FileManager.default.homeDirectoryForCurrentUser
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setChosenFolder(url)
    }

    /// iCloud Drive's root (`~/Library/Mobile Documents/com~apple~CloudDocs`), when it's turned on.
    nonisolated static var iCloudDrive: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func useICloudDrive() {
        guard let icloud = Self.iCloudDrive else {
            let a = NSAlert()
            a.messageText = "iCloud Drive isn't turned on"
            a.informativeText = "Turn on iCloud Drive in System Settings › Apple Account › iCloud, or choose another folder."
            a.runModal()
            return
        }
        setChosenFolder(icloud)
    }

    private func reconfigure() {
        watcher?.stop()
        watcher = nil
        pendingSync?.cancel()
        generation += 1
        let resolved = HistorySyncFolder.resolve(chosen: chosenFolder, settingsSync: settingsFolder, detected: detectedFolder)
        sync.folder = resolved?.url
        sync.origin = resolved?.origin
        sync.ownFile = resolved.map { HistorySync.fileURL(inSyncFolder: $0.url, machineID: machineID) }
        if !sync.isActive {
            others = []
            sync.machineCount = 0
            sync.machineNames = []
            sync.skipped = []
            sync.conflictCopies = []
            sync.lastError = nil
            recompute()
            return
        }
        syncNow(write: true)
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
        guard sync.isActive, let folder = sync.folder, let ownFile = sync.ownFile else { return }
        generation += 1
        let gen = generation
        let payload = MachineHistoryFile(machineID: machineID, machineName: machineName, history: local)
        let dir = HistorySync.directory(inSyncFolder: folder)
        Task.detached(priority: .utility) {
            let writeError: String? = {
                guard write else { return nil }
                do { try HistorySync.write(payload, to: ownFile); return nil } catch { return Self.describe(error) }
            }()
            let read = HistorySync.readAll(directory: dir)
            await MainActor.run { [weak self] in
                guard let self, gen == self.generation else { return }
                self.apply(read, writeError: writeError)
            }
        }
    }

    private func apply(_ read: HistorySyncRead, writeError: String?) {
        others = read.files.map(\.history)
        sync.machineCount = read.machineCount
        sync.machineNames = read.machineNames
        sync.skipped = read.skipped
        sync.conflictCopies = read.conflictCopies
        sync.lastError = writeError
        if writeError == nil { sync.lastSync = Date() }
        recompute()
        if watcher == nil, let folder = sync.folder {
            let dir = HistorySync.directory(inSyncFolder: folder)
            let w = FolderWatcher(directory: dir, file: nil, pollInterval: 60) { [weak self] in
                Task { @MainActor in self?.refreshFromFolder() }
            }
            w.start()
            watcher = w
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
    static func demoHistory(grokNow: Double, botNow: Double, now: Date = Date()) -> UsageHistory {
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
            h.record(.grokBot, percent: max(h.grokBot.last?.p ?? 0, botNow * pow(f, 1.15) + wobble), at: t)
        }
        h.record(.grok, percent: grokNow, at: now)
        h.record(.grokBot, percent: botNow, at: now)
        return h
    }
}
