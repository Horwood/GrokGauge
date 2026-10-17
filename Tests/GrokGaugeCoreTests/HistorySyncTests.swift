import Foundation
import Testing
@testable import GrokGaugeCore

@Suite struct HistorySyncTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    func t(_ hoursAgo: Double) -> Date { now.addingTimeInterval(-hoursAgo * 3600) }

    func history(grok: [(Double, Double)] = [], bot: [(Double, Double)] = []) -> UsageHistory {
        var h = UsageHistory()
        h.grok = grok.map { UsageSample(t: t($0.0), p: $0.1) }.sorted { $0.t < $1.t }
        h.grokBot = bot.map { UsageSample(t: t($0.0), p: $0.1) }.sorted { $0.t < $1.t }
        return h
    }

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gg-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Merge

    @Test func sameBucketTakesMaxNotSum() {
        // Two Macs read account-wide usage minutes apart: one reading, the higher one.
        let a = history(grok: [(2.0, 40)])
        let b = history(grok: [(2.0 - 3.0 / 60, 41)])
        let m = HistorySync.merge(local: a, others: [b], now: now)
        #expect(m.grok.count == 1)
        #expect(m.grok.first?.p == 41)
        // Identical readings collapse to one.
        let same = HistorySync.merge(local: a, others: [a, a], now: now)
        #expect(same.grok.map(\.p) == [40])
    }

    @Test func multipleMachinesInterleaveAndStaySorted() {
        let studio = history(grok: [(30, 10), (10, 30)], bot: [(20, 5)])
        let air = history(grok: [(20, 20), (5, 35)], bot: [(4, 9)])
        let mbp = history(grok: [(1, 40)])
        let m = HistorySync.merge(local: studio, others: [air, mbp], now: now)
        #expect(m.grok.map(\.p) == [10, 20, 30, 35, 40])
        #expect(m.grok.map(\.t) == m.grok.map(\.t).sorted())
        // Grok and Grok Bot never mix.
        #expect(m.grokBot.map(\.p) == [5, 9])
    }

    @Test func trimsToHistoryWindowAndDropsFuture() {
        let old = history(grok: [(UsageHistory.keep / 3600 + 1, 70), (3, 20)])
        let future = history(grok: [(-1, 99)])
        let m = HistorySync.merge(local: old, others: [future], now: now)
        #expect(m.grok.map(\.p) == [20])
    }

    @Test func dropsNonFiniteAndNegative() {
        var bad = UsageHistory()
        bad.grok = [UsageSample(t: t(3), p: .nan), UsageSample(t: t(2), p: -5), UsageSample(t: t(1), p: 12)]
        #expect(HistorySync.merge(local: UsageHistory(), others: [bad], now: now).grok.map(\.p) == [12])
    }

    @Test func staleDipIsRemovedButRealResetKept() {
        // 50 → 47 (another Mac's slightly old reading) → 52: the dip isn't a reset.
        let a = history(grok: [(6, 50), (2, 52)])
        let b = history(grok: [(4, 47)])
        #expect(HistorySync.merge(local: a, others: [b], now: now).grok.map(\.p) == [50, 52])
        // 80 → 2 → 3 is a real weekly reset and stays.
        let r = history(grok: [(6, 80), (4, 2), (2, 3)])
        let merged = HistorySync.merge(local: r, others: [], now: now)
        #expect(merged.grok.map(\.p) == [80, 2, 3])
    }

    @Test func dailyPeakUsesEveryMac() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let a = history(grok: [(1, 30)])
        let b = history(grok: [(0.5, 33)])
        let m = HistorySync.merge(local: a, others: [b], now: now)
        #expect(m.daily(.grok, days: 1, now: now, calendar: cal).first?.peak == 33)
    }

    // MARK: Files

    @Test func roundTripsAndHoldsOnlyUsage() throws {
        let f = MachineHistoryFile(machineID: "abc123", machineName: "Studio M2", updatedAt: now,
                                   history: history(grok: [(1, 12.5)], bot: [(2, 7)]))
        let data = try HistorySync.encode(f)
        let back = try HistorySync.decode(data)
        #expect(back == f)
        let keys = Set(try (JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]).keys)
        #expect(keys == ["app", "kind", "schema", "machineID", "machineName", "updatedAt", "grok", "grokBot"])
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("token") && !text.contains(".grok"))
    }

    @Test func fileNameIsSafe() {
        let folder = URL(fileURLWithPath: "/tmp/MacSyncing")
        #expect(HistorySync.fileURL(inSyncFolder: folder, machineID: "3f9c2a7d").path == "/tmp/MacSyncing/GrokGauge/history/3f9c2a7d.json")
        #expect(HistorySync.safeFileStem("../../etc/passwd") == "______etc_passwd")
        #expect(HistorySync.safeFileStem("") == "mac")
    }

    @Test func conflictCopyNames() {
        #expect(HistorySync.isConflictCopy("3f9c (1).json"))
        #expect(HistorySync.isConflictCopy("3f9c (conflicted copy 2026-10-17).json"))
        #expect(HistorySync.isConflictCopy("3f9c-Conflict-studio.json"))
        #expect(HistorySync.isConflictCopy("3f9c 2.json"))
        #expect(!HistorySync.isConflictCopy("3f9c2a7d41b08e55.json"))
    }

    @Test func readAllSkipsCorruptPartialAndForeignFilesWithoutThrowing() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = MachineHistoryFile(machineID: "aaa", machineName: "Air", updatedAt: now, history: history(grok: [(1, 20)]))
        let other = MachineHistoryFile(machineID: "bbb", machineName: "Studio", updatedAt: now, history: history(grok: [(2, 18)]))
        try HistorySync.write(good, to: dir.appendingPathComponent("aaa.json"))
        try HistorySync.write(other, to: dir.appendingPathComponent("bbb.json"))
        // Insync conflict copy of Air's file: readable, merged, but still one Mac.
        try HistorySync.write(good, to: dir.appendingPathComponent("aaa (1).json"))
        // Half-written file, garbage, a settings file, a newer schema, hidden/temp and non-JSON files.
        let full = try HistorySync.encode(other)
        try full.prefix(full.count / 2).write(to: dir.appendingPathComponent("ccc.json"))
        try Data("not json".utf8).write(to: dir.appendingPathComponent("ddd.json"))
        try Data(#"{"app":"GrokGauge","schema":2,"settings":{}}"#.utf8).write(to: dir.appendingPathComponent("eee.json"))
        var newer = good; newer.schema = 99; newer.machineID = "fff"
        try HistorySync.encode(newer).write(to: dir.appendingPathComponent("fff.json"))
        try Data("x".utf8).write(to: dir.appendingPathComponent(".aaa.json.tmp"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        let read = HistorySync.readAll(directory: dir)
        #expect(read.machineCount == 2)
        #expect(read.files.count == 3)
        #expect(read.machineNames == ["Air", "Studio"])
        #expect(read.conflictCopies == ["aaa (1).json"])
        #expect(Set(read.skipped.map(\.fileName)) == ["ccc.json", "ddd.json", "eee.json", "fff.json"])
        #expect(read.skipped.first { $0.fileName == "fff.json" }?.reason.contains("newer") == true)

        let merged = HistorySync.merge(local: UsageHistory(), others: read.files.map(\.history), now: now)
        #expect(merged.grok.map(\.p) == [18, 20])
    }

    @Test func missingFolderIsEmpty() {
        let read = HistorySync.readAll(directory: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"))
        #expect(read == HistorySyncRead())
        #expect(read.machineCount == 0)
    }

    @Test func atomicWriteReplacesOwnFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = HistorySync.fileURL(inSyncFolder: dir, machineID: "me")
        try HistorySync.write(MachineHistoryFile(machineID: "me", machineName: "A", updatedAt: now, history: history(grok: [(2, 1)])), to: url)
        try HistorySync.write(MachineHistoryFile(machineID: "me", machineName: "A", updatedAt: now, history: history(grok: [(1, 2)])), to: url)
        let read = HistorySync.readAll(directory: url.deletingLastPathComponent())
        #expect(read.files.count == 1)
        #expect(read.files.first?.grok.map(\.p) == [2])
    }

    // MARK: Folder choice

    @Test func folderPrecedence() {
        let chosen = URL(fileURLWithPath: "/c"), settings = URL(fileURLWithPath: "/s"), found = URL(fileURLWithPath: "/f")
        #expect(HistorySyncFolder.resolve(chosen: chosen, settingsSync: settings, detected: found)?.origin == .chosen)
        #expect(HistorySyncFolder.resolve(chosen: nil, settingsSync: settings, detected: found)?.url == settings)
        #expect(HistorySyncFolder.resolve(chosen: nil, settingsSync: nil, detected: found)?.origin == .detected)
        #expect(HistorySyncFolder.resolve(chosen: nil, settingsSync: nil, detected: nil) == nil)
        #expect(HistorySyncFolder.isEnabled(stored: nil))
        #expect(!HistorySyncFolder.isEnabled(stored: false))
    }
}
