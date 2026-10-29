import Foundation
import Testing
@testable import GrokGaugeCore

/// The current-usage file is the ring split, written so another program can read it.
/// Unlike history, the newest reading wins — a weekly reset must not lose to an older, higher percent.
@Suite struct UsageNowTests {
    let now = Date(timeIntervalSince1970: 1_792_442_000)   // Oct 19 2026
    var end: Date { Date(timeIntervalSince1970: 1_792_655_700) }

    func pool(_ percent: Double, products: [(String, Double)], at: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(percent: percent, percentInferred: false, period: .weekly,
                      periodStart: end.addingTimeInterval(-7 * 86_400), periodEnd: end,
                      products: products.map { ProductShare(key: $0.0, name: $0.0, symbol: "x", percent: $0.1) },
                      prepaidBalanceCents: 1446, onDemandUsedCents: 20, onDemandCapCents: 5000, fetchedAt: at ?? now)
    }

    func bot(_ percent: Double, at: Date? = nil) -> GrokBotSnapshot {
        GrokBotSnapshot(percent: percent, nextReset: end, readAt: at ?? now.addingTimeInterval(-30), expiresAt: nil)
    }

    let oct21: [(String, Double)] = [("GrokBot", 70.2), ("Cursor", 17.9), ("GrokChat", 6.1), ("GrokImagine", 1.4)]

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gg-nown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func fileMatchesTheRings() {
        let p = pool(95.9, products: oct21)
        let ring = BotRingReading.make(bot: bot(95.9), pool: p, knownSharedEnd: nil)
        let file = UsageNowFile.make(machineID: "abc", machineName: "Studio", pool: p, bot: ring, now: now)
        let breakdown = PoolBreakdown.make(pool: p, bot: ring)
        #expect(file?.total?.rounded == PoolBreakdown.whole(95.9))
        #expect(file?.total?.level == "critical")
        #expect(file?.grok?.rounded == breakdown.roundedGrok)
        #expect(file?.grokBot?.rounded == ring.roundedPercent)
        #expect(file?.grokBotMode == "shared")
        #expect(file?.cursor?.rounded == PoolBreakdown.whole(17.9))
        #expect(file?.equation == breakdown.equation)
        #expect(file?.equation == "Grok 8% + Grok Bot 70% + Cursor 18% = Total 96%")
        // updatedAt is when the numbers were read, not "now".
        #expect(file?.updatedAt == now)
        #expect(file?.period == "weekly")
        #expect(file?.periodEnd == end)
    }

    @Test func separateBotIsNotSubtractedAsASlice() {
        // Different reset: Grok Bot has its own allowance. Its percent must not come out of Total.
        var own = bot(12)
        own.nextReset = end.addingTimeInterval(3 * 3600)
        let p = pool(40, products: [("GrokChat", 40)])
        let ring = BotRingReading.make(bot: own, pool: p, knownSharedEnd: nil)
        #expect(!ring.isShared)
        let file = UsageNowFile.make(machineID: "abc", machineName: "Air", pool: p, bot: ring)
        #expect(file?.grokBotMode == "separate")
        #expect(file?.grokBot?.percent == 12)
        #expect(file?.grok?.rounded == 40)
        #expect(file?.cursor?.rounded == 0)
    }

    @Test func sharedWeekWithoutAShareDoesNotInventOne() throws {
        let own = bot(40)
        let ring = BotRingReading.make(bot: own, pool: nil, knownSharedEnd: end)
        #expect(ring.isShared && ring.percent == nil)
        let file = try #require(UsageNowFile.make(machineID: "abc", machineName: "Air", pool: nil, bot: ring))
        #expect(file.total == nil)
        #expect(file.grok == nil)
        #expect(file.grokBot == nil)
        #expect(file.grokBotMode == "shared")
    }

    @Test func nothingToSayStaysNil() {
        #expect(UsageNowFile.make(machineID: "abc", machineName: "Air", pool: nil, bot: nil) == nil)
        #expect(UsageNowFile.make(machineID: "  ", machineName: "Air", pool: pool(1, products: []), bot: nil) == nil)
    }

    @Test func signedOutClearsThePoolWithoutLeavingALoadingFile() {
        let file = UsageNowFile.make(machineID: "abc", machineName: "Air", pool: nil, bot: nil,
                                    grokUnavailable: true, now: now)
        #expect(file?.total == nil)
        #expect(file?.grokGap == "unavailable")
        #expect(file?.updatedAt == now)
        // Still loading is not the same state: no file, so the previous one stays put.
        #expect(UsageNowFile.make(machineID: "abc", machineName: "Air", pool: nil, bot: nil, grokUnavailable: false) == nil)
    }

    @Test func jsonHasNoSecrets() throws {
        let p = pool(10, products: [("GrokChat", 10)])
        let ring = BotRingReading.make(bot: bot(4, at: now), pool: nil, knownSharedEnd: nil)
        let file = try #require(UsageNowFile.make(machineID: "abc", machineName: "Studio", pool: p, bot: ring))
        let data = try UsageNowSync.encode(file)
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["prepaid", "onDemand", "token", "email", "cents", "auth.json", "user_"] {
            #expect(!text.contains(forbidden), "usage file contains \(forbidden)")
        }
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["kind"] as? String == "usageNow")
        #expect(obj["schema"] as? Int == 1)
        let back = try UsageNowSync.decode(data)
        #expect(back == file)
        #expect(back.updatedAt == file.updatedAt)
    }

    @Test func rejectsTheWrongKindAndANewerSchema() throws {
        let file = try #require(UsageNowFile.make(machineID: "abc", machineName: "Studio",
                                                  pool: pool(1, products: []), bot: nil))
        var obj = try #require(JSONSerialization.jsonObject(with: try UsageNowSync.encode(file)) as? [String: Any])
        obj["kind"] = "usageHistory"
        #expect(throws: UsageNowError.notAUsageFile) {
            try UsageNowSync.decode(try JSONSerialization.data(withJSONObject: obj))
        }
        obj["kind"] = "usageNow"
        obj["schema"] = 99
        #expect(throws: UsageNowError.newerSchema(99)) {
            try UsageNowSync.decode(try JSONSerialization.data(withJSONObject: obj))
        }
    }

    @Test func dropsADamagedPercent() throws {
        let file = try #require(UsageNowFile.make(machineID: "abc", machineName: "Studio",
                                                  pool: pool(12, products: [("GrokChat", 12)]), bot: nil))
        var obj = try #require(JSONSerialization.jsonObject(with: try UsageNowSync.encode(file)) as? [String: Any])
        var total = try #require(obj["total"] as? [String: Any])
        total["percent"] = -4
        obj["total"] = total
        var products = try #require(obj["products"] as? [[String: Any]])
        products.append(["key": "nope", "name": "Nope", "percent": 5_000])
        obj["products"] = products
        let back = try UsageNowSync.decode(try JSONSerialization.data(withJSONObject: obj))
        #expect(back.total == nil)
        #expect(back.products?.contains(where: { $0.key == "nope" }) == false)
        #expect(back.grok?.percent == file.grok?.percent)
    }

    @Test func newestReadingWinsNotTheHigherPercent() throws {
        // Studio fell asleep at 96%. Air read the pool after the reset: 4%, later.
        let studio = try #require(UsageNowFile.make(machineID: "studio", machineName: "Studio",
                                                    pool: pool(96, products: [("GrokChat", 96)], at: now.addingTimeInterval(-3600)),
                                                    bot: nil))
        let air = try #require(UsageNowFile.make(machineID: "air", machineName: "Air",
                                                pool: pool(4, products: [("GrokChat", 4)], at: now),
                                                bot: nil))
        let dir = try tempDir()
        let folder = dir.appendingPathComponent("Sync", isDirectory: true)
        try UsageNowSync.write(studio, to: UsageNowSync.fileURL(inSyncFolder: folder, machineID: studio.machineID))
        try UsageNowSync.write(air, to: UsageNowSync.fileURL(inSyncFolder: folder, machineID: air.machineID))
        // A conflict copy of Studio with the same moment must not add a Mac, or beat Air.
        let copy = UsageNowSync.directory(inSyncFolder: folder).appendingPathComponent("studio (1).json")
        try UsageNowSync.write(studio, to: copy)
        try Data("not json".utf8).write(to: UsageNowSync.directory(inSyncFolder: folder).appendingPathComponent("notes.json"))
        let read = UsageNowSync.readAll(directory: UsageNowSync.directory(inSyncFolder: folder))
        #expect(read.skipped.map(\.fileName) == ["notes.json"])
        let pick = try #require(UsageNowSync.freshest(read, now: now.addingTimeInterval(60)))
        #expect(pick.file.machineID == "air")
        #expect(pick.file.total?.percent == 4)
        #expect(pick.machineCount == 2)
        #expect(!pick.stale)
    }

    @Test func staleWhenEveryMacIsOld() throws {
        let old = try #require(UsageNowFile.make(machineID: "studio", machineName: "Studio",
                                                pool: pool(10, products: [], at: now.addingTimeInterval(-5 * 3600)),
                                                bot: nil))
        let pick = try #require(UsageNowSync.freshest(UsageNowRead(files: [UsageNowDiskFile(fileName: "studio.json", file: old)]), now: now))
        #expect(pick.stale)
    }

    @Test func ignoresAFileFromTheFuture() {
        let future = UsageNowFile(machineID: "air", machineName: "Air", updatedAt: now.addingTimeInterval(3600),
                                  total: UsageNowReading(percent: 1, rounded: 1, level: "normal", readAt: now.addingTimeInterval(3600)))
        let real = UsageNowFile(machineID: "studio", machineName: "Studio", updatedAt: now,
                                total: UsageNowReading(percent: 50, rounded: 50, level: "normal", readAt: now))
        let read = UsageNowRead(files: [
            UsageNowDiskFile(fileName: "air.json", file: future),
            UsageNowDiskFile(fileName: "studio.json", file: real),
        ])
        #expect(UsageNowSync.freshest(read, now: now)?.file.machineID == "studio")
    }

    @Test func machineIDCannotEscapeTheFolder() {
        let url = UsageNowSync.fileURL(inSyncFolder: URL(fileURLWithPath: "/tmp/sync"), machineID: "../etc/passwd")
        #expect(url.lastPathComponent == "___etc_passwd.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "now")
    }
}
