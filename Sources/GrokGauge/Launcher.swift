import AppKit

enum Launcher {
    static func openGrok() {
        NSWorkspace.shared.open(AppInfo.grokURL)
    }

    /// Finds "Grok Bot.app" by name in the usual Applications folders, then by bundle id.
    static func grokBotURL() -> URL? {
        let fm = FileManager.default
        let candidates = [
            URL(fileURLWithPath: "/Applications/Grok Bot.app"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Grok Bot.app"),
        ]
        if let hit = candidates.first(where: { fm.fileExists(atPath: $0.path) }) { return hit }
        for id in ["com.anysphere.sand"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return nil
    }

    static var hasGrokBot: Bool { grokBotURL() != nil }

    static func openGrokBot() {
        guard let url = grokBotURL() else {
            let alert = NSAlert()
            alert.messageText = "Grok Bot isn't installed"
            alert.informativeText = "GrokGauge looked for “Grok Bot.app” in /Applications and ~/Applications."
            alert.runModal()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }

    static func copyLoginCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("grok login", forType: .string)
    }
}
