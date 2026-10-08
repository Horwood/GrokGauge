import Foundation

/// A dotted version like "0.9.0" or "v1.2"; pre-release suffixes sort before the release.
public struct SemVer: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let parts: [Int]
    public let prerelease: String?

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let main = s.split(separator: "-", maxSplits: 1).map(String.init)
        guard let core = main.first, !core.isEmpty else { return nil }
        let nums = core.split(separator: ".").map { Int($0) }
        guard !nums.isEmpty, nums.allSatisfy({ $0 != nil }) else { return nil }
        parts = nums.map { $0! }
        prerelease = main.count > 1 ? main[1] : nil
    }

    public var description: String { parts.map(String.init).joined(separator: ".") + (prerelease.map { "-\($0)" } ?? "") }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        for i in 0..<n {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case (let p?, let q?): return p < q
        }
    }

    public static func == (a: SemVer, b: SemVer) -> Bool { !(a < b) && !(b < a) }
}

public struct ReleaseInfo: Codable, Equatable, Sendable {
    public let tag: String
    public let url: URL
    public let name: String?

    public init(tag: String, url: URL, name: String? = nil) {
        self.tag = tag
        self.url = url
        self.name = name
    }

    public var version: String { SemVer(tag)?.description ?? tag }
}

public enum UpdateCheck {
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/stevencombs/GrokGauge/releases/latest")!
    public static let brewUpgradeCommand = "brew upgrade --cask grokgauge"

    /// True when `latest` is a newer release than the running `current` version.
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let l = SemVer(latest), let c = SemVer(current) else { return false }
        return l > c
    }

    /// Parses GitHub's "latest release" JSON. Drafts and pre-releases are ignored.
    public static func parse(_ data: Data) -> ReleaseInfo? {
        struct Payload: Decodable {
            let tag_name: String?
            let html_url: String?
            let name: String?
            let draft: Bool?
            let prerelease: Bool?
        }
        guard let p = try? JSONDecoder().decode(Payload.self, from: data),
              p.draft != true, p.prerelease != true,
              let tag = p.tag_name, let urlString = p.html_url, let url = URL(string: urlString),
              url.scheme == "https", url.host == "github.com" else { return nil }
        return ReleaseInfo(tag: tag, url: url, name: p.name)
    }

    /// Asks GitHub for the latest release. Unauthenticated; sends no tokens or identifiers.
    public static func fetchLatest(appVersion: String) async throws -> ReleaseInfo? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.urlCache = nil
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GrokGauge/\(appVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request, delegate: NoRedirects())
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }
}

/// Exponential backoff for transient failures: 30 s, 60 s, 2 min, 4 min … capped.
public enum Backoff {
    public static func delay(attempt: Int, base: TimeInterval = 30, cap: TimeInterval = 15 * 60) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let exp = base * pow(2, Double(min(attempt - 1, 16)))
        return min(cap, exp)
    }
}
