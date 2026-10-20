import AppKit
import GrokGaugeCore
import SwiftUI

/// `--render-tour DIR [--demo]`: every welcome-tour card in light and dark, plus the one-folder Sync tab,
/// rendered offscreen (no clicking, no Screen Recording permission). Never writes to UserDefaults or any
/// sync folder; never prints or writes the token.
extension PreviewRenderer {
    static func renderTour(to dir: URL, demo: Bool) async -> Int32 {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = UsageStore(notifier: UsageNotifier())
        var cli: GrokCLIState = .signedIn
        var settings = GaugeSettings()
        if demo {
            store.showPreview(sample, bot: sampleBot, botProblem: nil)
        } else {
            let snapshot: UsageSnapshot
            do {
                snapshot = try await BillingClient(appVersion: AppInfo.version).fetch()
            } catch {
                FileHandle.standardError.write(Data("error: could not fetch usage (run --print-usage for details)\n".utf8))
                return 1
            }
            var bot: GrokBotSnapshot?
            var botProblem: BotProblem?
            do { bot = try GrokBotUsageReader.read() } catch let e as GrokBotUsageError { botProblem = BotProblem(e) } catch { botProblem = .unrecognized }
            store.showPreview(snapshot, bot: bot, botProblem: botProblem)
            settings = SettingsStore.savedSettings()     // this Mac's real thresholds, colors and menu bar mode
            cli = store.cliState()
        }
        let settingsStore = SettingsStore.preview(settings)
        let suffix = demo ? "-demo" : ""
        var ok = true

        let slugs: [OnboardingStep: String] = [.welcome: "welcome", .connect: "connect", .rings: "rings", .sharedPool: "shared-pool",
                                               .menuBar: "menu-bar", .settingsSync: "settings-sync", .historyPace: "history-pace", .thanks: "tip"]
        for step in OnboardingStep.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let view = OnboardingView(store: store, settingsStore: settingsStore, cliState: { cli }, close: {},
                                          step: step, cli: cli)
                let name = String(format: "tour-%02d-%@-%@%@", step.number, slugs[step] ?? "step", scheme == .dark ? "dark" : "light", suffix)
                ok = renderView(view, scheme: scheme, background: true, to: dir.appendingPathComponent(name + ".png")) && ok
            }
        }
        // The Connect card when the Grok CLI still needs installing (light) — what a brand-new user sees.
        let fresh = OnboardingView(store: store, settingsStore: settingsStore, cliState: { .notInstalled }, close: {},
                                   step: .connect, cli: .notInstalled)
        ok = renderView(fresh, scheme: .light, background: true, to: dir.appendingPathComponent("tour-02-connect-not-installed-light\(suffix).png")) && ok

        // The redesigned Sync tab, from what's on this Mac's disk (read-only) or from demo data.
        let (syncSettings, syncHistory) = demo ? demoSync() : liveSync()
        let historyStore = HistoryStore.preview(UsageHistory(), sync: syncHistory.sync)
        for scheme in [ColorScheme.light, .dark] {
            let view = PreferencesView(settingsStore: syncSettings, store: store, updates: UpdateMonitor.preview(available: nil, lastChecked: Date()),
                                       loginItem: LaunchAtLogin(), hotKeys: HotKeyCenter.shared, whatsNew: WhatsNewStore.preview(WhatsNewStore.demoState()),
                                       history: historyStore, status: ServiceStatusStore.demo(), tab: .sync, scrollable: false, tokenExpiry: { nil })
            ok = renderView(view, scheme: scheme, background: true,
                            to: dir.appendingPathComponent("prefs-sync-\(scheme == .dark ? "dark" : "light")\(suffix).png")) && ok
        }
        let diag = PreferencesView(settingsStore: syncSettings, store: store, updates: UpdateMonitor.preview(available: nil, lastChecked: Date()),
                                   loginItem: LaunchAtLogin(), hotKeys: HotKeyCenter.shared, whatsNew: WhatsNewStore.preview(WhatsNewStore.demoState()),
                                   history: historyStore, status: ServiceStatusStore.demo(), tab: .diagnostics, scrollable: false, tokenExpiry: { nil })
        ok = renderView(diag, scheme: .dark, background: true, to: dir.appendingPathComponent("prefs-diagnostics-dark\(suffix).png")) && ok
        if demo {
            // A Mac whose folder other Macs also use, while more Macs use another one: offered, not moved.
            let folder = URL(fileURLWithPath: NSHomeDirectory() + "/Dropbox", isDirectory: true)
            let other = URL(fileURLWithPath: NSHomeDirectory() + "/Google Drive/MacSyncing", isDirectory: true)
            let s = SettingsStore.preview(GaugeSettings(), syncFolder: folder, state: .synced(Date().addingTimeInterval(-40)),
                                          suggestion: .init(url: other, otherMacs: 3))
            var st = HistoryStore.SyncStatus(enabled: true, folder: folder, origin: .settingsSync)
            st.machineCount = 2
            st.machineNames = ["Air-M4", "Studio M2"]
            st.lastSync = Date().addingTimeInterval(-40)
            let view = PreferencesView(settingsStore: s, store: store, updates: UpdateMonitor.preview(available: nil, lastChecked: Date()),
                                       loginItem: LaunchAtLogin(), hotKeys: HotKeyCenter.shared, whatsNew: WhatsNewStore.preview(WhatsNewStore.demoState()),
                                       history: HistoryStore.preview(UsageHistory(), sync: st), status: ServiceStatusStore.demo(),
                                       tab: .sync, scrollable: false, tokenExpiry: { nil })
            ok = renderView(view, scheme: .dark, background: true, to: dir.appendingPathComponent("prefs-sync-suggestion-dark-demo.png")) && ok
        }
        print(ok ? "wrote tour previews to \(dir.path)" : "some previews failed")
        return ok ? 0 : 1
    }

    private static func demoSync() -> (SettingsStore, HistoryStore) {
        let folder = URL(fileURLWithPath: NSHomeDirectory() + "/Google Drive/Computers/Mac/MacSyncing", isDirectory: true)
        let legacy = folder.appendingPathComponent("xAI", isDirectory: true)
        let now = Date().addingTimeInterval(-75)
        let settings = SettingsStore.preview(GaugeSettings(), syncFolder: folder, state: .synced(now), readOnly: [legacy], migratedFrom: legacy)
        var st = HistoryStore.SyncStatus(enabled: true, folder: folder, origin: .settingsSync,
                                         ownFile: HistorySync.fileURL(inSyncFolder: folder, machineID: "3f9c2a7d41b08e55"),
                                         machineCount: 3, machineNames: ["Air-M4", "MacBook Pro M2 Max", "Studio M2"], lastSync: now)
        st.folders = [folder, legacy]
        st.readOnlyFolders = [legacy]
        st.lastWrite = now
        return (settings, HistoryStore.preview(UsageHistory(), sync: st))
    }

    /// What this Mac will do on its next launch, worked out read-only from its own disk and UserDefaults.
    private static func liveSync() -> (SettingsStore, HistoryStore) {
        let d = UserDefaults.standard
        let current = d.string(forKey: SettingsStore.syncFolderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let legacy = d.string(forKey: HistoryStore.folderKey).map { [URL(fileURLWithPath: $0, isDirectory: true)] } ?? []
        let detected = SettingsStore.searchSuggestedFolder()
        let machineID = HistoryStore.machineID(defaults: d)
        let candidates = SyncFolderPlan.candidateFolders(current: current, detected: detected, legacy: legacy,
                                                        subfolders: SettingsStore.subfoldersWithGrokGauge)
        let surveys = candidates.map(SyncFolderSurvey.read)
        var primary = current
        var migrated: URL?
        var suggestion: SettingsStore.FolderSuggestion?
        switch SyncFolderPlan.recommend(current: current, detected: detected, surveys: surveys, machineID: machineID) {
        case .autoSwitch(let u):
            migrated = current
            primary = u
        case .suggest(let u, let n): suggestion = .init(url: u, otherMacs: n)
        case .keep: break
        }
        let readOnly = SyncFolderPlan.readOnlyFolders(primary: primary, surveys: surveys)
        var read = HistorySyncRead()
        for f in (primary.map { [$0] } ?? []) + readOnly {
            let r = HistorySync.readAll(directory: HistorySync.directory(inSyncFolder: f))
            read.files += r.files
            read.skipped += r.skipped
            read.conflictCopies += r.conflictCopies
        }
        let enabled = HistorySyncFolder.isEnabled(stored: d.object(forKey: HistoryStore.enabledKey) as? Bool)
        var st = HistoryStore.SyncStatus(enabled: enabled, folder: primary, origin: primary == nil ? nil : .settingsSync,
                                         ownFile: primary.map { HistorySync.fileURL(inSyncFolder: $0, machineID: machineID) },
                                         machineCount: read.machineCount, machineNames: read.machineNames, lastSync: Date(),
                                         skipped: read.skipped, conflictCopies: read.conflictCopies)
        st.folders = (primary.map { [$0] } ?? []) + readOnly
        st.readOnlyFolders = readOnly
        st.lastWrite = Date()
        let settings = SettingsStore.preview(savedSettings(), syncFolder: primary, state: .synced(Date()),
                                             settingsSyncEnabled: d.object(forKey: SettingsStore.settingsSyncEnabledKey) as? Bool ?? true,
                                             readOnly: readOnly, suggestion: suggestion, migratedFrom: migrated)
        FileHandle.standardError.write(Data("sync plan: \(current?.lastPathComponent ?? "none") -> \(primary?.lastPathComponent ?? "none"), reading \(readOnly.count) older folder(s), \(read.machineCount) Macs\n".utf8))
        return (settings, HistoryStore.preview(UsageHistory(), sync: st))
    }

    private static func savedSettings() -> GaugeSettings { SettingsStore.savedSettings() }
}
