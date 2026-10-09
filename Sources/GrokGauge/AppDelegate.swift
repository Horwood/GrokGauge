import AppKit
import Combine
import GrokGaugeCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let notifier = UsageNotifier()
    private let settingsStore = SettingsStore()
    private let history = HistoryStore()
    private let updates = UpdateMonitor()
    private lazy var store = UsageStore(notifier: notifier, history: history) { [unowned self] in
        self.settingsStore.settings
    }
    private lazy var whatsNew = WhatsNewStore(
        settings: { [unowned self] in self.settingsStore.settings.whatsNew },
        notify: { [unowned self] items in self.notifier.postWhatsNew(items) })
    private let sizing = PopoverSizing()
    private let loginItem = LaunchAtLogin()
    private var preferences: PreferencesWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var lastApplied: GaugeSettings?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "GrokGauge"
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.setAccessibilityLabel("GrokGauge")
        }

        let root = PopoverView(store: store, settingsStore: settingsStore, history: history, updates: updates, whatsNew: whatsNew, sizing: sizing) { [weak self] in
            self?.openPreferences()
        }
        let host = NSHostingController(rootView: root)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true

        preferences = PreferencesWindowController { [unowned self] in
            PreferencesView(settingsStore: settingsStore, store: store, updates: updates, loginItem: loginItem,
                            hotKeys: HotKeyCenter.shared, whatsNew: whatsNew, tokenExpiry: { [weak self] in self?.store.grokTokenExpiry() })
        }
        MainMenu.install(target: self, settingsAction: #selector(openPreferencesAction(_:)))

        Publishers.Merge(store.objectWillChange, settingsStore.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // objectWillChange fires before the value lands; hop once more.
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
            .store(in: &cancellables)

        settingsStore.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] s in self?.apply(s) }
            .store(in: &cancellables)

        // Displays added, removed or rearranged (or the Dock resized): re-cap the dropdown height.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updatePopoverSizing() }
            .store(in: &cancellables)

        HotKeyCenter.shared.action = { [weak self] in self?.togglePopover(nil) }

        notifier.requestAuthorization()
        settingsStore.start()
        apply(settingsStore.settings)
        updateStatusItem()
        store.start()
        whatsNew.start()
    }

    /// Applies settings that drive non-SwiftUI parts: timers, the shortcut, the update check.
    private func apply(_ s: GaugeSettings) {
        let old = lastApplied
        lastApplied = s
        if old?.refreshInterval != s.refreshInterval {
            store.schedule(interval: s.refreshInterval.seconds)
        }
        if old?.hotKey != s.hotKey {
            HotKeyCenter.shared.register(s.hotKey)
        }
        if old?.checkForUpdates != s.checkForUpdates {
            updates.setEnabled(s.checkForUpdates)
        }
        // A source switched on (or a shorter interval) after launch: check what's now due.
        if let old, old.whatsNew != s.whatsNew || old.showsWhatsNewSection != s.showsWhatsNewSection {
            whatsNew.checkDue()
        }
    }

    private var palette: Palette { Palette(settingsStore.settings) }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let s = settingsStore.settings
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let grok = store.snapshot?.roundedPercent
        let bot = store.botSnapshot?.roundedPercent
        let mode = MenuBarLayout.effectiveMode(s.menuBarMode, hasGrokBot: store.hasGrokBot)
        var segments = MenuBarLayout.segments(
            grok: grok, bot: bot,
            grokDays: store.snapshot?.timeUntilReset().map(UsageFormat.wholeDays),
            botDays: store.botSnapshot?.timeUntilReset().map(UsageFormat.wholeDays),
            mode: mode, thresholds: s.thresholds, showDays: s.showDaysToReset)

        if segments.isEmpty && mode != .logoOnly {
            let text: String
            if let p = store.problem {
                text = p.needsLogin ? " login" : p == .changedShape ? " ?" : " –"
            } else {
                text = " …"
            }
            segments = [MenuBarSegment(text: text, level: nil)]
        }

        // Logo: template (adapts to the menu bar) unless "logo only", where it's tinted by status.
        if mode == .logoOnly {
            let level = MenuBarLayout.logoLevel(grok: grok, bot: bot, thresholds: s.thresholds)
            button.image = level.map { tinted(GrokMarkImage.template(size: 18), palette.nsColor($0)) }
                ?? GrokMarkImage.template(size: 18)
        } else {
            button.image = s.hideLogo ? nil : GrokMarkImage.template(size: 18)
        }

        let title = NSMutableAttributedString()
        for seg in segments {
            title.append(NSAttributedString(string: seg.text, attributes: [
                .font: font,
                .foregroundColor: seg.level.map { palette.nsColor($0) } ?? NSColor.secondaryLabelColor,
            ]))
        }
        // With no logo, drop the leading space so the title doesn't look off-center.
        if button.image == nil, title.string.hasPrefix(" ") {
            title.deleteCharacters(in: NSRange(location: 0, length: 1))
        }
        button.attributedTitle = title
        button.toolTip = tooltip()
        let spoken = accessibilitySummary(grok: grok, bot: bot)
        button.setAccessibilityValue(spoken)
    }

    private func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let out = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        out.isTemplate = false
        out.accessibilityDescription = "GrokGauge"
        return out
    }

    private func accessibilitySummary(grok: Int?, bot: Int?) -> String {
        var parts: [String] = []
        if let g = grok { parts.append("Grok \(g) percent, \(palette.level(g).spoken)") }
        else if let p = store.problem { parts.append("Grok: \(p.title)") }
        if let b = bot { parts.append("Grok Bot \(b) percent, \(palette.level(b).spoken)") }
        return parts.isEmpty ? "Loading" : parts.joined(separator: "; ")
    }

    private func tooltip() -> String {
        var lines: [String] = []
        if let s = store.snapshot {
            var line = "Grok: \(s.roundedPercent)% of this \(s.period.label.lowercased()) pool used"
            if let left = s.timeUntilReset() { line += ", resets in \(UsageFormat.countdown(left))" }
            lines.append(line)
            if let p = store.problem { lines.append("⚠︎ \(p.title)") }
        } else if let p = store.problem {
            lines.append("Grok: \(p.title)")
        } else {
            lines.append("Grok: loading")
        }
        if let b = store.botSnapshot {
            var line = "Grok Bot: \(b.roundedPercent)% of weekly usage"
            if let left = b.timeUntilReset() { line += ", resets in \(UsageFormat.countdown(left))" }
            lines.append(line)
        } else if let p = store.botProblem, p != .notInstalled {
            lines.append("Grok Bot: \(p.tooltip)")
        }
        if let r = updates.available { lines.append("Update available: \(r.version)") }
        return lines.joined(separator: "\n")
    }

    @objc private func openPreferencesAction(_ sender: Any?) { openPreferences() }

    func openPreferences() {
        if popover.isShown { popover.performClose(nil) }
        loginItem.refresh()
        preferences?.show()
    }

    /// Caps the dropdown to the visible part of the status item's screen.
    private func updatePopoverSizing() {
        sizing.update(for: statusItem?.button?.window?.screen)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            loginItem.refresh()
            store.refreshIfStale()
            updatePopoverSizing()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate()
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
