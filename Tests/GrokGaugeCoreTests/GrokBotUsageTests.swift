import Foundation
import Testing
@testable import GrokGaugeCore

@Suite struct GrokBotUsageTests {
    // Shape copied from a real Grok Bot 0.68 cache (values changed).
    static func cacheJSON(percent: Double = 9.644111, resetMs: Int64 = 1_791_999_342_858,
                          readMs: Int64 = 1_791_426_487_974, expiresMs: Int64 = 1_791_512_887_975,
                          onDemand: String = "null") -> String {
        """
        {"schemaVersion":2,"value":{"kind":"present","selectedTeamId":null,"reading":{"usage":{
          "percentUsed":\(percent),"nextResetMs":\(resetMs),"isSandTrial":false,"hasNonZeroIncludedLimit":true,
          "isTeamSeat":false,"onDemand":\(onDemand),"grokPlanLabel":"SuperGrok Plus"},"readAtMs":\(readMs)},
          "expiresAtMs":\(expiresMs)}}
        """
    }

    static let slot = "grok|user_01TESTACCOUNT0000000000000"

    /// Writes a fake Grok Bot data folder and returns it.
    static func makeDataDir(slot: String? = GrokBotUsageTests.slot,
                            caches: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grokbot-test-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("sand-client-persistence", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(key: String, _ body: String) throws {
            let name = GrokBotUsageReader.base32Encode(Data(key.utf8)) + ".blob"
            try Data(body.utf8).write(to: dir.appendingPathComponent(name))
        }
        if let slot {
            try write(key: "sand.client.slice.client-meta.account-slot", #"{"schemaVersion":1,"value":"\#(slot)"}"#)
        }
        for (account, body) in caches {
            let enc = account.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_.!~*'()"))) ?? account
            try write(key: "sand.client.slice.account.\(enc).weekly-usage.cache", body)
        }
        try write(key: "sand.client.slice.ui-layout", #"{"value":{}}"#)
        return root
    }

    static let readTime = Date(timeIntervalSince1970: 1_791_426_600)   // shortly after readAtMs

    @Test func base32RoundTripsRealFileName() throws {
        // A real file name from Grok Bot's folder.
        let name = "onqw4zbomnwgszlooqxhg3djmnss4y3mnfsw45bnnvsxiyjomfrwg33vnz2c243mn52a"
        #expect(GrokBotUsageReader.decodeBlobName(name + ".blob") == "sand.client.slice.client-meta.account-slot")
        #expect(GrokBotUsageReader.base32Encode(Data("sand.client.slice.client-meta.account-slot".utf8)) == name)
        #expect(GrokBotUsageReader.base32Decode("not base32!") == nil)
    }

    @Test func parsesPresentReading() throws {
        let s = try GrokBotUsageReader.parseCache(Data(Self.cacheJSON().utf8))
        #expect(abs(s.percent - 9.644111) < 1e-9)
        #expect(s.roundedPercent == 10)
        #expect(s.level == .normal)
        #expect(s.nextReset == Date(timeIntervalSince1970: 1_791_999_342.858))
        #expect(s.readAt == Date(timeIntervalSince1970: 1_791_426_487.974))
        #expect(s.planLabel == "SuperGrok Plus")
        #expect(s.onDemandLimitCents == nil)
        #expect(s.periodKey == "bot-1791999342")
    }

    @Test func roundsLikeGrokBot() {
        func r(_ p: Double) -> Int { GrokBotSnapshot(percent: p, nextReset: nil, readAt: Date(), expiresAt: nil).roundedPercent }
        #expect(r(0) == 0)
        #expect(r(0.2) == 1)
        #expect(r(9.4) == 9)
        #expect(r(9.64) == 10)
        #expect(r(80.4) == 80)
        #expect(r(80.6) == 81)
        #expect(r(140) == 100)
    }

    @Test func parsesOnDemand() throws {
        let s = try GrokBotUsageReader.parseCache(Data(Self.cacheJSON(onDemand: #"{"usedCents":250,"limitCents":2000}"#).utf8))
        #expect(s.onDemandUsedCents == 250)
        #expect(s.onDemandLimitCents == 2000)
    }

    @Test func absentReadingIsUnavailable() {
        let json = #"{"schemaVersion":2,"value":{"kind":"absent","selectedTeamId":null,"expiresAtMs":1791512887975}}"#
        #expect(throws: GrokBotUsageError.unavailable) { try GrokBotUsageReader.parseCache(Data(json.utf8)) }
    }

    @Test func garbageIsUnrecognized() {
        #expect(throws: GrokBotUsageError.unrecognized) { try GrokBotUsageReader.parseCache(Data("{}".utf8)) }
        #expect(throws: GrokBotUsageError.unrecognized) {
            try GrokBotUsageReader.parseCache(Data(#"{"value":{"kind":"present","reading":{"usage":{"percentUsed":true},"readAtMs":1}}}"#.utf8))
        }
    }

    @Test func readsActiveAccountFromDisk() throws {
        let dir = try Self.makeDataDir(caches: [
            Self.slot: Self.cacheJSON(percent: 9.6),
            "grok|user_SOMEONEELSE": Self.cacheJSON(percent: 55, readMs: 1_791_426_500_000),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try GrokBotUsageReader.read(dataDir: dir, now: Self.readTime)
        #expect(s.roundedPercent == 10)
    }

    @Test func withoutSlotPicksNewestReading() throws {
        let dir = try Self.makeDataDir(slot: nil, caches: [
            "grok|user_A": Self.cacheJSON(percent: 9.6, readMs: 1_791_426_000_000),
            "grok|user_B": Self.cacheJSON(percent: 55, readMs: 1_791_426_500_000),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try GrokBotUsageReader.read(dataDir: dir, now: Self.readTime).roundedPercent == 55)
    }

    @Test func signedInAccountWithoutReadingDoesNotBorrowAnother() throws {
        let dir = try Self.makeDataDir(caches: ["grok|user_SOMEONEELSE": Self.cacheJSON()])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: GrokBotUsageError.noReading) { try GrokBotUsageReader.read(dataDir: dir, now: Self.readTime) }
    }

    @Test func expiredOrResetReadingIsStale() throws {
        let dir = try Self.makeDataDir(caches: [Self.slot: Self.cacheJSON()])
        defer { try? FileManager.default.removeItem(at: dir) }
        let afterExpiry = Date(timeIntervalSince1970: 1_791_512_888)
        #expect {
            try GrokBotUsageReader.read(dataDir: dir, now: afterExpiry)
        } throws: { error in
            if case GrokBotUsageError.stale(let s)? = error as? GrokBotUsageError { return s.roundedPercent == 10 }
            return false
        }
        // Reset passed even though Grok Bot's cache TTL hasn't.
        let s = try GrokBotUsageReader.parseCache(Data(Self.cacheJSON(resetMs: 1_791_426_550_000).utf8))
        #expect(s.isStale(now: Self.readTime))
        #expect(!s.isStale(now: Date(timeIntervalSince1970: 1_791_426_500)))
    }

    @Test func missingFolderMeansNotInstalled() {
        let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent("no-grokbot-\(UUID().uuidString)")
        #expect(throws: GrokBotUsageError.notInstalled) { try GrokBotUsageReader.read(dataDir: nowhere) }
    }

    @Test func emptyPersistenceMeansNoReading() throws {
        let dir = try Self.makeDataDir(slot: nil, caches: [:])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: GrokBotUsageError.noReading) { try GrokBotUsageReader.read(dataDir: dir) }
    }

    @Test func refusesSymlinkedCache() throws {
        let dir = try Self.makeDataDir(caches: [:])
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("elsewhere.json")
        try Data(Self.cacheJSON().utf8).write(to: target)
        let enc = "grok%7Cuser_01TESTACCOUNT0000000000000"
        let name = GrokBotUsageReader.base32Encode(Data("sand.client.slice.account.\(enc).weekly-usage.cache".utf8)) + ".blob"
        try FileManager.default.createSymbolicLink(
            at: GrokBotUsageReader.persistenceDirectory(in: dir).appendingPathComponent(name), withDestinationURL: target)
        #expect(throws: GrokBotUsageError.noReading) { try GrokBotUsageReader.read(dataDir: dir, now: Self.readTime) }
    }

    @Test func menuBarHighest() {
        #expect(MenuBarTitle.segments(grok: 0, bot: 9, style: .highest) == [MenuBarSegment(text: " 9%", level: .normal)])
        #expect(MenuBarTitle.segments(grok: 91, bot: 9, style: .highest) == [MenuBarSegment(text: " 91%", level: .critical)])
        #expect(MenuBarTitle.segments(grok: nil, bot: 86, style: .highest) == [MenuBarSegment(text: " 86%", level: .warning)])
        #expect(MenuBarTitle.segments(grok: nil, bot: nil, style: .highest).isEmpty)
    }

    @Test func menuBarBoth() {
        let segs = MenuBarTitle.segments(grok: 0, bot: 9, style: .both)
        #expect(segs.map(\.text).joined() == " G 0% · B 9%")
        #expect(segs[1].level == .normal && segs[3].level == .normal && segs[0].level == nil)
        let missing = MenuBarTitle.segments(grok: 42, bot: nil, style: .both)
        #expect(missing.map(\.text).joined() == " G 42% · B –")
        #expect(missing[3].level == nil)
    }
}
