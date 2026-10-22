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

/// How the Grok CLI got onto this Mac, which decides the update command GrokGauge suggests.
public enum GrokCLIInstallKind: String, Equatable, Sendable {
    /// xAI's curl installer (`~/.grok/bin/grok`, updated with `grok update`).
    case installer
    /// Homebrew's `grok-build` cask (`$HOMEBREW_PREFIX/bin/grok`, updated with `brew upgrade --cask grok-build`).
    case homebrew
    /// Somewhere else on PATH; treated like the installer's copy.
    case other

    public var title: String {
        switch self {
        case .installer: return "xAI installer"
        case .homebrew: return "Homebrew"
        case .other: return "on PATH"
        }
    }
}

/// A Grok CLI found on this Mac. Found by looking at files only; GrokGauge never runs it.
public struct GrokCLI: Equatable, Sendable {
    public var path: String
    public var kind: GrokCLIInstallKind
    public var version: String?

    public init(path: String, kind: GrokCLIInstallKind, version: String?) {
        self.path = path
        self.kind = kind
        self.version = version
    }

    /// The command to copy when a newer CLI is out.
    public var updateCommand: String {
        kind == .homebrew ? GrokCLISetup.brewUpgradeCommand : GrokCLISetup.cliUpdateCommand
    }

    /// For Diagnostics, e.g. "Homebrew 1.0.67" (no file paths: the report promises none).
    public var summary: String {
        "\(kind.title)\(version.map { " \($0)" } ?? "")"
    }
}

public enum GrokCLISetup {
    /// Homebrew's cask for the Grok CLI (downloads the CLI from x.ai).
    public static let brewCask = "grok-build"
    public static let brewInstallCommand = "brew install --cask grok-build"
    public static let brewUpgradeCommand = "brew upgrade --cask grok-build"
    /// xAI's official installer (installs the CLI into `~/.grok`).
    public static let installerCommand = "curl -fsSL https://x.ai/cli/install.sh | bash"
    public static let cliUpdateCommand = "grok update"
    public static let loginCommand = "grok login"
    /// Works before a new shell picks up the installer's PATH change.
    public static let fallbackLoginCommand = "~/.grok/bin/grok login"
    /// Homebrew's two standard prefixes (Apple silicon, Intel).
    public static let homebrewPrefixes = ["/opt/homebrew", "/usr/local"]

    /// `brew` itself, if Homebrew is installed in a standard prefix.
    public static func brewPath(prefixes: [String] = homebrewPrefixes,
                                isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        prefixes.map { "\($0)/bin/brew" }.first(where: isExecutable)
    }

    /// The install command to suggest: Homebrew's cask when Homebrew is here, else xAI's installer.
    public static func installCommand(brewAvailable: Bool) -> String {
        brewAvailable ? brewInstallCommand : installerCommand
    }
    public static var installCommand: String { installCommand(brewAvailable: brewPath() != nil) }

    /// Places the CLI is usually found: the installer's `~/.grok/bin`, Homebrew, /usr/local, then the
    /// user's login-shell PATH (apps launched from Finder don't inherit it).
    public static func candidatePaths(home: String, shellPATH: String?) -> [String] {
        var dirs = ["\(home)/.grok/bin"] + homebrewPrefixes.map { "\($0)/bin" }
        for d in (shellPATH ?? "").split(separator: ":").map(String.init) where !d.isEmpty {
            let expanded = d.hasPrefix("~") ? home + d.dropFirst() : d
            if expanded.hasPrefix("/") && !dirs.contains(expanded) { dirs.append(expanded) }
        }
        return dirs.map { ($0 as NSString).appendingPathComponent("grok") }
    }

    /// Follows symlinks (Homebrew and the installer both link `grok` to a versioned binary).
    public static func resolve(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// What a `grok` file is, from its resolved location. nil when it's not the Grok CLI, e.g. the
    /// unrelated regex tool from Homebrew's `grok` formula (`Cellar/grok/...`).
    public static func identify(path: String, resolved: String, home: String) -> GrokCLI? {
        if resolved.contains("/Cellar/grok/") { return nil }
        let name = (resolved as NSString).lastPathComponent
        if let r = resolved.range(of: "/Caskroom/\(brewCask)/") {
            let dir = resolved[r.upperBound...].split(separator: "/").first.map(String.init)
            let v = GrokCLIVersion.version(fromBinaryName: name)
                ?? dir.flatMap { GrokCLIVersion.parsePointer(Data($0.utf8)) }
            return GrokCLI(path: path, kind: .homebrew, version: v)
        }
        let kind: GrokCLIInstallKind = path.hasPrefix("\(home)/.grok/") ? .installer : .other
        return GrokCLI(path: path, kind: kind, version: GrokCLIVersion.version(fromBinaryName: name))
    }

    /// The newest `grok-build` binary in Homebrew's Caskroom, for when the cask installed but couldn't
    /// link `bin/grok` (e.g. the regex tool from the `grok` formula already owns that name).
    public static func caskroomCLI(prefixes: [String] = homebrewPrefixes, fileManager: FileManager = .default) -> GrokCLI? {
        var best: GrokCLI?
        for prefix in prefixes {
            let root = "\(prefix)/Caskroom/\(brewCask)"
            guard let versions = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            for v in versions {
                guard let version = GrokCLIVersion.parsePointer(Data(v.utf8)),
                      let files = try? fileManager.contentsOfDirectory(atPath: "\(root)/\(v)"),
                      let bin = files.sorted().first(where: { GrokCLIVersion.version(fromBinaryName: $0) != nil }) else { continue }
                let path = "\(root)/\(v)/\(bin)"
                guard fileManager.isExecutableFile(atPath: path) else { continue }
                if let b = best?.version, !UpdateCheck.isNewer(version, than: b) { continue }
                best = GrokCLI(path: path, kind: .homebrew, version: version)
            }
        }
        return best
    }

    /// The Grok CLI this Mac would use: the first real Grok CLI among the candidates, else a
    /// Homebrew `grok-build` copy that isn't linked. nil when there's none.
    public static func locate(home: String = NSHomeDirectory(), shellPATH: String?,
                              isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                              resolve: (String) -> String = GrokCLISetup.resolve,
                              caskroom: () -> GrokCLI? = { GrokCLISetup.caskroomCLI() }) -> GrokCLI? {
        for path in candidatePaths(home: home, shellPATH: shellPATH) where isExecutable(path) {
            if let cli = identify(path: path, resolved: resolve(path), home: home) { return cli }
        }
        return caskroom()
    }

    /// Path of the Grok CLI, or nil (see `locate`).
    public static func findCLI(home: String = NSHomeDirectory(), shellPATH: String?,
                               isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                               resolve: (String) -> String = GrokCLISetup.resolve,
                               caskroom: () -> GrokCLI? = { GrokCLISetup.caskroomCLI() }) -> String? {
        locate(home: home, shellPATH: shellPATH, isExecutable: isExecutable, resolve: resolve, caskroom: caskroom)?.path
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

    /// Script for "Install in Terminal…" (only after the user confirms): installs the CLI with Homebrew
    /// (`brew` is the full path to it) or, without Homebrew, xAI's official installer, then prints the
    /// sign-in step. Never signs in for the user.
    public static func terminalScript(brew: String?) -> String {
        let install = brew.map { "\"\($0)\" install --cask \(brewCask)" } ?? installerCommand
        let shown = brew == nil ? installerCommand : brewInstallCommand
        let how = brew == nil ? "xAI's official installer" : "Homebrew (the \(brewCask) cask, downloaded from x.ai)"
        let login = brew == nil ? fallbackLoginCommand : loginCommand
        let hint = brew == nil ? "(In a new Terminal window, plain 'grok login' works too.)"
            : "(If 'grok' isn't found, open a new Terminal window.)"
        return """
        #!/bin/bash
        # Written by GrokGauge after you clicked "Install in Terminal…". Safe to delete.
        echo "Installing the Grok CLI with \(how):"
        echo "  \(shown)"
        echo
        \(install)
        status=$?
        echo
        if [ $status -eq 0 ]; then
          echo "Done. Next, sign in (this opens your browser):"
          echo "  \(login)"
          echo "\(hint)"
        else
          echo "The install didn't finish (exit $status). You can try again from GrokGauge."
        fi
        echo
        rm -f "$0"
        exec "${SHELL:-/bin/zsh}" -l
        """
    }
}
