import AppKit
import Combine
import GrokGaugeCore
import UniformTypeIdentifiers

/// Owns the user's preferences: stores them locally, and (optionally) keeps them in sync with
/// `<sync folder>/GrokGauge/settings.json`. Only preferences ever go into that file.
@MainActor
final class SettingsStore: ObservableObject {
    enum SyncState: Equatable {
        case off
        case synced(Date)
        case failed(String)
    }

    @Published var settings: GaugeSettings {
        didSet { settingsDidChange(from: oldValue) }
    }
    /// Per-Mac choice; stored only in this Mac's UserDefaults.
    @Published private(set) var syncFolder: URL?
    @Published private(set) var syncState: SyncState = .off
    /// A likely sync folder found on this Mac (e.g. "MacSyncing"). Used automatically when no folder is set.
    @Published private(set) var suggestedFolder: URL?
    /// "Settings" toggle on the Sync tab (per Mac, on by default). History has its own toggle in HistoryStore.
    @Published private(set) var settingsSyncEnabled: Bool = true
    /// Other folders with GrokGauge history (older setups, other Macs on older versions): read, never written.
    @Published private(set) var readOnlyFolders: [URL] = []
    /// A folder more of your Macs use, offered when GrokGauge won't switch on its own.
    @Published private(set) var folderSuggestion: FolderSuggestion?
    /// The folder GrokGauge moved away from automatically (shown on the Diagnostics tab).
    @Published private(set) var migratedFrom: URL?

    struct FolderSuggestion: Equatable {
        var url: URL
        var otherMacs: Int
    }

    static let settingsKey = "settings.v1"
    static let syncFolderKey = "sync.folderPath"
    static let legacyMenuBarStyleKey = "menuBar.style"
    static let settingsSyncEnabledKey = "sync.settingsEnabled"
    /// Set by "Stop Syncing", so a found folder isn't picked up again on the next launch.
    static let stoppedKey = "sync.stoppedByUser"
    static let migratedFromKey = "sync.migratedFrom"

    /// For the folder survey: this Mac's history id and any older history-only folder (0.9.2–0.9.4).
    private var surveyMachineID = ""
    private var surveyLegacy: [URL] = []
    private var surveyGeneration = 0

    private let defaults: UserDefaults
    private let persist: Bool
    private var applyingRemote = false
    private var bumping = false
    private var watcher: FolderWatcher?
    private var pendingWrite: DispatchWorkItem?

    init(defaults: UserDefaults = .standard, persist: Bool = true) {
        self.defaults = defaults
        self.persist = persist
        if persist, let data = defaults.data(forKey: Self.settingsKey),
           let saved = try? SettingsSync.decode(data) {
            settings = saved
        } else if persist {
            // First launch of 0.9 (or a fresh install): carry over the 0.3 menu bar choice.
            settings = GaugeSettings.migratingFrom03(menuBarStyle: defaults.string(forKey: Self.legacyMenuBarStyleKey))
            save()
        } else {
            settings = GaugeSettings()
        }
        if persist, let path = defaults.string(forKey: Self.syncFolderKey) {
            syncFolder = URL(fileURLWithPath: path, isDirectory: true)
        }
        if persist {
            settingsSyncEnabled = defaults.object(forKey: Self.settingsSyncEnabledKey) as? Bool ?? true
            migratedFrom = defaults.string(forKey: Self.migratedFromKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
    }

    /// Inert store for previews: never touches UserDefaults or disk.
    static func preview(_ s: GaugeSettings = GaugeSettings(), syncFolder: URL? = nil, state: SyncState = .off,
                        settingsSyncEnabled: Bool = true, readOnly: [URL] = [], suggestion: FolderSuggestion? = nil,
                        migratedFrom: URL? = nil) -> SettingsStore {
        let store = SettingsStore(persist: false)
        store.settings = s
        store.syncFolder = syncFolder
        store.syncState = state
        store.settingsSyncEnabled = settingsSyncEnabled
        store.readOnlyFolders = readOnly
        store.folderSuggestion = suggestion
        store.migratedFrom = migratedFrom
        return store
    }

    /// The settings saved on this Mac, read without side effects (for --render-tour).
    static func savedSettings(defaults: UserDefaults = .standard) -> GaugeSettings {
        defaults.data(forKey: settingsKey).flatMap { try? SettingsSync.decode($0) } ?? GaugeSettings()
    }

    func start() {
        guard persist else { return }
        startWatching()
    }

    // MARK: Local changes

    private func settingsDidChange(from old: GaugeSettings) {
        guard !bumping else { return }
        if !applyingRemote, !settings.sameContent(as: old) {
            bumping = true
            settings.modifiedAt = Date()
            bumping = false
            scheduleSyncWrite()
        }
        save()
    }

    private func save() {
        guard persist, let data = try? SettingsSync.encode(settings) else { return }
        defaults.set(data, forKey: Self.settingsKey)
    }

    func resetLayout() { settings.resetLayout() }

    func resetColors() { settings.colors = .system }

    func resetAll() {
        let keepModified = settings.modifiedAt
        var fresh = GaugeSettings()
        fresh.modifiedAt = keepModified
        settings = fresh
    }

    // MARK: Sync

    func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder your Macs already sync (Google Drive, Insync, iCloud Drive, Dropbox…). "
            + "GrokGauge keeps settings.json and each Mac's history in a GrokGauge subfolder."
        panel.directoryURL = syncFolder ?? suggestedFolder ?? FileManager.default.homeDirectoryForCurrentUser
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setSyncFolder(url)
    }

    /// `byUser` is false for the automatic move to the folder your other Macs use.
    func setSyncFolder(_ url: URL?, byUser: Bool = true) {
        stopWatching()
        syncFolder = url
        folderSuggestion = nil
        if persist {
            if let url { defaults.set(url.path, forKey: Self.syncFolderKey) } else { defaults.removeObject(forKey: Self.syncFolderKey) }
            if byUser { defaults.set(url == nil, forKey: Self.stoppedKey) }
            if byUser, url != nil {
                migratedFrom = nil
                defaults.removeObject(forKey: Self.migratedFromKey)
            }
        }
        syncState = .off
        startWatching()
        if byUser { surveyFolders(allowSwitch: false) }
    }

    func setSettingsSyncEnabled(_ on: Bool) {
        guard on != settingsSyncEnabled else { return }
        settingsSyncEnabled = on
        if persist { defaults.set(on, forKey: Self.settingsSyncEnabledKey) }
        stopWatching()
        syncState = .off
        startWatching()
    }

    private var stoppedByUser: Bool { persist && defaults.bool(forKey: Self.stoppedKey) }

    // MARK: Choosing the one folder all Macs share

    func configureSurvey(machineID: String, legacy: [URL]) {
        surveyMachineID = machineID
        surveyLegacy = legacy
    }

    /// Looks for GrokGauge data in nearby folders (read-only), then: picks up the folder found automatically
    /// when none is set, moves to the folder the other Macs use when no other Mac uses this one, or offers it
    /// otherwise. Folders that still hold history are read (never written) so older versions merge in.
    func surveyFolders(allowSwitch: Bool = true) {
        guard persist else { return }
        surveyGeneration += 1
        let gen = surveyGeneration
        let current = syncFolder
        let detected = suggestedFolder
        let legacy = surveyLegacy + [migratedFrom].compactMap { $0 }
        let machineID = surveyMachineID
        Task.detached(priority: .utility) {
            let candidates = SyncFolderPlan.candidateFolders(current: current, detected: detected, legacy: legacy,
                                                            subfolders: Self.subfoldersWithGrokGauge)
            let surveys = candidates.map(SyncFolderSurvey.read)
            await MainActor.run { [weak self] in
                guard let self, gen == self.surveyGeneration, SyncFolderPlan.same(self.syncFolder, current) else { return }
                self.applySurvey(surveys, current: current, detected: detected, machineID: machineID, allowSwitch: allowSwitch)
            }
        }
    }

    private func applySurvey(_ surveys: [SyncFolderSurvey], current: URL?, detected: URL?, machineID: String, allowSwitch: Bool) {
        switch SyncFolderPlan.recommend(current: current, detected: detected, surveys: surveys, machineID: machineID) {
        case .autoSwitch(let url) where allowSwitch && !(current == nil && stoppedByUser):
            if let current {
                migratedFrom = current
                defaults.set(current.path, forKey: Self.migratedFromKey)
            }
            setSyncFolder(url, byUser: false)
            readOnlyFolders = SyncFolderPlan.readOnlyFolders(primary: url, surveys: surveys)
        case .suggest(let url, let n):
            folderSuggestion = FolderSuggestion(url: url, otherMacs: n)
            readOnlyFolders = SyncFolderPlan.readOnlyFolders(primary: current, surveys: surveys)
        default:
            folderSuggestion = nil
            readOnlyFolders = SyncFolderPlan.readOnlyFolders(primary: current, surveys: surveys)
        }
    }

    /// Immediate subfolders that contain a GrokGauge folder (one level, at most 200 entries looked at).
    nonisolated static func subfoldersWithGrokGauge(_ root: URL) -> [URL] {
        let fm = FileManager.default
        let kids = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
        return kids.prefix(200).filter { k in
            var dir: ObjCBool = false
            let marker = k.appendingPathComponent(SettingsSync.folderName, isDirectory: true).path
            return k.lastPathComponent != SettingsSync.folderName && fm.fileExists(atPath: marker, isDirectory: &dir) && dir.boolValue
        }
    }

    private func startWatching() {
        guard settingsSyncEnabled, let folder = syncFolder else { return }
        let file = SettingsSync.fileURL(inSyncFolder: folder)
        reconcile()
        let w = FolderWatcher(directory: file.deletingLastPathComponent(), file: file) { [weak self] in
            Task { @MainActor in self?.reconcile() }
        }
        w.start()
        watcher = w
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
        pendingWrite?.cancel()
    }

    /// Compares this Mac's settings with the shared file. Last write wins.
    func reconcile() {
        guard settingsSyncEnabled, let folder = syncFolder else { return }
        let file = SettingsSync.fileURL(inSyncFolder: folder)
        do {
            let remote = try SettingsSync.read(from: file)
            switch SettingsSync.resolve(local: settings, remote: remote) {
            case .inSync:
                syncState = .synced(Date())
            case .adoptRemote(let r):
                applyingRemote = true
                settings = r
                applyingRemote = false
                syncState = .synced(Date())
            case .writeLocal:
                try SettingsSync.write(settings, to: file)
                syncState = .synced(Date())
            }
        } catch {
            syncState = .failed(Self.describe(error))
        }
    }

    /// Debounced so dragging a slider writes once, not fifty times.
    private func scheduleSyncWrite() {
        guard persist, settingsSyncEnabled, syncFolder != nil else { return }
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.reconcile() }
        }
        pendingWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private static func describe(_ error: Error) -> String {
        if error is DecodingError { return "settings.json isn't a GrokGauge settings file" }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return "No permission to use that folder"
            case NSFileWriteOutOfSpaceError: return "Disk is full"
            case NSFileReadTooLargeError: return "settings.json is too large"
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return "Folder not found"
            default: break
            }
        }
        return "Couldn't read or write settings.json"
    }

    // MARK: Export / Import

    func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "GrokGauge Settings.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SettingsSync.encode(settings).write(to: url, options: .atomic)
        } catch {
            alert("Couldn't export settings", Self.describe(error))
        }
    }

    func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let imported = try SettingsSync.read(from: url) else { return }
            // An import is a change made on this Mac now, so it wins the next sync.
            var s = imported
            s.modifiedAt = settings.modifiedAt
            settings = s   // didSet stamps it as changed now if anything differs
        } catch {
            alert("Couldn't import settings", Self.describe(error))
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // MARK: Suggested folder

    /// Looks (read-only, shallow) for a folder named "MacSyncing" / "Mac Syncing" inside the
    /// usual cloud-drive folders in the home folder. Only ever offered as a suggestion.
    func findSuggestedFolder() {
        guard persist, suggestedFolder == nil else { return }
        Task.detached(priority: .utility) {
            let hit = Self.searchSuggestedFolder()
            await MainActor.run {
                self.suggestedFolder = hit
                self.surveyFolders()
            }
        }
    }

    nonisolated static func searchSuggestedFolder() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let names: Set<String> = ["macsyncing", "mac syncing", "mac sync"]
        let cloudHints = ["drive", "dropbox", "icloud", "onedrive", "sync", "box"]
        let roots = ((try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: [.skipsHiddenFiles])) ?? [])
            .filter { url in cloudHints.contains { url.lastPathComponent.lowercased().contains($0) } }
        // iCloud Drive and ~/Library/CloudStorage are deliberately not scanned: touching them can
        // trigger a macOS privacy prompt. Users can still pick folders there with "Choose…".
        if names.contains(home.lastPathComponent.lowercased()) { return home }

        var visited = 0
        var queue: [(URL, Int)] = roots.map { ($0, 0) }
        while !queue.isEmpty, visited < 4_000 {
            let (dir, depth) = queue.removeFirst()
            visited += 1
            if names.contains(dir.lastPathComponent.lowercased()) { return dir }
            guard depth < 4 else { continue }
            let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
            for k in kids {
                let v = try? k.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                if v?.isDirectory == true, v?.isPackage != true { queue.append((k, depth + 1)) }
            }
        }
        return nil
    }
}
