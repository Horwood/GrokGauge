import Foundation

/// The JSON file shared between Macs through a synced folder (`<folder>/GrokGauge/settings.json`).
/// It contains preferences only: never tokens, usage numbers, or history.
public struct SettingsEnvelope: Codable, Equatable, Sendable {
    public var app: String
    public var schema: Int
    public var settings: GaugeSettings

    public init(settings: GaugeSettings) {
        app = "GrokGauge"
        schema = GaugeSettings.schemaVersion
        self.settings = settings
    }
}

public enum SyncDecision: Equatable, Sendable {
    /// Both sides already match.
    case inSync
    /// The file is newer: apply it here.
    case adoptRemote(GaugeSettings)
    /// This Mac is newer (or the file is missing/unreadable): write ours.
    case writeLocal
}

public enum SettingsSync {
    public static let folderName = "GrokGauge"
    public static let fileName = "settings.json"
    /// Timestamps closer than this are treated as equal (JSON keeps milliseconds).
    static let tolerance: TimeInterval = 0.002

    public static func fileURL(inSyncFolder folder: URL) -> URL {
        folder.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(fileName)
    }

    /// Last write wins, by `modifiedAt`. Ties keep this Mac's copy.
    public static func resolve(local: GaugeSettings, remote: GaugeSettings?) -> SyncDecision {
        guard let remote else { return .writeLocal }
        let delta = remote.modifiedAt.timeIntervalSince(local.modifiedAt)
        if delta > tolerance { return .adoptRemote(remote) }
        if delta < -tolerance { return .writeLocal }
        return remote.sameContent(as: local) ? .inSync : .writeLocal
    }

    public static func encode(_ settings: GaugeSettings) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(Self.timestamp(date))
        }
        return try e.encode(SettingsEnvelope(settings: settings))
    }

    public static func decode(_ data: Data) throws -> GaugeSettings {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = ISODate.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date")
            }
            return date
        }
        return try d.decode(SettingsEnvelope.self, from: data).settings
    }

    static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// Reads the shared file. Missing file -> nil. Small files only.
    public static func read(from url: URL) throws -> GaugeSettings? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url, options: [.uncached])
        guard data.count < 512 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        return try decode(data)
    }

    /// Writes atomically (temp file + rename) so sync clients never see half a file.
    public static func write(_ settings: GaugeSettings, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(settings).write(to: url, options: [.atomic])
    }
}
