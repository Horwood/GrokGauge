import Foundation

/// The bearer credential `grok login` (Grok Build CLI) stores in `~/.grok/auth.json`.
/// GrokGauge only ever reads this file. It never refreshes, rewrites, logs, or
/// copies the token; it is sent solely to the billing endpoint in `BillingClient`.
public struct GrokCredential: Sendable {
    let token: String
    public let expiresAt: Date?
    public let email: String?

    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(30)
    }
}

extension GrokCredential: CustomStringConvertible, CustomDebugStringConvertible {
    // Make accidental printing harmless.
    public var description: String { "GrokCredential(expiresAt: \(String(describing: expiresAt)), token: <redacted>)" }
    public var debugDescription: String { description }
}

public enum AuthError: Error, Equatable {
    case notSignedIn            // no auth.json or no usable entry
    case unreadable             // file exists but could not be parsed
    case expired(Date)          // newest token has expired; `grok login` must refresh it
}

public enum AuthStore {
    /// `$GROK_HOME/auth.json`, defaulting to `~/.grok/auth.json`.
    public static var authFileURL: URL {
        if let home = ProcessInfo.processInfo.environment["GROK_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    public static func load(now: Date = Date(), from url: URL = authFileURL) throws -> GrokCredential {
        guard FileManager.default.fileExists(atPath: url.path) else { throw AuthError.notSignedIn }
        guard let data = try? Data(contentsOf: url) else { throw AuthError.unreadable }
        return try select(fromJSON: data, now: now)
    }

    /// auth.json is a map of `"<issuer>::<id>" -> { key, expires_at, email, ... }`.
    static func select(fromJSON data: Data, now: Date) throws -> GrokCredential {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AuthError.unreadable
        }

        struct Candidate { let preferred: Bool; let cred: GrokCredential }
        let candidates: [Candidate] = root.compactMap { (entryId, value) in
            guard let entry = value as? [String: Any],
                  let raw = entry["key"] as? String else { return nil }
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return nil }
            let expires = (entry["expires_at"] as? String).flatMap(ISODate.parse)
            let issuer = (entry["oidc_issuer"] as? String) ?? entryId
            return Candidate(
                preferred: issuer.hasPrefix("https://auth.x.ai") || entryId.hasPrefix("https://auth.x.ai"),
                cred: GrokCredential(token: token, expiresAt: expires, email: entry["email"] as? String)
            )
        }
        guard !candidates.isEmpty else { throw AuthError.notSignedIn }

        // Prefer valid tokens, then the SuperGrok (auth.x.ai) issuer, then the latest expiry.
        let sorted = candidates.sorted { a, b in
            let ae = a.cred.isExpired(now: now), be = b.cred.isExpired(now: now)
            if ae != be { return !ae }
            if a.preferred != b.preferred { return a.preferred }
            return (a.cred.expiresAt ?? .distantFuture) > (b.cred.expiresAt ?? .distantFuture)
        }
        let best = sorted[0].cred
        if best.isExpired(now: now), let exp = best.expiresAt { throw AuthError.expired(exp) }
        return best
    }
}
