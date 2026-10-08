import Foundation

/// Hands out a usable Grok credential, renewing it when needed.
///
/// Renewal follows the Grok CLI's own rules so both can share `~/.grok/auth.json` safely:
/// take the CLI's `auth.json.lock` (flock), re-read the file, adopt a token the CLI already renewed,
/// otherwise spend the refresh token once and write the result back atomically.
public actor AuthSession {
    public struct Result: Sendable {
        public let credential: GrokCredential
        public let refreshed: Bool        // GrokGauge renewed the token just now
        public let adopted: Bool          // someone else (the CLI) had renewed it already
        public let refreshTokenRotated: Bool
    }

    private let authURL: URL
    private let refresher: TokenRefreshing
    private let window: TimeInterval
    private let lockTimeout: TimeInterval
    private let clock: @Sendable () -> Date

    public init(authURL: URL = AuthStore.authFileURL,
                refresher: TokenRefreshing = OIDCTokenRefresher(),
                window: TimeInterval = RefreshPolicy.defaultWindow,
                lockTimeout: TimeInterval = 20,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.authURL = authURL
        self.refresher = refresher
        self.window = window
        self.lockTimeout = lockTimeout
        self.clock = clock
    }

    /// - Parameters:
    ///   - rejectedToken: pass the credential the billing endpoint just refused (401/403).
    ///   - force: renew even if the token is fresh (debug `--refresh-now`).
    public func credential(rejecting rejected: GrokCredential? = nil, force: Bool = false) async throws -> Result {
        let now = clock()
        let current = try AuthStore.readBest(from: authURL, now: now, preferring: rejected?.entryID)
        let wasRejected = rejected.map { current.isToken($0.token) } ?? false

        // The file already holds a different token than the one that was refused: just use it.
        if rejected != nil, !wasRejected, !current.token.isEmpty, !current.isExpired(now: now) {
            return Result(credential: current, refreshed: false, adopted: true, refreshTokenRotated: false)
        }

        switch RefreshPolicy.decide(current, now: now, window: window, rejected: wasRejected, force: force) {
        case .useCurrent:
            return Result(credential: current, refreshed: false, adopted: false, refreshTokenRotated: false)
        case .reconnect:
            if wasRejected { throw AuthError.refreshRejected }
            throw AuthError.expired(current.expiresAt ?? now)
        case .refresh:
            return try await renew(current, rejectedToken: wasRejected ? current.token : nil, force: force)
        }
    }

    private func renew(_ tried: GrokCredential, rejectedToken: String?, force: Bool) async throws -> Result {
        let lock: AuthFileLock
        do {
            lock = try await AuthFileLock.acquire(for: authURL, timeout: lockTimeout)
        } catch {
            // The CLI may be mid-refresh. Keep using a still-valid token; otherwise retry next cycle.
            if rejectedToken == nil, !tried.isExpired(now: clock()) {
                return Result(credential: tried, refreshed: false, adopted: false, refreshTokenRotated: false)
            }
            throw AuthError.refreshUnavailable
        }
        defer { lock.release() }

        // Re-read under the lock: the CLI may have renewed while we waited.
        let disk = try AuthStore.readBest(from: authURL, now: clock(), preferring: tried.entryID)
        if RefreshPolicy.shouldAdopt(disk: disk, tried: tried, rejectedToken: rejectedToken,
                                     now: clock(), window: window, force: force) {
            return Result(credential: disk, refreshed: false, adopted: true, refreshTokenRotated: false)
        }

        do {
            return try await exchangeAndPersist(disk)
        } catch RefreshError.rejected {
            // A sibling may have rotated the refresh token underneath us; retry once with what's on disk now.
            if let again = try? AuthStore.readBest(from: authURL, now: clock(), preferring: tried.entryID),
               again.hasDifferentRefreshToken(than: disk), again.canRefresh {
                if again.hasDifferentToken(than: disk), !again.isExpired(now: clock(), buffer: 300),
                   !again.isToken(rejectedToken) {
                    return Result(credential: again, refreshed: false, adopted: true, refreshTokenRotated: false)
                }
                if let r = try? await exchangeAndPersist(again) { return r }
            }
            throw AuthError.refreshRejected
        } catch RefreshError.notConfigured, RefreshError.notAllowed {
            throw AuthError.refreshRejected
        } catch let e as AuthFileError {
            throw e
        } catch {
            // Transient: keep going with the current token while it still works.
            if rejectedToken == nil, !disk.token.isEmpty, !disk.isExpired(now: clock()) {
                return Result(credential: disk, refreshed: false, adopted: false, refreshTokenRotated: false)
            }
            throw AuthError.refreshUnavailable
        }
    }

    private func exchangeAndPersist(_ c: GrokCredential) async throws -> Result {
        let started = clock()
        let tokens = try await refresher.refresh(c)
        let update = TokenUpdate(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresIn.map { started.addingTimeInterval($0) },
            createTime: started)

        let original = try Data(contentsOf: authURL)
        let merged = try AuthFileStore.merge(original: original, entryID: c.entryID, update: update)
        try AuthFileStore.write(merged, to: authURL)

        let fresh = try AuthStore.readBest(from: authURL, now: clock(), preferring: c.entryID)
        guard fresh.token == tokens.accessToken else { throw AuthFileError.unparseable }
        let rotated = tokens.refreshToken != nil && tokens.refreshToken != c.refreshToken
        return Result(credential: fresh, refreshed: true, adopted: false, refreshTokenRotated: rotated)
    }
}
