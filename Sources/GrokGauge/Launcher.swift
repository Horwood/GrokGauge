import AppKit
import GrokGaugeCore

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

    // MARK: X (shortcut only; GrokGauge reads no X data)

    static let xBundleID = "com.atebits.Tweetie2"
    static let xWebURL = URL(string: "https://x.com")!

    /// The native X app (by bundle id), else an "X" web app saved from Safari (Add to Dock), else nil.
    static func xAppURL() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: xBundleID) { return url }
        let fm = FileManager.default
        let folders = [URL(fileURLWithPath: "/Applications"),
                       fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for folder in folders {
            for name in ["X.app", "Twitter.app"] {
                let url = folder.appendingPathComponent(name)
                if isXApp(at: url) { return url }
            }
        }
        return nil
    }

    static func isXApp(at url: URL) -> Bool {
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let id = info["CFBundleIdentifier"] as? String else { return false }
        if id == xBundleID { return true }
        // Safari web apps keep the site's web manifest in Info.plist.
        guard id.hasPrefix("com.apple.Safari.WebApp"), let manifest = info["Manifest"] as? [String: Any] else { return false }
        if (manifest["android_package_name"] as? String) == "com.twitter.android" { return true }
        let start = (manifest["start_url"] as? String ?? "").lowercased()
        return start.contains("x.com") || start.contains("twitter.com")
    }

    static func openX() {
        if let app = xAppURL() {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
                if error != nil { DispatchQueue.main.async { _ = NSWorkspace.shared.open(xWebURL) } }
            }
        } else {
            NSWorkspace.shared.open(xWebURL)
        }
    }

    static func copyLoginCommand() {
        copy(GrokCLISetup.loginCommand)
    }

    static func copyInstallCommand() {
        copy(GrokCLISetup.installCommand)
    }

    private static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    static func openTerminal() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
    }

    /// Asks first, then opens Terminal installing the CLI with Homebrew (`grok-build`) or, without
    /// Homebrew, xAI's official installer. Never runs anything silently, never signs in for the user.
    @MainActor
    static func installCLIInTerminal() {
        let brew = GrokCLISetup.brewPath()
        let alert = NSAlert()
        alert.messageText = "Install the Grok CLI in Terminal?"
        alert.informativeText = brew != nil ? """
            Terminal will open and run:

            \(GrokCLISetup.brewInstallCommand)

            Homebrew downloads the Grok CLI from x.ai. When it's done, run “grok login” to sign in. \
            GrokGauge picks up the sign-in automatically.

            Prefer xAI's own installer? Copy this instead: \(GrokCLISetup.installerCommand)
            """ : """
            Terminal will open and run xAI's official installer:

            \(GrokCLISetup.installerCommand)

            It downloads the Grok CLI from x.ai and installs it in ~/.grok. When it's done, run \
            “\(GrokCLISetup.fallbackLoginCommand)” (or “grok login” in a new window) to sign in. \
            GrokGauge picks up the sign-in automatically.
            """
        alert.addButton(withTitle: "Open Terminal and Install")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn,
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("Install Grok CLI.command")
        do {
            try GrokCLISetup.terminalScript(brew: brew).write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch { return }
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: .init()) { _, _ in }
    }
}
