import AppKit
import GrokGaugeCore
import SwiftUI

enum PrefsTab: String, CaseIterable, Identifiable {
    case layout, menuBar, colors, sync, diagnostics, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .layout: return "Layout"
        case .menuBar: return "Menu Bar"
        case .colors: return "Colors & Alerts"
        case .sync: return "Sync"
        case .diagnostics: return "Diagnostics"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .layout: return "rectangle.3.group"
        case .menuBar: return "menubar.rectangle"
        case .colors: return "paintpalette"
        case .sync: return "arrow.triangle.2.circlepath"
        case .diagnostics: return "stethoscope"
        case .about: return "info.circle"
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var store: UsageStore
    @ObservedObject var updates: UpdateMonitor
    @ObservedObject var loginItem: LaunchAtLogin
    @ObservedObject var hotKeys: HotKeyCenter
    @ViewState var tab: PrefsTab = .layout
    /// false when rendering previews: lays everything out at full height instead of scrolling.
    var scrollable = true
    var tokenExpiry: () -> Date? = { nil }

    private var settings: Binding<GaugeSettings> { $settingsStore.settings }
    private var palette: Palette { Palette(settingsStore.settings) }

    var body: some View {
        VStack(spacing: 0) {
            TabBar(selection: $tab)
            Divider()
            if scrollable {
                ScrollView { page.padding(20) }
            } else {
                page.padding(20)
            }
        }
        .frame(width: 600)
        .frame(minHeight: scrollable ? 640 : nil, alignment: .top)
        .environment(\.palette, palette)
    }

    @ViewBuilder private var page: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch tab {
            case .layout: layoutTab
            case .menuBar: menuBarTab
            case .colors: colorsTab
            case .sync: syncTab
            case .diagnostics: DiagnosticsTab(store: store, settings: settingsStore.settings, tokenExpiry: tokenExpiry)
            case .about: aboutTab
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Layout

    private var layoutTab: some View {
        Group {
            PrefGroup(title: "Dropdown sections",
                      footer: "Drag rows (or use the arrows) to reorder. Unchecked sections are hidden. Changes apply right away.") {
                ReorderList(items: settings.sections, title: \.title,
                            icon: { AnyView(Image(systemName: $0.symbol).foregroundStyle(.secondary)) },
                            note: { s in
                                if s == .grokBotRing && !store.hasGrokBot { return "(Grok Bot not installed)" }
                                if s == .grokBotRing && settingsStore.settings.ringStyle == .combined { return "(part of the combined ring)" }
                                return nil
                            })
            }
            PrefGroup(title: "History graphs",
                      footer: "Shown in \u{201C}Last 7 days & pace\u{201D}. Turning both graphs off hides that section; "
                        + "its checkbox above works too. Bars show the highest % reached each day.") {
                Toggle("Grok history", isOn: settings.showGrokHistory)
                    .padding(.vertical, 6)
                Divider()
                HStack {
                    Toggle("Grok Bot history", isOn: settings.showGrokBotHistory)
                    if !store.hasGrokBot {
                        Text("(Grok Bot not installed)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                Divider()
                PrefRow(label: "Graph style") {
                    GraphStylePicker(selection: settings.graphStyle, tint: palette.color(.normal))
                }
                .padding(.vertical, 4)
                .disabled(!settingsStore.settings.showGrokHistory && !settingsStore.settings.showGrokBotHistory)
            }
            PrefGroup(title: "Rings") {
                Picker("Ring style", selection: settings.ringStyle) {
                    ForEach(RingStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .padding(.vertical, 6)
            }
            PrefGroup(title: "Action buttons", footer: "Open X opens the X app if it's installed, otherwise x.com. GrokGauge reads no X data.") {
                ReorderList(items: settings.actions, title: \.title, icon: { kind in
                    kind == .openX
                        ? AnyView(Text("𝕏").font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary))
                        : AnyView(Image(systemName: kind.symbol).foregroundStyle(.secondary))
                })
            }
            HStack {
                Spacer()
                Button("Reset Layout to Default") { settingsStore.resetLayout() }
            }
        }
    }

    // MARK: Menu bar

    private var menuBarTab: some View {
        let s = settingsStore.settings
        let mode = MenuBarLayout.effectiveMode(s.menuBarMode, hasGrokBot: store.hasGrokBot)
        let sample = MenuBarLayout.segments(
            grok: store.snapshot?.roundedPercent ?? 10, bot: store.botSnapshot?.roundedPercent ?? (store.hasGrokBot ? 86 : nil),
            grokDays: store.snapshot?.timeUntilReset().map(UsageFormat.wholeDays) ?? 5,
            botDays: store.botSnapshot?.timeUntilReset().map(UsageFormat.wholeDays),
            mode: mode, thresholds: s.thresholds, showDays: s.showDaysToReset)
        let logoLevel = MenuBarLayout.logoLevel(grok: store.snapshot?.roundedPercent ?? 10,
                                                bot: store.botSnapshot?.roundedPercent, thresholds: s.thresholds)
        return Group {
            PrefGroup(title: "Show in the menu bar",
                      footer: store.hasGrokBot ? nil : "Grok Bot isn't installed, so the Grok Bot options show Grok.") {
                Picker("Menu bar shows", selection: settings.menuBarMode) {
                    ForEach(MenuBarMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .padding(.vertical, 6)
                Divider()
                Toggle("Add days to reset (10% · 5d)", isOn: settings.showDaysToReset)
                    .padding(.vertical, 6)
                Divider()
                Toggle("Hide the GrokGauge logo", isOn: settings.hideLogo)
                    .disabled(s.menuBarMode == .logoOnly)
                    .padding(.vertical, 6)
                Divider()
                PrefRow(label: "Preview") {
                    MenuBarPreview(segments: sample.isEmpty && mode != .logoOnly ? [MenuBarSegment(text: " …", level: nil)] : sample,
                                   showLogo: mode == .logoOnly || !s.hideLogo,
                                   logoColor: mode == .logoOnly ? logoLevel.map { palette.color($0) } : nil,
                                   palette: palette)
                }
            }
            PrefGroup(title: "Keyboard shortcut",
                      footer: hotKeys.registrationFailed && s.hotKey.enabled
                        ? "⚠︎ macOS refused \(s.hotKey.display). Another app probably uses it; record a different one."
                        : "Opens or closes the GrokGauge dropdown from anywhere. Needs ⌃, ⌥ or ⌘.") {
                Toggle("Open the dropdown with a shortcut", isOn: settings.hotKey.enabled)
                    .padding(.vertical, 6)
                Divider()
                PrefRow(label: "Shortcut") {
                    HotKeyRecorder(hotKey: settings.hotKey, onRecording: { recording in
                        if recording { hotKeys.unregister() } else { hotKeys.register(settingsStore.settings.hotKey) }
                    })
                    .disabled(!s.hotKey.enabled)
                    Button("Reset") { settingsStore.settings.hotKey = .standard }
                        .disabled(s.hotKey == .standard)
                }
            }
        }
    }

    // MARK: Colors & alerts

    private var colorsTab: some View {
        let s = settingsStore.settings
        let tints = (palette.color(.normal), palette.color(.warning), palette.color(.critical))
        return Group {
            PrefGroup(title: "Levels",
                      footer: "0–\(s.thresholds.warningAbove)% normal · \(s.thresholds.warningAbove + 1)–\(s.thresholds.criticalAbove)% warning · \(s.thresholds.criticalAbove + 1)–100% critical. Used for the rings, the menu bar, and the product bars.") {
                RangeSlider(value: settings.thresholds, colors: tints)
                    .padding(.top, 8)
                Divider().padding(.vertical, 4)
                ThresholdFields(value: settings.thresholds)
                    .padding(.vertical, 4)
            }
            PrefGroup(title: "Colors", footer: similarityNote(s.colors)) {
                colorRow("Normal", .normal, s.colors.normal == nil)
                Divider()
                colorRow("Warning", .warning, s.colors.warning == nil)
                Divider()
                colorRow("Critical", .critical, s.colors.critical == nil)
                Divider()
                HStack {
                    Text("Presets").foregroundStyle(.secondary)
                    Spacer()
                    Button("Colorblind-Friendly") { settingsStore.settings.colors = .colorblindFriendly }
                        .help("Okabe–Ito blue / orange / vermilion")
                    Button("Reset Colors") { settingsStore.resetColors() }
                        .disabled(s.colors == .system)
                }
                .padding(.vertical, 7)
            }
            PrefGroup(title: "Notifications",
                      footer: "One notification per level per week, for Grok and Grok Bot separately.") {
                Toggle("Notify at the color levels", isOn: settings.notificationsLinked)
                    .padding(.vertical, 6)
                if !s.notificationsLinked {
                    Divider()
                    RangeSlider(value: settings.notificationThresholds, colors: tints)
                        .padding(.top, 8)
                    ThresholdFields(value: settings.notificationThresholds)
                        .padding(.vertical, 6)
                }
            }
            PrefGroup(title: "General") {
                PrefRow(label: "Refresh Grok every") {
                    Picker("Refresh every", selection: settings.refreshInterval) {
                        ForEach(RefreshInterval.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                Divider()
                PrefRow(label: "Launch at login", detail: loginItem.lastError) {
                    Toggle("Launch at login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }
    }

    private func colorRow(_ name: String, _ level: UsageLevel, _ isSystem: Bool) -> some View {
        PrefRow(label: name, detail: isSystem ? "System color" : settingsStore.settings.colors.color(for: level)?.hex) {
            ColorPicker(name, selection: colorBinding(level), supportsOpacity: false)
                .labelsHidden()
        }
    }

    private func colorBinding(_ level: UsageLevel) -> Binding<Color> {
        Binding(
            get: { palette.color(level) },
            set: { new in
                guard let rgba = RGBAColor(nsColor: NSColor(new)) else { return }
                switch level {
                case .normal: settingsStore.settings.colors.normal = rgba
                case .warning: settingsStore.settings.colors.warning = rgba
                case .critical: settingsStore.settings.colors.critical = rgba
                }
            })
    }

    private func similarityNote(_ colors: LevelColors) -> String {
        let pairs = colors.similarPairs()
        guard let (a, b) = pairs.first else { return "Click a color to open the macOS color picker." }
        let r = colors.resolved
        func rgba(_ l: UsageLevel) -> RGBAColor { l == .normal ? r.normal : l == .warning ? r.warning : r.critical }
        let dE = Int(ColorMath.deltaE2000(rgba(a), rgba(b)).rounded())
        return "⚠︎ \(a.rawValue.capitalized) and \(b.rawValue.capitalized) are hard to tell apart (ΔE \(dE)). Pick more distinct colors, or try the colorblind-friendly preset."
    }

    // MARK: Sync

    private var syncTab: some View {
        Group {
            PrefGroup(title: "Sync settings between Macs",
                      footer: "GrokGauge keeps one small file, **GrokGauge/settings.json**, in this folder and watches it for changes. The newest change wins. Only preferences sync — never your Grok login, usage numbers, or history. The folder choice stays on this Mac.") {
                PrefRow(label: "Folder", detail: settingsStore.syncFolder.map(Self.abbreviate) ?? "Not syncing") {
                    Button(settingsStore.syncFolder == nil ? "Choose…" : "Change…") { settingsStore.chooseSyncFolder() }
                    if settingsStore.syncFolder != nil {
                        Button("Stop Syncing") { settingsStore.setSyncFolder(nil) }
                    }
                }
                if settingsStore.syncFolder == nil, let hint = settingsStore.suggestedFolder {
                    Divider()
                    PrefRow(label: "Found a sync folder", detail: Self.abbreviate(hint)) {
                        Button("Use It") { settingsStore.setSyncFolder(hint) }
                    }
                }
                if settingsStore.syncFolder != nil {
                    Divider()
                    PrefRow(label: "Status", detail: syncStatusText) {
                        Button("Sync Now") { settingsStore.reconcile() }
                    }
                }
            }
            PrefGroup(title: "Back up or move settings", footer: "Exports the same JSON that sync uses. Importing counts as a change on this Mac.") {
                PrefRow(label: "Settings file") {
                    Button("Export…") { settingsStore.exportSettings() }
                    Button("Import…") { settingsStore.importSettings() }
                }
            }
            HStack {
                Spacer()
                Button("Reset All Settings…") {
                    let a = NSAlert()
                    a.messageText = "Reset all GrokGauge settings?"
                    a.informativeText = "Layout, menu bar, colors, alerts and the shortcut go back to their defaults. The sync folder choice is kept."
                    a.addButton(withTitle: "Reset")
                    a.addButton(withTitle: "Cancel")
                    if a.runModal() == .alertFirstButtonReturn { settingsStore.resetAll() }
                }
            }
        }
        .onAppear { settingsStore.findSuggestedFolder() }
    }

    private var syncStatusText: String {
        switch settingsStore.syncState {
        case .off: return "Waiting…"
        case .synced(let d): return "In sync · checked \(d.formatted(date: .omitted, time: .shortened))"
        case .failed(let m): return "⚠︎ \(m)"
        }
    }

    static func abbreviate(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = url.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    // MARK: About / updates

    private var aboutTab: some View {
        Group {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("GrokGauge").font(.title2.weight(.semibold))
                    Text("Version \(AppInfo.version)").foregroundStyle(.secondary)
                    Text("SuperGrok and Grok Bot usage in your menu bar. Unofficial; not affiliated with xAI.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            PrefGroup(title: "Updates",
                      footer: "Checks GitHub's public releases for stevencombs/GrokGauge (no account, no identifiers). Nothing installs automatically.") {
                Toggle("Check for updates daily", isOn: settings.checkForUpdates)
                    .padding(.vertical, 6)
                Divider()
                PrefRow(label: updateHeadline, detail: updateDetail) {
                    if updates.isChecking { ProgressView().controlSize(.small) }
                    Button("Check Now") { updates.checkNow() }
                        .disabled(updates.isChecking)
                }
                if let r = updates.available {
                    Divider()
                    PrefRow(label: "Update with Homebrew", detail: UpdateCheck.brewUpgradeCommand) {
                        Button("Copy Command") { UpdateMonitor.copyBrewCommand() }
                        Link("View Release", destination: r.url)
                    }
                }
            }
            PrefGroup(title: "Links") {
                PrefRow(label: "Source code & README") { Link("github.com/stevencombs/GrokGauge", destination: AppInfo.repoURL) }
                Divider()
                PrefRow(label: "Report a bug", detail: "Paste the report from the Diagnostics tab") {
                    Link("New issue", destination: AppInfo.repoURL.appendingPathComponent("issues/new/choose"))
                }
            }
        }
    }

    private var updateHeadline: String {
        if let r = updates.available { return "Version \(r.version) is available" }
        if updates.lastError != nil { return "Couldn't check for updates" }
        return updates.lastChecked == nil ? "Not checked yet" : "GrokGauge is up to date"
    }

    private var updateDetail: String? {
        guard let d = updates.lastChecked else { return nil }
        return "Last checked \(d.formatted(date: .abbreviated, time: .shortened))"
    }
}

// MARK: - Tab bar

private struct TabBar: View {
    @Binding var selection: PrefsTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PrefsTab.allCases) { t in
                Button { selection = t } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.symbol).font(.system(size: 17, weight: .regular)).frame(height: 20)
                        Text(t.title).font(.system(size: 11))
                    }
                    .frame(width: 88, height: 46)
                    .foregroundStyle(selection == t ? Color.accentColor : Color.secondary)
                    .background(selection == t ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(Color.clear),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.title)
                .accessibilityAddTraits(selection == t ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Diagnostics

struct DiagnosticsTab: View {
    @ObservedObject var store: UsageStore
    let settings: GaugeSettings
    let tokenExpiry: () -> Date?
    @ViewState var expiry: Date? = nil
    @ViewState var copied = false

    var body: some View {
        let report = Diagnostics.report(store: store, settings: settings, tokenExpiry: expiry)
        Group {
            ForEach(report.sources, id: \.name) { s in
                PrefGroup(title: s.name) {
                    PrefRow(label: "Status") { Text(s.status).foregroundStyle(.secondary) }
                    Divider()
                    PrefRow(label: "Last success") { Text(Self.time(s.lastSuccess)).foregroundStyle(.secondary) }
                    Divider()
                    PrefRow(label: "Last error") {
                        Text(s.lastError.map { e in "\(e)\(s.lastErrorAt.map { " · " + Self.time($0) } ?? "")" } ?? "None")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    Divider()
                    if s.name == "Grok" {
                        PrefRow(label: "Login expires", detail: "Renewed automatically before it runs out") {
                            Text(Self.time(s.tokenExpiresAt)).foregroundStyle(.secondary)
                        }
                    } else {
                        PrefRow(label: "Login", detail: "Read-only: GrokGauge reads Grok Bot's local usage cache, not its login") {
                            Text("Not used").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            PrefGroup(title: "This Mac", footer: "The report never includes tokens, emails, account ids, or file paths.") {
                PrefRow(label: "GrokGauge") { Text(report.appVersion).foregroundStyle(.secondary) }
                Divider()
                PrefRow(label: "macOS") { Text("\(report.macOSVersion) (\(report.architecture))").foregroundStyle(.secondary) }
                Divider()
                PrefRow(label: "Bug report") {
                    Button(copied ? "Copied" : "Copy Report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.text, forType: .string)
                        copied = true
                    }
                }
            }
        }
        .onAppear { expiry = tokenExpiry() }
    }

    static func time(_ d: Date?) -> String {
        guard let d else { return "—" }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
}

enum Diagnostics {
    @MainActor
    static func report(store: UsageStore, settings: GaugeSettings, tokenExpiry: Date?) -> DiagnosticsReport {
        let grokStatus: String
        if let p = store.problem { grokStatus = p.title } else if store.snapshot != nil {
            grokStatus = store.snapshot?.percentInferred == true ? "OK (percent inferred as 0)" : "OK"
        } else { grokStatus = "Loading" }
        let botStatus: String
        if let p = store.botProblem { botStatus = p.tooltip } else if store.botSnapshot != nil { botStatus = "OK" } else { botStatus = "Loading" }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "Apple silicon"
        #else
        let arch = "Intel"
        #endif
        var summary = [
            "Menu bar: \(settings.menuBarMode.title)\(settings.showDaysToReset ? " + days" : "")\(settings.hideLogo ? ", no logo" : "")",
            "Ring style: \(settings.ringStyle.title)",
            "History graphs: \(historyGraphSummary(settings))",
            "Levels: \(settings.thresholds.warningAbove)/\(settings.thresholds.criticalAbove)\(settings.notificationsLinked ? "" : ", alerts \(settings.notificationThresholds.warningAbove)/\(settings.notificationThresholds.criticalAbove)")",
            "Colors: \(settings.colors == .system ? "system" : settings.colors == .colorblindFriendly ? "colorblind-friendly" : "custom")",
            "Refresh: \(settings.refreshInterval.title)",
            "Shortcut: \(settings.hotKey.enabled ? settings.hotKey.display : "off")",
            "Update check: \(settings.checkForUpdates ? "on" : "off")",
        ]
        if let next = store.nextRetry { summary.append("Next retry: \(DiagnosticsReport.stamp(next))") }
        return DiagnosticsReport(
            appVersion: AppInfo.version,
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            architecture: arch,
            sources: [
                SourceDiagnostics(name: "Grok", status: grokStatus, lastSuccess: store.grokLastSuccess,
                                  lastError: store.grokLastError?.message, lastErrorAt: store.grokLastError?.at,
                                  tokenExpiresAt: tokenExpiry),
                SourceDiagnostics(name: "Grok Bot", status: store.hasGrokBot ? botStatus : "Not installed",
                                  lastSuccess: store.botLastSuccess,
                                  lastError: store.botLastError?.message, lastErrorAt: store.botLastError?.at),
            ],
            settingsSummary: summary)
    }
}

/// e.g. "Bars (Grok, Grok Bot)" or "off" (for the Diagnostics settings summary).
func historyGraphSummary(_ s: GaugeSettings) -> String {
    let shown = [s.showGrokHistory ? "Grok" : nil, s.showGrokBotHistory ? "Grok Bot" : nil].compactMap { $0 }
    guard s.isVisible(.historyPace), !shown.isEmpty else { return "off" }
    return "\(s.graphStyle.title) (\(shown.joined(separator: ", ")))"
}
