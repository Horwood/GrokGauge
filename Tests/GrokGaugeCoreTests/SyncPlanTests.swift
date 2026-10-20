import Foundation
import Testing
@testable import GrokGaugeCore

@Suite struct SyncPlanTests {
    let mac = URL(fileURLWithPath: "/Users/s/Google Drive/Computers/Mac/MacSyncing", isDirectory: true)
    var xai: URL { mac.appendingPathComponent("xAI", isDirectory: true) }
    let me = "air"

    // MARK: Recommendation

    @Test func movesOffAFolderNoOtherMacUses() {
        // Air-M4 today: settings in MacSyncing/xAI (only its own history there); the other Macs use MacSyncing.
        let surveys = [SyncFolderSurvey(folder: xai, machineIDs: [me], hasSettingsFile: true),
                       SyncFolderSurvey(folder: mac, machineIDs: [me, "studio", "mbp"], hasSettingsFile: true)]
        #expect(SyncFolderPlan.recommend(current: xai, detected: mac, surveys: surveys, machineID: me) == .autoSwitch(mac))
        // Once there, it stays, and the old folder is read (not written) so nothing in it is lost.
        #expect(SyncFolderPlan.recommend(current: mac, detected: mac, surveys: surveys, machineID: me) == .keep)
        #expect(SyncFolderPlan.readOnlyFolders(primary: mac, surveys: surveys) == [xai])
    }

    @Test func otherMacsKeepTheirFolderAndReadTheOldOne() {
        // Studio on MacSyncing sees Air's legacy file in MacSyncing/xAI: it reads it but doesn't move there.
        let surveys = [SyncFolderSurvey(folder: mac, machineIDs: ["studio", "mbp", me], hasSettingsFile: true),
                       SyncFolderSurvey(folder: xai, machineIDs: [me], hasSettingsFile: true)]
        #expect(SyncFolderPlan.recommend(current: mac, detected: mac, surveys: surveys, machineID: "studio") == .keep)
        #expect(SyncFolderPlan.readOnlyFolders(primary: mac, surveys: surveys) == [xai])
    }

    @Test func offersButDoesntMoveWhenOtherMacsShareThisFolderToo() {
        let dropbox = URL(fileURLWithPath: "/Users/s/Dropbox", isDirectory: true)
        let surveys = [SyncFolderSurvey(folder: dropbox, machineIDs: [me, "mini"]),
                       SyncFolderSurvey(folder: mac, machineIDs: ["studio", "mbp", "pro"])]
        #expect(SyncFolderPlan.recommend(current: dropbox, detected: mac, surveys: surveys, machineID: me) == .suggest(mac, otherMacs: 3))
    }

    @Test func tiesStayPut() {
        let a = URL(fileURLWithPath: "/a", isDirectory: true), b = URL(fileURLWithPath: "/b", isDirectory: true)
        let surveys = [SyncFolderSurvey(folder: a, machineIDs: [me, "x"]), SyncFolderSurvey(folder: b, machineIDs: ["y"])]
        #expect(SyncFolderPlan.recommend(current: a, detected: b, surveys: surveys, machineID: me) == .keep)
    }

    @Test func withNoFolderPicksTheOneTheOtherMacsUseOrTheFoundOne() {
        let surveys = [SyncFolderSurvey(folder: mac, machineIDs: ["studio"]), SyncFolderSurvey(folder: xai)]
        #expect(SyncFolderPlan.recommend(current: nil, detected: mac, surveys: surveys, machineID: me) == .autoSwitch(mac))
        // Brand-new setup: nothing anywhere yet, so the found MacSyncing folder is used.
        #expect(SyncFolderPlan.recommend(current: nil, detected: mac, surveys: [], machineID: me) == .autoSwitch(mac))
        #expect(SyncFolderPlan.recommend(current: nil, detected: nil, surveys: [], machineID: me) == .keep)
        // A history-only folder from 0.9.2–0.9.4 with other Macs in it counts too.
        let legacy = URL(fileURLWithPath: "/Users/s/Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        #expect(SyncFolderPlan.recommend(current: nil, detected: nil, surveys: [SyncFolderSurvey(folder: legacy, machineIDs: ["mbp"])],
                                         machineID: me) == .autoSwitch(legacy))
    }

    @Test func emptyFoldersAreNeverRecommended() {
        let surveys = [SyncFolderSurvey(folder: xai, machineIDs: [me]), SyncFolderSurvey(folder: mac)]
        #expect(SyncFolderPlan.recommend(current: xai, detected: mac, surveys: surveys, machineID: me) == .keep)
        #expect(SyncFolderPlan.readOnlyFolders(primary: xai, surveys: surveys).isEmpty)
        #expect(SyncFolderPlan.readOnlyFolders(primary: nil, surveys: surveys).isEmpty)
    }

    // MARK: Candidates

    @Test func candidatesCoverParentFoundLegacyAndSubfoldersWithoutDuplicates() {
        let legacy = URL(fileURLWithPath: "/Users/s/iCloud", isDirectory: true)
        let list = SyncFolderPlan.candidateFolders(current: xai, detected: mac, legacy: [legacy, mac]) { root in
            SyncFolderPlan.same(root, self.mac) ? [self.xai, self.mac.appendingPathComponent("Old", isDirectory: true)] : []
        }
        #expect(list.map(\.lastPathComponent) == ["xAI", "MacSyncing", "iCloud", "Old"])
        #expect(SyncFolderPlan.same(URL(fileURLWithPath: "/a/b/"), URL(fileURLWithPath: "/a/./b")))
        #expect(!SyncFolderPlan.same(URL(fileURLWithPath: "/a"), nil))
        #expect(SyncFolderPlan.same(nil, nil))
    }

    @Test func surveyReadsTheGrokGaugeSubfolderFromDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("syncplan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!SyncFolderSurvey.read(root).hasData)   // missing folder: just empty
        try SettingsSync.write(GaugeSettings(), to: SettingsSync.fileURL(inSyncFolder: root))
        for id in ["a1", "b2"] {
            try HistorySync.write(MachineHistoryFile(machineID: id, machineName: id, history: UsageHistory()),
                                  to: HistorySync.fileURL(inSyncFolder: root, machineID: id))
        }
        let s = SyncFolderSurvey.read(root)
        #expect(s.hasSettingsFile)
        #expect(s.machineIDs == ["a1", "b2"])
        #expect(s.otherMacs(excluding: "a1") == 1)
    }

    // MARK: Status line

    let t: (Date) -> String = { _ in "11:38 PM" }

    @Test func oneStatusLineForSettingsAndHistory() {
        let h = SyncSummary.HistoryPart(enabled: true, machineCount: 3, machineNames: ["Air-M4", "MacBook Pro", "Studio"], lastSync: Date())
        #expect(SyncSummary.line(settings: .synced(Date()), history: h, time: t) == "In sync · 3 Macs (Air-M4, MacBook Pro, Studio) · synced 11:38 PM")
        // Settings off: still one line, about history.
        #expect(SyncSummary.line(settings: .off, history: h, time: t) == "In sync · 3 Macs (Air-M4, MacBook Pro, Studio) · synced 11:38 PM")
        // History off: no Mac count.
        #expect(SyncSummary.line(settings: .synced(Date()), history: .init(enabled: false), time: t) == "In sync · synced 11:38 PM")
        #expect(SyncSummary.line(settings: .off, history: .init(enabled: false), time: t).hasPrefix("Off"))
    }

    @Test func problemsReplaceInSync() {
        let h = SyncSummary.HistoryPart(enabled: true, machineCount: 1, machineNames: ["Air-M4"], lastSync: nil, error: "Disk is full", skipped: 2)
        let line = SyncSummary.line(settings: .failed("No permission to use that folder"), history: h, time: t)
        #expect(line == "⚠︎ Settings: No permission to use that folder · ⚠︎ History: Disk is full · 1 Mac (Air-M4) · ⚠︎ skipped 2 bad files (see Diagnostics)")
        #expect(!line.contains("In sync"))
        #expect(SyncSummary.line(settings: .waiting, history: .init(enabled: true), time: t) == "Syncing…")
    }

    @Test func latestOfTheTwoSyncTimesIsShown() {
        let early = Date(timeIntervalSince1970: 1_000), late = Date(timeIntervalSince1970: 2_000)
        let line = SyncSummary.line(settings: .synced(early), history: .init(enabled: true, machineCount: 2, lastSync: late)) {
            $0 == late ? "late" : "early"
        }
        #expect(line == "In sync · 2 Macs · synced late")
    }
}
