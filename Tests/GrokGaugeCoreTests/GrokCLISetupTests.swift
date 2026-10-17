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
        #expect(GrokCLISetup.installCommand == "curl -fsSL https://x.ai/cli/install.sh | bash")
        #expect(GrokCLISetup.loginCommand == "grok login")
        #expect(GrokCLISetup.fallbackLoginCommand == "~/.grok/bin/grok login")
        let script = GrokCLISetup.terminalScript
        #expect(script.hasPrefix("#!/bin/bash"))
        #expect(script.contains(GrokCLISetup.installCommand))
        #expect(!script.contains("grok login\n"))          // prints the sign-in step, never runs it
        #expect(script.contains("echo \"  ~/.grok/bin/grok login\""))
    }
}
