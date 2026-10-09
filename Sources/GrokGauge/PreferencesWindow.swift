import AppKit
import SwiftUI

/// The Settings window (gear button in the dropdown, or ⌘,).
@MainActor
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let makeView: () -> PreferencesView

    init(makeView: @escaping () -> PreferencesView) {
        self.makeView = makeView
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: makeView())
            let w = NSWindow(contentViewController: host)
            w.title = "GrokGauge Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 600, height: 680))
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("GrokGaugeSettings")
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the hosting view so nothing keeps running while the window is closed.
        window?.contentViewController = nil
        window = nil
    }
}

/// An accessory app has no visible menu bar, but a main menu still provides the standard
/// key equivalents (⌘W, ⌘Q, ⌘, and copy/paste in text fields).
/// Opens the PayPal tip page from the app menu.
@MainActor
final class SupportTarget: NSObject {
    static let shared = SupportTarget()
    @objc func openSupport(_ sender: Any?) { NSWorkspace.shared.open(AppInfo.tipURL) }
}

enum MainMenu {
    @MainActor
    static func install(target: AnyObject, settingsAction: Selector) {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let app = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: settingsAction, keyEquivalent: ",")
        settings.target = target
        app.addItem(settings)
        let support = NSMenuItem(title: "Support GrokGauge…", action: #selector(SupportTarget.openSupport(_:)), keyEquivalent: "")
        support.target = SupportTarget.shared
        app.addItem(support)
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Quit GrokGauge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = window
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}
