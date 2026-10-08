import AppKit
import Combine
import GrokGaugeCore
import SwiftUI

extension UsageLevel {
    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var nsColor: NSColor {
        switch self {
        case .normal: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let notifier = UsageNotifier()
    private lazy var store = UsageStore(notifier: notifier)
    private let loginItem = LaunchAtLogin()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "GrokGauge"
        if let button = statusItem.button {
            button.image = GrokMarkImage.template(size: 18)
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.setAccessibilityLabel("GrokGauge")
        }

        let root = PopoverView(store: store, loginItem: loginItem)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // objectWillChange fires before the value lands; hop once more.
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
            .store(in: &cancellables)

        notifier.requestAuthorization()
        updateStatusItem()
        store.start()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let grok = store.snapshot?.roundedPercent
        let bot = store.botSnapshot?.roundedPercent
        // "Both" only makes sense when Grok Bot is installed.
        let style: MenuBarStyle = store.hasGrokBot ? store.menuBarStyle : .highest
        var segments = MenuBarTitle.segments(grok: grok, bot: bot, style: style)

        if segments.isEmpty {
            let text: String
            if let p = store.problem { text = p.needsLogin ? " login" : " –" } else { text = " …" }
            segments = [MenuBarSegment(text: text, level: nil)]
        }

        let title = NSMutableAttributedString()
        for seg in segments {
            title.append(NSAttributedString(string: seg.text, attributes: [
                .font: font,
                .foregroundColor: seg.level?.nsColor ?? NSColor.secondaryLabelColor,
            ]))
        }
        button.attributedTitle = title
        button.toolTip = tooltip()
        button.setAccessibilityValue(title.string.trimmingCharacters(in: .whitespaces))
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
        return lines.joined(separator: "\n")
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            loginItem.refresh()
            store.refreshIfStale()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate()
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
