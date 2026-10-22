import Foundation
import Testing
@testable import GrokGaugeCore

@Suite struct GrokCLISetupTests {
    let home = "/Users/test"

    @Test func candidatesCoverInstallerHomebrewUsrLocalThenShellPATH() {
        let c = GrokCLISetup.candidatePaths(home: home, shellPATH: "/opt/homebrew/bin:~/bin:relative:/custom/tools:")
        #expect(c == ["/Users/test/.grok/bin/grok", "/opt/homebrew/bin/grok", "/usr/local/bin/grok",
                      "/Users/test/bin/grok", "/custom/tools/grok"])
        #expect(GrokCLISetup.candidatePaths(home: home, shellPATH: nil).count == 3)
    }

    @Test func findsFirstExecutable() {
        let found = GrokCLISetup.findCLI(home: home, shellPATH: "/custom/tools",
                                         isExecutable: { $0 == "/custom/tools/grok" || $0 == "/usr/local/bin/grok" })
        #expect(found == "/usr/local/bin/grok")
        #expect(GrokCLISetup.findCLI(home: home, shellPATH: "/custom/tools", isExecutable: { _ in false }) == nil)
        let installer = GrokCLISetup.findCLI(home: home, shellPATH: nil, isExecutable: { $0.hasSuffix("/.grok/bin/grok") })
        #expect(installer == "/Users/test/.grok/bin/grok")
    }

    @Test func stateFromCLIAndLogin() {
        #expect(GrokCLISetup.state(cliPath: nil, hasUsableLogin: false) == .notInstalled)
        #expect(GrokCLISetup.state(cliPath: "/x/grok", hasUsableLogin: false) == .signedOut(cliPath: "/x/grok"))
        #expect(GrokCLISetup.state(cliPath: "/x/grok", hasUsableLogin: true) == .signedIn)
        // A usable login counts even when the CLI lives somewhere we don't look.
        #expect(GrokCLISetup.state(cliPath: nil, hasUsableLogin: true) == .signedIn)
        #expect(GrokCLIState.notInstalled.title == "Grok CLI not installed")
        #expect(GrokCLIState.signedOut(cliPath: nil).title == "Sign in to Grok")
    }

    @Test func loginDetectionReadsTheAuthFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grokauth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let auth = dir.appendingPathComponent("auth.json")
        #expect(!GrokCLISetup.hasUsableLogin(authFile: auth))
        #expect(GrokCLISetup.loginStamp(authFile: auth) == nil)
        try Data("not json".utf8).write(to: auth)
        #expect(!GrokCLISetup.hasUsableLogin(authFile: auth))
        #expect(GrokCLISetup.loginStamp(authFile: auth) != nil)
    }

    @Test func commandsAreTheOfficialOnes() {
        #expect(GrokCLISetup.installerCommand == "curl -fsSL https://x.ai/cli/install.sh | bash")
        #expect(GrokCLISetup.brewInstallCommand == "brew install --cask grok-build")
        #expect(GrokCLISetup.brewUpgradeCommand == "brew upgrade --cask grok-build")
        #expect(GrokCLISetup.installCommand(brewAvailable: true) == "brew install --cask grok-build")
        #expect(GrokCLISetup.installCommand(brewAvailable: false) == GrokCLISetup.installerCommand)
        #expect(GrokCLISetup.loginCommand == "grok login")
        #expect(GrokCLISetup.fallbackLoginCommand == "~/.grok/bin/grok login")
        let script = GrokCLISetup.terminalScript(brew: nil)
        #expect(script.hasPrefix("#!/bin/bash"))
        #expect(script.contains("\n" + GrokCLISetup.installerCommand + "\n"))
        #expect(!script.contains("grok login\n"))          // prints the sign-in step, never runs it
        #expect(script.contains("echo \"  ~/.grok/bin/grok login\""))
    }

    @Test func terminalScriptUsesHomebrewWhenPresent() {
        let script = GrokCLISetup.terminalScript(brew: "/opt/homebrew/bin/brew")
        #expect(script.contains("\n\"/opt/homebrew/bin/brew\" install --cask grok-build\n"))
        #expect(!script.contains("install.sh"))
        #expect(script.contains("echo \"  grok login\""))
        #expect(!script.contains("\ngrok login"))         // never signs in for the user
    }

    @Test func brewIsFoundInEitherStandardPrefix() {
        #expect(GrokCLISetup.brewPath(isExecutable: { $0 == "/usr/local/bin/brew" }) == "/usr/local/bin/brew")
        #expect(GrokCLISetup.brewPath(isExecutable: { _ in true }) == "/opt/homebrew/bin/brew")
        #expect(GrokCLISetup.brewPath(isExecutable: { _ in false }) == nil)
    }

    @Test func identifiesInstallerHomebrewAndTheUnrelatedGrokFormula() {
        let installer = GrokCLISetup.identify(path: "/Users/test/.grok/bin/grok",
                                              resolved: "/Users/test/.grok/downloads/grok-1.0.62-macos-aarch64", home: home)
        #expect(installer == GrokCLI(path: "/Users/test/.grok/bin/grok", kind: .installer, version: "1.0.62"))
        #expect(installer?.updateCommand == "grok update")

        let brew = GrokCLISetup.identify(path: "/opt/homebrew/bin/grok",
                                         resolved: "/opt/homebrew/Caskroom/grok-build/1.0.67/grok-1.0.67-macos-aarch64", home: home)
        #expect(brew == GrokCLI(path: "/opt/homebrew/bin/grok", kind: .homebrew, version: "1.0.67"))
        #expect(brew?.updateCommand == "brew upgrade --cask grok-build")
        let intel = GrokCLISetup.identify(path: "/usr/local/bin/grok",
                                          resolved: "/usr/local/Caskroom/grok-build/1.0.70/grok", home: home)
        #expect(intel?.kind == .homebrew)
        #expect(intel?.version == "1.0.70")      // from the Caskroom folder when the file name has none

        // Homebrew's `grok` formula is an unrelated regex tool, not the Grok CLI.
        #expect(GrokCLISetup.identify(path: "/opt/homebrew/bin/grok",
                                      resolved: "/opt/homebrew/Cellar/grok/0.9.2_2/bin/grok", home: home) == nil)
        let other = GrokCLISetup.identify(path: "/custom/tools/grok", resolved: "/custom/tools/grok", home: home)
        #expect(other?.kind == .other)
        #expect(other?.version == nil)
        #expect(other?.updateCommand == "grok update")
    }

    @Test func locateSkipsTheRegexToolAndFallsBackToTheCaskroom() {
        let caskroomCopy = GrokCLI(path: "/opt/homebrew/Caskroom/grok-build/1.0.67/grok-1.0.67-macos-aarch64",
                                   kind: .homebrew, version: "1.0.67")
        let links = ["/opt/homebrew/bin/grok": "/opt/homebrew/Cellar/grok/0.9.2_2/bin/grok",
                     "/usr/local/bin/grok": "/usr/local/Caskroom/grok-build/1.0.66/grok-1.0.66-macos-x86_64"]
        let resolve: (String) -> String = { links[$0] ?? $0 }
        // Regex tool at /opt/homebrew/bin is skipped; the Intel-prefix Homebrew CLI is next.
        let found = GrokCLISetup.locate(home: home, shellPATH: nil, isExecutable: { links[$0] != nil },
                                        resolve: resolve, caskroom: { caskroomCopy })
        #expect(found?.path == "/usr/local/bin/grok")
        #expect(found?.kind == .homebrew)
        // Only the regex tool linked: the unlinked Caskroom copy is used.
        let unlinked = GrokCLISetup.locate(home: home, shellPATH: nil, isExecutable: { $0 == "/opt/homebrew/bin/grok" },
                                           resolve: resolve, caskroom: { caskroomCopy })
        #expect(unlinked == caskroomCopy)
        #expect(GrokCLISetup.findCLI(home: home, shellPATH: nil, isExecutable: { $0 == "/opt/homebrew/bin/grok" },
                                     resolve: resolve, caskroom: { nil }) == nil)
        // The installer's copy wins when both are installed.
        let both = GrokCLISetup.locate(home: home, shellPATH: nil, isExecutable: { _ in true },
                                       resolve: { $0.hasPrefix(home) ? home + "/.grok/downloads/grok-1.0.62-macos-aarch64" : resolve($0) },
                                       caskroom: { caskroomCopy })
        #expect(both?.kind == .installer)
        #expect(both?.version == "1.0.62")
    }

    @Test func caskroomPicksTheNewestExecutableCopy() throws {
        let fm = FileManager.default
        let prefix = fm.temporaryDirectory.appendingPathComponent("brewprefix-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: prefix) }
        #expect(GrokCLISetup.caskroomCLI(prefixes: [prefix.path]) == nil)
        for v in ["1.0.9", "1.0.67", "1.0.10"] {
            let dir = prefix.appendingPathComponent("Caskroom/grok-build/\(v)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let bin = dir.appendingPathComponent("grok-\(v)-macos-aarch64")
            try Data("#!/bin/sh\n".utf8).write(to: bin)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        }
        try fm.createDirectory(at: prefix.appendingPathComponent("Caskroom/grok-build/.metadata"), withIntermediateDirectories: true)
        let cli = try #require(GrokCLISetup.caskroomCLI(prefixes: [prefix.path]))
        #expect(cli.version == "1.0.67")
        #expect(cli.kind == .homebrew)
        #expect(cli.path.hasSuffix("Caskroom/grok-build/1.0.67/grok-1.0.67-macos-aarch64"))
    }

    @Test func summaryHasNoFilePaths() {
        let cli = GrokCLI(path: "/Users/test/.grok/bin/grok", kind: .installer, version: "1.0.62")
        #expect(cli.summary == "xAI installer 1.0.62")
        #expect(GrokCLI(path: "/opt/homebrew/bin/grok", kind: .homebrew, version: nil).summary == "Homebrew")
    }
}
