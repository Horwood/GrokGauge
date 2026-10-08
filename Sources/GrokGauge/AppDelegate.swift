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
        let title: String
        let color: NSColor
        let tooltip: String

        if let s = store.snapshot {
            title = " \(s.roundedPercent)%"
            color = s.level.nsColor
            var tip = "SuperGrok: \(s.roundedPercent)% of this \(s.period.label.lowercased()) pool used"
            if let left = s.timeUntilReset() { tip += "\nResets in \(UsageFormat.countdown(left))" }
            if let p = store.problem { tip += "\n⚠︎ \(p.title)" }
            tooltip = tip
        } else if let p = store.problem {
            title = p.needsLogin ? " login" : " –"
            color = .secondaryLabelColor
            tooltip = "GrokGauge: \(p.title)"
        } else {
            title = " …"
            color = .secondaryLabelColor
            tooltip = "GrokGauge: loading"
        }

        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
        button.toolTip = tooltip
        button.setAccessibilityValue(title.trimmingCharacters(in: .whitespaces))
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
