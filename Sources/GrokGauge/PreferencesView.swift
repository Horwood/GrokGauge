import AppKit
import GrokGaugeCore
import SwiftUI

enum PrefsTab: String, CaseIterable, Identifiable {
    case layout, menuBar, colors, whatsNew, sync, diagnostics, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .layout: return "Layout"
        case .menuBar: return "Menu Bar"
        case .colors: return "Colors & Alerts"
        case .whatsNew: return "What's New"
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
        case .whatsNew: return "newspaper"
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
    @ObservedObject var whatsNew: WhatsNewStore
    @ObservedObject var history: HistoryStore
    @ObservedObject var status: ServiceStatusStore = .preview([:])
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
            case .whatsNew: WhatsNewPrefs(settings: settings, store: whatsNew)
            case .sync: syncTab
            case .diagnostics: DiagnosticsTab(store: store, whatsNew: whatsNew, history: history, status: status, settings: settingsStore.settings, tokenExpiry: tokenExpiry,
                                              migratedFrom: settingsStore.migratedFrom)
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
                                if s == .grokRing { return "(the whole weekly pool)" }
                                if s == .regularGrokRing { return "(regular Grok use: Total minus Grok Bot and Cursor)" }
                                if s == .cursorRing { return "(Cursor's share of the pool; off by default)" }
                                return nil
                            })
            }
            PrefGroup(title: "History graphs",
                      footer: "Shown in \u{201C}Last 7 days & pace\u{201D}. Turning both graphs off hides that section; "
                        + "its checkbox above works too. Bars show the highest % reached each day.") {
                Toggle("Total (whole pool) history", isOn: settings.showGrokHistory)
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
                HStack {
                    Toggle("Cursor history", isOn: settings.showCursorHistory)
                    if !settingsStore.settings.isVisible(.cursorRing) {
                        Text("(shown while the Cursor ring is on)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                Divider()
                PrefRow(label: "Graph style") {
                    GraphStylePicker(selection: settings.graphStyle, tint: palette.color(.normal))
                }
                .padding(.vertical, 4)
                .disabled(!settingsStore.settings.showGrokHistory && !settingsStore.settings.showGrokBotHistory
                          && !settingsStore.settings.showsCursorHistory)
            }
            PrefGroup(title: "Service status",
                      footer: "Dots for the public xAI (status.x.ai) and Cursor (status.cursor.com) status pages, checked about "
                        + "every 5 minutes and when you open the dropdown. No login; nothing about you is sent. Click a dot to open "
                        + "the page. Cursor's page also covers Grok Bot and Cloud Agents.") {
                Toggle("xAI (Grok, grok.com, API, Imagine, Voice)", isOn: settings.serviceStatus.xai)
                    .padding(.vertical, 6)
                Divider()
                Toggle("Cursor (Grok Bot, Cloud Agents, IDE)", isOn: settings.serviceStatus.cursor)
                    .padding(.vertical, 6)
                Divider()
                Toggle("Notify me when a service goes from normal to an outage", isOn: settings.serviceStatus.notify)
                    .padding(.vertical, 6)
                    .disabled(settingsStore.settings.serviceStatus.enabled.isEmpty)
            }
            .disabled(!settingsStore.settings.isVisible(.serviceStatus))
            PrefGroup(title: "Grok by product",
                      footer: "Check the products to show and drag (or use the arrows) to set My order. "
                        + "Other sorts fall back to My order for ties. Products xAI adds later appear at the end, shown. "
                        + "Unchecking every product hides the section.") {
                ProductReorderList(items: Binding(
                    get: { settingsStore.settings.productBreakdown.listing(including: store.snapshot?.products ?? []) },
                    set: { settingsStore.settings.productBreakdown.order = $0 }))
                Divider()
                PrefRow(label: "Sort") {
                    Picker("Sort", selection: settings.productBreakdown.sort) {
                        ForEach(ProductSort.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Reset") { settingsStore.settings.productBreakdown.reset() }
                        .disabled(settingsStore.settings.productBreakdown.isDefault)
                }
                .padding(.vertical, 4)
            }
            .disabled(!settingsStore.settings.isVisible(.productBreakdown))
            PrefGroup(title: "Rings",
                      footer: "The Total ring is your whole SuperGrok weekly pool. The Grok, Grok Bot and Cursor rings are "
                        + "each one's slice of it, labeled \u{201C}share of pool\u{201D}, and add up to the Total. Grok "
                        + "(grok.com, the apps, Imagine, Voice, API) is worked out as Total minus Grok Bot and Cursor. "
                        + "The Cursor ring needs no Cursor sign-in.") {
                Picker("Ring style", selection: settings.ringStyle) {
                    ForEach(RingStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .padding(.vertical, 6)
                Divider()
                Toggle("Show the Cursor ring", isOn: Binding(
                    get: { settingsStore.settings.isVisible(.cursorRing) },
                    set: { on in
                        if let i = settingsStore.settings.sections.firstIndex(where: { $0.id == .cursorRing }) {
                            settingsStore.settings.sections[i].visible = on
                        }
                    }))
                    .padding(.vertical, 6)
                Divider()
                PrefRow(label: "With three or four rings") {
                    Picker("With three or four rings", selection: settings.ringSizing) {
                        ForEach(RingSizing.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.vertical, 4)
                .disabled(DropdownSection.rings.filter { settingsStore.settings.isVisible($0) && ($0 != .grokBotRing || store.hasGrokBot) }.count < 3
                          || settingsStore.settings.ringStyle != .sideBySide)
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
            grok: store.snapshot?.roundedPercent ?? 10,
            bot: store.botRing.map { MenuBarLayout.botPercent($0) } ?? (store.hasGrokBot ? 27 : nil),
            grokDays: store.snapshot?.timeUntilReset().map(UsageFormat.wholeDays) ?? 5,
            botDays: store.botRing?.timeUntilReset().map(UsageFormat.wholeDays),
            mode: mode, thresholds: s.thresholds, showDays: s.showDaysToReset)
        let logoLevel = MenuBarLayout.logoLevel(grok: store.snapshot?.roundedPercent ?? 10,
                                                bot: MenuBarLayout.botPercent(store.botRing), thresholds: s.thresholds)
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

    /// One folder for everything: settings and the 7-day history each have a switch, one status line and one
    /// Sync Now. Older folders that still hold history are read quietly (listed on the Diagnostics tab).
    private var syncTab: some View {
        let folder = settingsStore.syncFolder
        return Group {
            PrefGroup(title: "Sync between Macs",
                      footer: "GrokGauge keeps **settings.json** and **history/<this Mac>.json** in a **GrokGauge** subfolder of this folder. Only preferences and usage percentages go there, never your Grok login. Every Mac's readings are combined (highest wins), not added. The folder choice stays on this Mac.") {
                PrefRow(label: "Folder", detail: folder.map(Self.abbreviate) ?? "Not syncing. Settings and history stay on this Mac.") {
                    Button(folder == nil ? "Choose…" : "Change…") { settingsStore.chooseSyncFolder() }
                    if folder != nil {
                        Button("Stop Syncing") { settingsStore.setSyncFolder(nil) }
                    }
                }
                if folder == nil, let hint = settingsStore.suggestedFolder {
                    Divider()
                    PrefRow(label: "Found a sync folder", detail: Self.abbreviate(hint)) {
                        Button("Use It") { settingsStore.setSyncFolder(hint) }
                    }
                }
                if let s = settingsStore.folderSuggestion {
                    Divider()
                    PrefRow(label: "Your other Macs use another folder",
                            detail: "\(Self.abbreviate(s.url)) · \(s.otherMacs == 1 ? "1 other Mac" : "\(s.otherMacs) other Macs")") {
                        Button("Switch") { settingsStore.setSyncFolder(s.url) }
                    }
                }
                if folder != nil {
                    Divider()
                    PrefRow(label: "Status", detail: syncStatusLine) {
                        Button("Sync Now") {
                            settingsStore.reconcile()
                            history.syncNow()
                        }
                        .disabled(!settingsStore.settingsSyncEnabled && !history.sync.enabled)
                    }
                }
                Divider()
                PrefRow(label: "Settings", detail: "Layout, menu bar, colors, alerts and the shortcut. The newest change wins.") {
                    Toggle("Settings", isOn: Binding(get: { settingsStore.settingsSyncEnabled }, set: { settingsStore.setSettingsSyncEnabled($0) }))
                        .toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel("Sync settings")
                }
                Divider()
                PrefRow(label: "7-day usage history", detail: "Each Mac's readings, merged into the history graphs.") {
                    Toggle("7-day usage history", isOn: Binding(get: { history.sync.enabled }, set: { history.setEnabled($0) }))
                        .toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel("Sync 7-day usage history")
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

    /// Settings + history in one line, e.g. "In sync · 3 Macs (Air-M4, …) · synced 11:38 PM".
    private var syncStatusLine: String {
        let settingsPart: SyncSummary.SettingsPart
        if !settingsStore.settingsSyncEnabled { settingsPart = .off } else {
            switch settingsStore.syncState {
            case .off: settingsPart = .waiting
            case .synced(let d): settingsPart = .synced(d)
            case .failed(let m): settingsPart = .failed(m)
            }
        }
        let h = history.sync
        let historyPart = SyncSummary.HistoryPart(
            enabled: h.enabled, machineCount: h.machineCount, machineNames: h.machineNames, lastSync: h.lastSync,
            error: h.writeError ?? h.lastError ?? h.localSaveError.map { "history.json: \($0)" }, skipped: h.skipped.count)
        return SyncSummary.line(settings: settingsPart, history: historyPart) { $0.formatted(date: .omitted, time: .shortened) }
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
                    Text("SuperGrok and Grok Bot usage in your menu bar. Unofficial; not affiliated with xAI or Cursor.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            MakerCard()
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
        HStack(spacing: 2) {
            ForEach(PrefsTab.allCases) { t in
                Button { selection = t } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.symbol).font(.system(size: 17, weight: .regular)).frame(height: 20)
                        Text(t.title).font(.system(size: 11))
                    }
                    .frame(width: 80, height: 46)
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
    @ObservedObject var whatsNew: WhatsNewStore
    @ObservedObject var history: HistoryStore
    @ObservedObject var status: ServiceStatusStore
    let settings: GaugeSettings
    let tokenExpiry: () -> Date?
    /// Where sync moved from automatically (0.9.5 one-folder migration), if it did.
    var migratedFrom: URL? = nil
    @ViewState var expiry: Date? = nil
    @ViewState var copied = false

    var body: some View {
        let report = Diagnostics.report(store: store, whatsNew: whatsNew, history: history, status: status, settings: settings, tokenExpiry: expiry)
        let news = Set(NewsSource.allCases.map(\.title))
        let statusRows = Set(ServiceSource.allCases.map { "\($0.title) status" })
        Group {
            ForEach(report.sources.filter { !news.contains($0.name) && !statusRows.contains($0.name) }, id: \.name) { s in
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
                        Divider()
                        cliRow
                    } else {
                        PrefRow(label: "Login", detail: "Read-only: GrokGauge reads Grok Bot's local usage cache, not its login") {
                            Text("Not used").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            PrefGroup(title: "What's new from xAI", footer: "Public pages only, no login. Failed checks retry after 5 min, 10, 20 … up to the check interval.") {
                let rows = report.sources.filter { news.contains($0.name) }
                ForEach(Array(rows.enumerated()), id: \.element.name) { i, s in
                    if i > 0 { Divider() }
                    PrefRow(label: s.name, detail: newsDetail(s)) {
                        Text(s.status).foregroundStyle(.secondary).multilineTextAlignment(.trailing).lineLimit(2)
                    }
                }
            }
            statusGroup
            historyGroup
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

    /// Service status: last result, error and the URL used, per source.
    @ViewBuilder private var statusGroup: some View {
        PrefGroup(title: "Service status", footer: "Public status pages, no login. Checked every 5 min; failed checks retry after 5, 10, 20, then every 30 min.") {
            ForEach(Array(ServiceSource.allCases.enumerated()), id: \.element) { i, s in
                let st = status.state(s)
                if i > 0 { Divider() }
                PrefRow(label: s.title, detail: statusDetail(s, st)) {
                    Text(!settings.serviceStatus.isOn(s) ? "Off" : st.lastError != nil ? "⚠︎ \(st.lastError!)" : st.report?.summary ?? "Not checked yet")
                        .foregroundStyle(.secondary).multilineTextAlignment(.trailing).lineLimit(2)
                }
            }
        }
    }

    private func statusDetail(_ s: ServiceSource, _ st: ServiceStatusStore.SourceState) -> String {
        var parts: [String] = []
        if let r = st.report { parts.append("Checked \(Self.time(r.checkedAt))") }
        if let at = st.lastErrorAt { parts.append("Failed \(Self.time(at))") }
        if let f = st.fallbackReason { parts.append("Summary failed (\(f)), used the RSS feed") }
        parts.append((st.lastURL ?? s.summaryURL).absoluteString)
        return parts.joined(separator: " · ")
    }

    /// History sync: folder, Macs, last sync, and any file that had to be skipped.
    @ViewBuilder private var historyGroup: some View {
        let s = history.sync
        PrefGroup(title: "History sync", footer: s.isActive ? "Files GrokGauge can't read are skipped (never deleted); the rest still merge." : nil) {
            PrefRow(label: "Status") {
                Text(!s.enabled ? "Off" : s.folder == nil ? "Local only (no sync folder)" : s.writeError.map { "⚠︎ \($0)" } ?? s.lastError ?? "On")
                    .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            if let e = s.localSaveError {
                Divider()
                PrefRow(label: "This Mac's history.json", detail: "~/Library/Application Support/GrokGauge/history.json") {
                    Text("⚠︎ \(e)").foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            }
            if s.isActive {
                Divider()
                PrefRow(label: "Folder", detail: migratedFrom.map { "Moved here automatically from \(PreferencesView.abbreviate($0)), the folder your other Macs use." }) {
                    Text(s.folder.map(PreferencesView.abbreviate) ?? "—").foregroundStyle(.secondary)
                        .lineLimit(3).multilineTextAlignment(.trailing).textSelection(.enabled)
                }
                if !s.readOnlyFolders.isEmpty {
                    Divider()
                    PrefRow(label: "Other folders found",
                            detail: "Older sync folders that still hold GrokGauge history. They're read (never written), so Macs on older versions still merge in.") {
                        Text(s.readOnlyFolders.map(PreferencesView.abbreviate).joined(separator: "\n")).foregroundStyle(.secondary)
                            .lineLimit(4).multilineTextAlignment(.trailing).textSelection(.enabled)
                    }
                }
                Divider()
                PrefRow(label: "This Mac's file", detail: s.ownFile.map { PreferencesView.abbreviate($0) }) {
                    Text(s.writeError.map { "⚠︎ Write failed · \($0)\(s.writeErrorAt.map { " · " + Self.time($0) } ?? "")" }
                         ?? s.lastWrite.map { "Written \(Self.time($0))" } ?? "Not written yet")
                        .foregroundStyle(.secondary).multilineTextAlignment(.trailing).textSelection(.enabled)
                }
                Divider()
                PrefRow(label: "Macs", detail: s.machineNames.isEmpty ? nil : s.machineNames.joined(separator: ", ")) {
                    Text("\(s.machineCount)").foregroundStyle(.secondary)
                }
                Divider()
                PrefRow(label: "Last sync") { Text(Self.time(s.lastSync)).foregroundStyle(.secondary) }
                if !s.conflictCopies.isEmpty {
                    Divider()
                    PrefRow(label: "Conflict copies", detail: s.conflictCopies.joined(separator: ", ")) {
                        Text("\(s.conflictCopies.count) merged").foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(s.skipped.enumerated()), id: \.offset) { _, skip in
                    Divider()
                    PrefRow(label: "Skipped file", detail: skip.fileName) {
                        Text("⚠︎ \(skip.reason)").foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
            }
        }
    }

    /// Grok CLI setup state, with the next step when something's missing.
    @ViewBuilder private var cliRow: some View {
        switch store.cliState() {
        case .notInstalled:
            PrefRow(label: "Grok CLI", detail: "Needed for Grok usage (Grok Bot works without it). Install: \(GrokCLISetup.installCommand)") {
                Button("Copy Install Command") { Launcher.copyInstallCommand() }
                Button("Install in Terminal…") { Launcher.installCLIInTerminal() }
            }
        case .signedOut:
            PrefRow(label: "Grok CLI", detail: store.cli()?.kind == .installer
                    ? "Installed, not signed in. Run “grok login” (or “\(GrokCLISetup.fallbackLoginCommand)”)."
                    : "Installed, not signed in. Run “grok login” in Terminal.") {
                Button("Copy “grok login”") { Launcher.copyLoginCommand() }
                Button("Open Terminal") { Launcher.openTerminal() }
            }
        case .signedIn:
            PrefRow(label: "Grok CLI") {
                Text("Signed in\(store.cli().map { " · \($0.summary)" } ?? "")").foregroundStyle(.secondary)
            }
        }
    }

    private func newsDetail(_ s: SourceDiagnostics) -> String? {
        var parts: [String] = []
        if let d = s.lastSuccess { parts.append("Checked \(Self.time(d))") }
        if let e = s.lastError, let at = s.lastErrorAt, at > (s.lastSuccess ?? .distantPast) {
            parts.append("Error: \(e) · \(Self.time(at))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func time(_ d: Date?) -> String {
        guard let d else { return "—" }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
}

enum Diagnostics {
    @MainActor
    static func report(store: UsageStore, whatsNew: WhatsNewStore? = nil, history: HistoryStore? = nil,
                       status: ServiceStatusStore? = nil, settings: GaugeSettings, tokenExpiry: Date?) -> DiagnosticsReport {
        let grokStatus: String
        if let p = store.problem { grokStatus = p.title } else if store.snapshot != nil {
            grokStatus = store.snapshot?.percentInferred == true ? "OK (percent inferred as 0)" : "OK"
        } else { grokStatus = "Loading" }
        let botStatus: String
        if let p = store.botProblem {
            botStatus = p.tooltip
        } else if let r = store.botRing {
            botStatus = r.isShared
                ? "OK · on the shared Grok pool (own reading \(r.own.roundedPercent)% = whole pool; ring shows its \(r.roundedPercent.map { "\($0)%" } ?? "…") share)"
                : "OK · own weekly allowance"
        } else { botStatus = "Loading" }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "Apple silicon"
        #else
        let arch = "Intel"
        #endif
        var summary = [
            "Menu bar: \(settings.menuBarMode.title)\(settings.showDaysToReset ? " + days" : "")\(settings.hideLogo ? ", no logo" : "")",
            "Ring style: \(settings.ringStyle.title)\(settings.isVisible(.cursorRing) ? ", Cursor ring on (\(settings.ringSizing.rawValue))" : "")\(settings.isVisible(.regularGrokRing) ? "" : ", Grok ring off")",
            "Pool split: \(store.poolBreakdown?.equation ?? "no reading yet") (Grok = Total − Grok Bot − Cursor)",
            "History graphs: \(historyGraphSummary(settings))",
            "Levels: \(settings.thresholds.warningAbove)/\(settings.thresholds.criticalAbove)\(settings.notificationsLinked ? "" : ", alerts \(settings.notificationThresholds.warningAbove)/\(settings.notificationThresholds.criticalAbove)")",
            "Colors: \(settings.colors == .system ? "system" : settings.colors == .colorblindFriendly ? "colorblind-friendly" : "custom")",
            "Refresh: \(settings.refreshInterval.title)",
            "Shortcut: \(settings.hotKey.enabled ? settings.hotKey.display : "off")",
            "Update check: \(settings.checkForUpdates ? "on" : "off")",
            "Grok CLI: \(store.cliState().summary)\(store.cli().map { " (\($0.summary))" } ?? "")",
            "Service status: \(settings.showsServiceStatus ? settings.serviceStatus.enabled.map(\.title).joined(separator: ", ") : "off")\(settings.serviceStatus.notify ? ", notify on" : "")",
            "What's new: \(settings.showsWhatsNewSection ? "shown" : "hidden"), \(settings.whatsNew.interval.rawValue)h, notify \(settings.whatsNew.notify ? "on" : "off")",
        ]
        if let h = history?.sync { summary.append("History sync: \(historySyncSummary(h))") }
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
            ] + (whatsNew?.diagnostics() ?? []) + (status?.diagnostics() ?? []),
            settingsSummary: summary)
    }
}

/// e.g. "on, 3 Macs, last sync 2026-10-17T22:15:00Z, 1 skipped file". No paths or names (the report is shareable).
@MainActor
func historySyncSummary(_ s: HistoryStore.SyncStatus) -> String {
    guard s.enabled else { return "off" }
    guard s.isActive else { return "local only (no sync folder)" }
    var parts = ["on (\(s.origin?.label ?? "folder"))", "\(s.machineCount) Mac\(s.machineCount == 1 ? "" : "s")",
                 "last sync \(s.lastSync.map(DiagnosticsReport.stamp) ?? "never")"]
    if !s.skipped.isEmpty { parts.append("\(s.skipped.count) skipped file\(s.skipped.count == 1 ? "" : "s"): \(s.skipped.map(\.reason).joined(separator: "; "))") }
    if !s.conflictCopies.isEmpty { parts.append("\(s.conflictCopies.count) conflict cop\(s.conflictCopies.count == 1 ? "y" : "ies") merged") }
    if !s.readOnlyFolders.isEmpty { parts.append("also reading \(s.readOnlyFolders.count) older folder\(s.readOnlyFolders.count == 1 ? "" : "s")") }
    parts.append("last write \(s.lastWrite.map(DiagnosticsReport.stamp) ?? "never")")
    if let e = s.writeError { parts.append("write error: \(e)") }
    if let e = s.localSaveError { parts.append("local save error: \(e)") }
    if let e = s.lastError, e != s.writeError { parts.append("error: \(e)") }
    return parts.joined(separator: ", ")
}

/// e.g. "Bars (Grok, Grok Bot)" or "off" (for the Diagnostics settings summary).
func historyGraphSummary(_ s: GaugeSettings) -> String {
    let shown = [s.showGrokHistory ? "Total" : nil, s.showGrokBotHistory ? "Grok Bot" : nil,
                 s.showsCursorHistory ? "Cursor" : nil].compactMap { $0 }
    guard s.isVisible(.historyPace), !shown.isEmpty else { return "off" }
    return "\(s.graphStyle.title) (\(shown.joined(separator: ", ")))"
}

// MARK: - About › maker

/// The retroCombs logo, credit line, YouTube channel and contact address.
private struct MakerCard: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            if let logo = AppInfo.makerLogo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.16 : 0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.18), radius: 8, x: 0, y: 4)
                    .accessibilityLabel("retroCombs logo")
            }
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Made by Steven Combs (retroCombs)")
                        .font(.headline)
                    Text("Videos, projects and updates on YouTube.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    NSWorkspace.shared.open(AppInfo.youTubeURL)
                } label: {
                    Label("YouTube: \(AppInfo.youTubeHandle)", systemImage: "play.rectangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(YouTubeButtonStyle())
                .help(AppInfo.youTubeURL.absoluteString)
                .accessibilityLabel("Open the retroCombs-Tech YouTube channel")
                Button {
                    NSWorkspace.shared.open(AppInfo.tipURL)
                } label: {
                    Label("Support GrokGauge · Tip via PayPal", systemImage: "heart.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(TipButtonStyle())
                .help(AppInfo.tipURL.absoluteString)
                .accessibilityLabel("Support GrokGauge: tip via PayPal")
                Link(destination: AppInfo.contactURL) {
                    Label("Contact: \(AppInfo.contactEmail)", systemImage: "envelope")
                        .font(.system(size: 12))
                }
                .help("Write to \(AppInfo.contactEmail)")
                .accessibilityLabel("Email \(AppInfo.contactEmail)")
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

/// PayPal-blue capsule, same shape as the YouTube button but quieter.
private struct TipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color(red: 0.0, green: 0.19, blue: 0.53)
                .opacity(configuration.isPressed ? 0.75 : 1)))
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            .contentShape(Capsule())
    }
}

/// Always-red, always-prominent button (system prominent buttons turn gray in inactive windows).
private struct YouTubeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color(red: 0.85, green: 0.11, blue: 0.10)
                .opacity(configuration.isPressed ? 0.75 : 1)))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .contentShape(Capsule())
    }
}
