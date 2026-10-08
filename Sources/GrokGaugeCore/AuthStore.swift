import Foundation

/// One login entry from `~/.grok/auth.json` (written by `grok login`, the Grok Build CLI).
/// The file is a map of `"<issuer>::<client_id>" -> { key, refresh_token, expires_at, oidc_issuer, oidc_client_id, ... }`.
/// Tokens are only ever sent to the billing endpoint (`key`) and the auth.x.ai token endpoint (`refresh_token`).
public struct GrokCredential: Sendable, Equatable {
    public let entryID: String
    let token: String
    let refreshToken: String?
    public let expiresAt: Date?
    public let email: String?
    public let issuer: String?
    public let clientID: String?
    let principalType: String?
    let principalID: String?

    public func isExpired(now: Date = Date(), buffer: TimeInterval = 30) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(buffer)
    }

    /// Everything a refresh needs: a refresh token, the issuer, and the OAuth client id.
    public var canRefresh: Bool {
        !(refreshToken ?? "").isEmpty && !(issuer ?? "").isEmpty && !(clientID ?? "").isEmpty
    }

    /// True when `other` carries a different access token (e.g. the CLI refreshed meanwhile).
    func hasDifferentToken(than other: GrokCredential) -> Bool { token != other.token }
    func hasDifferentRefreshToken(than other: GrokCredential) -> Bool { refreshToken != other.refreshToken }
    func isToken(_ t: String?) -> Bool { t != nil && token == t }
}

extension GrokCredential: CustomStringConvertible, CustomDebugStringConvertible {
    // Make accidental printing harmless.
    public var description: String {
        "GrokCredential(entry: \(entryID), expiresAt: \(String(describing: expiresAt)), tokens: <redacted>)"
    }
    public var debugDescription: String { description }
}

public enum AuthError: Error, Equatable {
    case notSignedIn            // no auth.json or no usable entry
    case unreadable             // file exists but could not be parsed
    case expired(Date)          // token expired and can't be renewed (no refresh token)
    case refreshRejected        // auth.x.ai rejected the refresh token (revoked/expired): `grok login` needed
    case refreshUnavailable     // couldn't reach auth.x.ai and the current token is no longer usable
}

public enum AuthStore {
    /// `$GROK_AUTH_PATH`, else `$GROK_HOME/auth.json`, else `~/.grok/auth.json` (same order as the Grok CLI).
    public static var authFileURL: URL {
        let env = ProcessInfo.processInfo.environment
        if let path = env["GROK_AUTH_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        if let home = env["GROK_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    /// The best entry in the file, even if its access token has expired (it may still be renewable).
    public static func readBest(from url: URL = authFileURL, now: Date = Date(), preferring id: String? = nil) throws -> GrokCredential {
        guard FileManager.default.fileExists(atPath: url.path) else { throw AuthError.notSignedIn }
        guard let data = try? Data(contentsOf: url) else { throw AuthError.unreadable }
        return try select(fromJSON: data, now: now, preferring: id)
    }

    static func entries(fromJSON data: Data) throws -> [GrokCredential] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AuthError.unreadable
        }
        func str(_ v: Any?) -> String? {
            guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        return root.compactMap { (entryID, value) in
            guard let entry = value as? [String: Any] else { return nil }
            let token = str(entry["key"])
            let refresh = str(entry["refresh_token"])
            guard token != nil || refresh != nil else { return nil }
            let scopeParts = entryID.components(separatedBy: "::")
            return GrokCredential(
                entryID: entryID,
                token: token ?? "",
                refreshToken: refresh,
                expiresAt: str(entry["expires_at"]).flatMap(ISODate.parse),
                email: str(entry["email"]),
                issuer: str(entry["oidc_issuer"]) ?? (scopeParts.count == 2 ? scopeParts[0] : nil),
                clientID: str(entry["oidc_client_id"]) ?? (scopeParts.count == 2 ? scopeParts[1] : nil),
                principalType: str(entry["principal_type"]),
                principalID: str(entry["principal_id"])
            )
        }
    }

    static func select(fromJSON data: Data, now: Date, preferring id: String? = nil) throws -> GrokCredential {
        let all = try entries(fromJSON: data)
        if let id, let match = all.first(where: { $0.entryID == id }) { return match }
        guard !all.isEmpty else { throw AuthError.notSignedIn }
        func preferred(_ c: GrokCredential) -> Bool {
            (c.issuer ?? c.entryID).hasPrefix("https://auth.x.ai") || c.entryID.hasPrefix("https://auth.x.ai")
        }
        // Prefer entries that work now or can be renewed, then the SuperGrok (auth.x.ai) issuer,
        // then currently valid ones, then the latest expiry.
        return all.sorted { a, b in
            let au = !a.token.isEmpty && !a.isExpired(now: now), bu = !b.token.isEmpty && !b.isExpired(now: now)
            let aOK = au || a.canRefresh, bOK = bu || b.canRefresh
            if aOK != bOK { return aOK }
            if preferred(a) != preferred(b) { return preferred(a) }
            if au != bu { return au }
            return (a.expiresAt ?? .distantFuture) > (b.expiresAt ?? .distantFuture)
        }[0]
    }
}

/// Pure decision logic for when to renew. Kept free of I/O so it's easy to test.
public enum RefreshPolicy {
    public enum Decision: Equatable { case useCurrent, refresh, reconnect }

    /// Renew when the access token is within this long of expiring.
    public static let defaultWindow: TimeInterval = 60 * 60

    /// - Parameters:
    ///   - rejected: the billing endpoint just answered 401/403 for this credential's token.
    ///   - force: renew regardless of expiry (`--refresh-now`).
    public static func decide(_ c: GrokCredential, now: Date, window: TimeInterval = defaultWindow,
                              rejected: Bool = false, force: Bool = false) -> Decision {
        if force || rejected || c.token.isEmpty {
            return c.canRefresh ? .refresh : .reconnect
        }
        guard let exp = c.expiresAt else { return .useCurrent }
        if exp.timeIntervalSince(now) > window { return .useCurrent }
        if c.canRefresh { return .refresh }
        return c.isExpired(now: now) ? .reconnect : .useCurrent
    }

    /// After taking the lock and re-reading auth.json: adopt what's on disk instead of spending the
    /// refresh token when someone else (usually the Grok CLI) already renewed.
    public static func shouldAdopt(disk: GrokCredential, tried: GrokCredential, rejectedToken: String?,
                                   now: Date, window: TimeInterval = defaultWindow, force: Bool = false) -> Bool {
        if force { return false }
        guard disk.hasDifferentToken(than: tried), !disk.token.isEmpty, !disk.isToken(rejectedToken) else { return false }
        return decide(disk, now: now, window: window) == .useCurrent && !disk.isExpired(now: now, buffer: 300)
    }
}
