import Foundation

/// Where the user is in setting up Grok: GrokGauge reads Grok usage with the Grok CLI's login
/// (`~/.grok/auth.json`), so it needs the CLI installed and signed in. Grok Bot works without it.
public enum GrokCLIState: Equatable, Sendable {
    case notInstalled
    /// The CLI is installed (at `cliPath`, if we found it) but there's no usable login.
    case signedOut(cliPath: String?)
    case signedIn

    public var title: String {
        switch self {
        case .notInstalled: return "Grok CLI not installed"
        case .signedOut: return "Sign in to Grok"
        case .signedIn: return "Signed in"
        }
    }
    /// Short words for Diagnostics.
    public var summary: String {
        switch self {
        case .notInstalled: return "not installed"
        case .signedOut: return "installed, signed out"
        case .signedIn: return "signed in"
        }
    }
}

public enum GrokCLISetup {
    /// xAI's official installer (installs the CLI into `~/.grok`).
    public static let installCommand = "curl -fsSL https://x.ai/cli/install.sh | bash"
    public static let loginCommand = "grok login"
    /// Works before a new shell picks up the installer's PATH change.
    public static let fallbackLoginCommand = "~/.grok/bin/grok login"

    /// Places the CLI is usually found: the installer's `~/.grok/bin`, Homebrew, /usr/local, then the
    /// user's login-shell PATH (apps launched from Finder don't inherit it).
    public static func candidatePaths(home: String, shellPATH: String?) -> [String] {
        var dirs = ["\(home)/.grok/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        for d in (shellPATH ?? "").split(separator: ":").map(String.init) where !d.isEmpty {
            let expanded = d.hasPrefix("~") ? home + d.dropFirst() : d
            if expanded.hasPrefix("/") && !dirs.contains(expanded) { dirs.append(expanded) }
        }
        return dirs.map { ($0 as NSString).appendingPathComponent("grok") }
    }

    /// First executable `grok` among the candidates, or nil.
    public static func findCLI(home: String = NSHomeDirectory(), shellPATH: String?,
                               isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        candidatePaths(home: home, shellPATH: shellPATH).first(where: isExecutable)
    }

    /// A usable login wins even if we can't see the CLI (e.g. installed somewhere unusual).
    public static func state(cliPath: String?, hasUsableLogin: Bool) -> GrokCLIState {
        if hasUsableLogin { return .signedIn }
        return cliPath == nil ? .notInstalled : .signedOut(cliPath: cliPath)
    }

    /// Whether `auth.json` holds a credential GrokGauge could use (read locally; nothing is sent).
    public static func hasUsableLogin(authFile: URL = AuthStore.authFileURL) -> Bool {
        (try? AuthStore.readBest(from: authFile)) != nil
    }

    /// Modification time of the login file (nil when missing), to notice `grok login` finishing.
    public static func loginStamp(authFile: URL = AuthStore.authFileURL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: authFile.path))?[.modificationDate] as? Date
    }

    /// The user's login-shell PATH, read once with a short timeout (`$SHELL -l -c 'printf %s "$PATH"'`).
    /// Runs no other command; returns nil on any problem.
    public static func loginShellPATH(timeout: TimeInterval = 3) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard p.terminationStatus == 0, let s = String(data: data.prefix(16_384), encoding: .utf8) else { return nil }
        let path = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Script for "Install in Terminal…" (only after the user confirms): runs the official installer,
    /// then prints the sign-in step. Never signs in for the user.
    public static var terminalScript: String {
        """
        #!/bin/bash
        # Written by GrokGauge after you clicked "Install in Terminal…". Safe to delete.
        echo "Installing the Grok CLI with xAI's official installer:"
        echo "  \(installCommand)"
        echo
        \(installCommand)
        status=$?
        echo
        if [ $status -eq 0 ]; then
          echo "Done. Next, sign in (this opens your browser):"
          echo "  \(fallbackLoginCommand)"
          echo "(In a new Terminal window, plain 'grok login' works too.)"
        else
          echo "The installer didn't finish (exit $status). You can try again from GrokGauge."
        fi
        echo
        rm -f "$0"
        exec "${SHELL:-/bin/zsh}" -l
        """
    }
}
