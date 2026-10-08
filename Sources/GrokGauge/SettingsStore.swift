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
    /// A likely sync folder found on this Mac (e.g. "MacSyncing"), offered as a suggestion only.
    @Published private(set) var suggestedFolder: URL?

    static let settingsKey = "settings.v1"
    static let syncFolderKey = "sync.folderPath"
    static let legacyMenuBarStyleKey = "menuBar.style"

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
    }

    /// Inert store for previews: never touches UserDefaults or disk.
    static func preview(_ s: GaugeSettings = GaugeSettings(), syncFolder: URL? = nil, state: SyncState = .off) -> SettingsStore {
        let store = SettingsStore(persist: false)
        store.settings = s
        store.syncFolder = syncFolder
        store.syncState = state
        return store
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
            + "GrokGauge keeps one small settings.json in a GrokGauge subfolder."
        panel.directoryURL = syncFolder ?? suggestedFolder ?? FileManager.default.homeDirectoryForCurrentUser
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setSyncFolder(url)
    }

    func setSyncFolder(_ url: URL?) {
        stopWatching()
        syncFolder = url
        if persist {
            if let url { defaults.set(url.path, forKey: Self.syncFolderKey) } else { defaults.removeObject(forKey: Self.syncFolderKey) }
        }
        syncState = .off
        startWatching()
    }

    private func startWatching() {
        guard let folder = syncFolder else { return }
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
        guard let folder = syncFolder else { return }
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
        guard persist, syncFolder != nil else { return }
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
            await MainActor.run { self.suggestedFolder = hit }
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
