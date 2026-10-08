import Foundation
import Testing
@testable import GrokGaugeCore

// MARK: - Fixtures

/// Mirrors the real file's layout (serde_json pretty print, no trailing newline).
let sampleAuthJSON = """
{
  "https://auth.x.ai::client-1": {
    "key": "access-OLD",
    "auth_mode": "oidc",
    "create_time": "2026-10-07T01:37:02.380497Z",
    "user_id": "u-1",
    "email": "me@example.com",
    "principal_type": "User",
    "principal_id": "u-1",
    "team_id": "t-1",
    "coding_data_retention_opt_out": false,
    "team_blocked_reasons": [],
    "nested": {
      "a": 1.50,
      "b": [
        true,
        null
      ]
    },
    "refresh_token": "refresh-OLD",
    "expires_at": "2026-10-07T07:37:02.380497Z",
    "oidc_issuer": "https://auth.x.ai",
    "oidc_client_id": "client-1"
  },
  "https://other.example::x": {
    "key": "unrelated",
    "note": "keep \\"me\\" / untouched é"
  }
}
"""

func makeCredential(token: String = "access-OLD", refresh: String? = "refresh-OLD",
                    expires: Date?, issuer: String? = "https://auth.x.ai", client: String? = "client-1") -> GrokCredential {
    GrokCredential(entryID: "https://auth.x.ai::client-1", token: token, refreshToken: refresh, expiresAt: expires,
                   email: nil, issuer: issuer, clientID: client, principalType: "User", principalID: "u-1")
}

final class TempAuthDir {
    let dir: URL
    var authURL: URL { dir.appendingPathComponent("auth.json") }

    init(contents: String = sampleAuthJSON) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("grokgauge-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: authURL)
        chmod(authURL.path, 0o600)
    }

    func read() throws -> String { try String(contentsOf: authURL, encoding: .utf8) }
    func json() throws -> [String: [String: Any]] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: authURL)) as! [String: [String: Any]]
    }
    deinit { try? FileManager.default.removeItem(at: dir) }
}

/// Scriptable stand-in for auth.x.ai.
final class MockRefresher: TokenRefreshing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String?] = []
    var calls: [String?] { lock.withLock { _calls } }
    let handler: @Sendable (_ refreshToken: String?, _ callIndex: Int) throws -> RefreshedTokens

    init(_ handler: @escaping @Sendable (String?, Int) throws -> RefreshedTokens) { self.handler = handler }

    func refresh(_ credential: GrokCredential) async throws -> RefreshedTokens {
        let index = lock.withLock { () -> Int in _calls.append(credential.refreshToken); return _calls.count - 1 }
        return try handler(credential.refreshToken, index)
    }
}

let fixedNow = ISODate.parse("2026-10-07T07:00:00Z")!   // 37 min before access-OLD expires

// MARK: - Decision logic

@Suite struct RefreshPolicyTests {
    let now = fixedNow

    @Test func freshTokenIsUsedAsIs() {
        let c = makeCredential(expires: now.addingTimeInterval(3 * 3600))
        #expect(RefreshPolicy.decide(c, now: now) == .useCurrent)
    }

    @Test func refreshesWithinOneHourOfExpiry() {
        #expect(RefreshPolicy.decide(makeCredential(expires: now.addingTimeInterval(59 * 60)), now: now) == .refresh)
        #expect(RefreshPolicy.decide(makeCredential(expires: now.addingTimeInterval(61 * 60)), now: now) == .useCurrent)
    }

    @Test func refreshesExpiredToken() {
        #expect(RefreshPolicy.decide(makeCredential(expires: now.addingTimeInterval(-60)), now: now) == .refresh)
    }

    @Test func refreshesAfter401EvenIfFresh() {
        let c = makeCredential(expires: now.addingTimeInterval(5 * 3600))
        #expect(RefreshPolicy.decide(c, now: now, rejected: true) == .refresh)
        #expect(RefreshPolicy.decide(c, now: now, force: true) == .refresh)
    }

    @Test func withoutRefreshTokenFallsBackToLogin() {
        let soon = makeCredential(refresh: nil, expires: now.addingTimeInterval(20 * 60))
        #expect(RefreshPolicy.decide(soon, now: now) == .useCurrent)          // still valid: keep using it
        let gone = makeCredential(refresh: nil, expires: now.addingTimeInterval(-1))
        #expect(RefreshPolicy.decide(gone, now: now) == .reconnect)
        #expect(RefreshPolicy.decide(soon, now: now, rejected: true) == .reconnect)
        #expect(RefreshPolicy.decide(makeCredential(expires: nil, client: nil), now: now, rejected: true) == .reconnect)
    }

    @Test func noExpiryMeansUseCurrent() {
        #expect(RefreshPolicy.decide(makeCredential(expires: nil), now: now) == .useCurrent)
    }

    @Test func adoptsTokenTheCLIRenewed() {
        let tried = makeCredential(expires: now.addingTimeInterval(10 * 60))
        let renewed = makeCredential(token: "access-CLI", refresh: "refresh-CLI", expires: now.addingTimeInterval(6 * 3600))
        #expect(RefreshPolicy.shouldAdopt(disk: renewed, tried: tried, rejectedToken: nil, now: now))
        // Same token on disk: must refresh ourselves.
        #expect(!RefreshPolicy.shouldAdopt(disk: tried, tried: tried, rejectedToken: nil, now: now))
        // Disk token also near expiry: refresh with the disk's (newer) refresh token instead.
        let nearlyDone = makeCredential(token: "access-CLI", expires: now.addingTimeInterval(20 * 60))
        #expect(!RefreshPolicy.shouldAdopt(disk: nearlyDone, tried: tried, rejectedToken: nil, now: now))
        // Never adopt the token the server just refused, and never when forced.
        #expect(!RefreshPolicy.shouldAdopt(disk: renewed, tried: tried, rejectedToken: "access-CLI", now: now))
        #expect(!RefreshPolicy.shouldAdopt(disk: renewed, tried: tried, rejectedToken: nil, now: now, force: true))
    }

    @Test func expiredSuperGrokLoginBeatsUnrelatedEntry() throws {
        let later = fixedNow.addingTimeInterval(3600)   // access-OLD has expired, but it can be renewed
        let c = try AuthStore.select(fromJSON: Data(sampleAuthJSON.utf8), now: later)
        #expect(c.entryID == "https://auth.x.ai::client-1")
    }

    @Test func onlyAuthXaiIsAllowed() {
        #expect(OIDCTokenRefresher.isAllowed(URL(string: "https://auth.x.ai/oauth2/token")))
        #expect(!OIDCTokenRefresher.isAllowed(URL(string: "http://auth.x.ai/oauth2/token")))
        #expect(!OIDCTokenRefresher.isAllowed(URL(string: "https://auth.x.ai.evil.com/token")))
        #expect(!OIDCTokenRefresher.isAllowed(URL(string: "https://evil.com/auth.x.ai")))
        #expect(!OIDCTokenRefresher.isAllowed(URL(string: "https://user@auth.x.ai/token")))
    }

    @Test func formEncodingEscapesReservedCharacters() {
        #expect(OIDCTokenRefresher.formEncode([("a", "x+y/z=&"), ("b", "c d")]) == "a=x%2By%2Fz%3D%26&b=c%20d")
    }
}

// MARK: - auth.json merge + write

@Suite struct AuthFileMergeTests {
    @Test func untouchedRoundTripIsByteIdentical() throws {
        let node = try JSONNode.parse(Data(sampleAuthJSON.utf8))
        #expect(node.serialized() == sampleAuthJSON)
    }

    @Test func mergeUpdatesOnlyTokenFields() throws {
        let created = ISODate.parse("2026-10-07T07:00:00.123456Z")!
        let update = TokenUpdate(accessToken: "access-NEW", refreshToken: "refresh-NEW",
                                 expiresAt: created.addingTimeInterval(21_600), createTime: created)
        let out = try AuthFileStore.merge(original: Data(sampleAuthJSON.utf8), entryID: "https://auth.x.ai::client-1", update: update)
        let text = String(decoding: out, as: UTF8.self)

        let expected = sampleAuthJSON
            .replacingOccurrences(of: "\"access-OLD\"", with: "\"access-NEW\"")
            .replacingOccurrences(of: "\"refresh-OLD\"", with: "\"refresh-NEW\"")
            .replacingOccurrences(of: "\"create_time\": \"2026-10-07T01:37:02.380497Z\"", with: "\"create_time\": \"\(AuthFileStore.timestamp(created))\"")
            .replacingOccurrences(of: "\"expires_at\": \"2026-10-07T07:37:02.380497Z\"", with: "\"expires_at\": \"\(AuthFileStore.timestamp(created.addingTimeInterval(21_600)))\"")
        #expect(text == expected)
        #expect(AuthFileStore.timestamp(created).hasPrefix("2026-10-07T07:00:00.123"))
        #expect(AuthFileStore.timestamp(created).hasSuffix("Z"))
        #expect(ISODate.parse(AuthFileStore.timestamp(created)) != nil)
    }

    @Test func keepsRefreshTokenWhenNotRotated() throws {
        let update = TokenUpdate(accessToken: "access-NEW", refreshToken: nil, expiresAt: nil, createTime: fixedNow)
        let out = try AuthFileStore.merge(original: Data(sampleAuthJSON.utf8), entryID: "https://auth.x.ai::client-1", update: update)
        let obj = try JSONSerialization.jsonObject(with: out) as! [String: [String: Any]]
        #expect(obj["https://auth.x.ai::client-1"]?["refresh_token"] as? String == "refresh-OLD")
        #expect(obj["https://auth.x.ai::client-1"]?["key"] as? String == "access-NEW")
        #expect(obj["https://auth.x.ai::client-1"]?["expires_at"] as? String == "2026-10-07T07:37:02.380497Z")
        #expect(obj["https://other.example::x"]?["note"] as? String == "keep \"me\" / untouched é")
        #expect(obj["https://auth.x.ai::client-1"]?["coding_data_retention_opt_out"] as? Bool == false)
    }

    @Test func preservesTrailingNewline() throws {
        let update = TokenUpdate(accessToken: "n", refreshToken: nil, expiresAt: nil, createTime: fixedNow)
        let out = try AuthFileStore.merge(original: Data((sampleAuthJSON + "\n").utf8), entryID: "https://auth.x.ai::client-1", update: update)
        #expect(out.last == 0x0A)
    }

    @Test func missingEntryOrGarbageThrows() {
        let update = TokenUpdate(accessToken: "n", refreshToken: nil, expiresAt: nil, createTime: fixedNow)
        #expect(throws: AuthFileError.entryMissing) {
            try AuthFileStore.merge(original: Data(sampleAuthJSON.utf8), entryID: "nope", update: update)
        }
        #expect(throws: AuthFileError.unparseable) {
            try AuthFileStore.merge(original: Data("{not json".utf8), entryID: "x", update: update)
        }
    }

    @Test func atomicWriteKeeps0600AndFollowsSymlinks() throws {
        let tmp = try TempAuthDir()
        let link = tmp.dir.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tmp.authURL)
        try AuthFileStore.write(Data("{\"a\": 1}".utf8), to: link)

        #expect(try tmp.read() == "{\"a\": 1}")
        let attrs = try FileManager.default.attributesOfItem(atPath: tmp.authURL.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType) == .typeSymbolicLink)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tmp.dir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func lockIsExclusiveAndTimesOut() async throws {
        let tmp = try TempAuthDir()
        let held = try await AuthFileLock.acquire(for: tmp.authURL, timeout: 1)
        await #expect(throws: AuthFileError.lockTimeout) {
            _ = try await AuthFileLock.acquire(for: tmp.authURL, timeout: 0.3)
        }
        let stamp = try String(contentsOf: AuthFileLock.lockURL(for: tmp.authURL), encoding: .utf8)
        #expect(stamp.hasPrefix("\(getpid()):"))
        held.release()
        let again = try await AuthFileLock.acquire(for: tmp.authURL, timeout: 1)
        again.release()
        #expect(FileManager.default.fileExists(atPath: AuthFileLock.lockURL(for: tmp.authURL).path))  // never deleted
    }
}

// MARK: - End-to-end renewal against temp files

@Suite struct AuthSessionTests {
    func session(_ tmp: TempAuthDir, _ mock: MockRefresher, now: Date = fixedNow) -> AuthSession {
        AuthSession(authURL: tmp.authURL, refresher: mock, lockTimeout: 1, clock: { now })
    }

    @Test func proactiveRefreshWritesBackAndRotates() async throws {
        let tmp = try TempAuthDir()
        let mock = MockRefresher { _, _ in RefreshedTokens(accessToken: "access-NEW", refreshToken: "refresh-NEW", expiresIn: 21_600) }
        let result = try await session(tmp, mock).credential()

        #expect(result.refreshed && result.refreshTokenRotated)
        #expect(result.credential.token == "access-NEW")
        #expect(mock.calls == ["refresh-OLD"])
        let entry = try tmp.json()["https://auth.x.ai::client-1"]!
        #expect(entry["key"] as? String == "access-NEW")
        #expect(entry["refresh_token"] as? String == "refresh-NEW")
        #expect(ISODate.parse(entry["expires_at"] as! String) == ISODate.parse(AuthFileStore.timestamp(fixedNow.addingTimeInterval(21_600))))
        #expect(entry["email"] as? String == "me@example.com")
        #expect(try tmp.json()["https://other.example::x"]?["key"] as? String == "unrelated")
        let perms = try FileManager.default.attributesOfItem(atPath: tmp.authURL.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600)
    }

    @Test func freshTokenNeverCallsAuthServer() async throws {
        let tmp = try TempAuthDir()
        let mock = MockRefresher { _, _ in Issue.record("should not refresh"); throw RefreshError.transient("x") }
        let early = fixedNow.addingTimeInterval(-3 * 3600)   // 3h37m before expiry
        let before = try tmp.read()
        let result = try await session(tmp, mock, now: early).credential()
        #expect(!result.refreshed)
        #expect(result.credential.token == "access-OLD")
        #expect(try tmp.read() == before)
    }

    @Test func rejectedTokenTriggersRefreshEvenWhenFresh() async throws {
        let tmp = try TempAuthDir()
        let mock = MockRefresher { _, _ in RefreshedTokens(accessToken: "access-NEW", refreshToken: nil, expiresIn: 3600) }
        let early = fixedNow.addingTimeInterval(-3 * 3600)
        let s = session(tmp, mock, now: early)
        let first = try await s.credential().credential
        let renewed = try await s.credential(rejecting: first)
        #expect(renewed.refreshed)
        #expect(renewed.credential.token == "access-NEW")
        #expect(try tmp.json()["https://auth.x.ai::client-1"]?["refresh_token"] as? String == "refresh-OLD")  // not rotated
    }

    @Test func adoptsTokenAlreadyRenewedByCLI() async throws {
        let tmp = try TempAuthDir()
        let mock = MockRefresher { _, _ in Issue.record("should adopt instead"); throw RefreshError.transient("x") }
        let s = session(tmp, mock)
        let old = try AuthStore.readBest(from: tmp.authURL, now: fixedNow)
        // The CLI renews in the meantime.
        let cliUpdate = TokenUpdate(accessToken: "access-CLI", refreshToken: "refresh-CLI",
                                    expiresAt: fixedNow.addingTimeInterval(6 * 3600), createTime: fixedNow)
        try AuthFileStore.write(AuthFileStore.merge(original: Data(contentsOf: tmp.authURL),
                                                     entryID: old.entryID, update: cliUpdate), to: tmp.authURL)
        let result = try await s.credential(rejecting: old)
        #expect(result.adopted)
        #expect(result.credential.token == "access-CLI")
        #expect(mock.calls.isEmpty)
    }

    @Test func revokedRefreshTokenMeansLoginNeeded() async throws {
        let tmp = try TempAuthDir()
        let before = try tmp.read()
        let mock = MockRefresher { _, _ in throw RefreshError.rejected("invalid_grant") }
        await #expect(throws: AuthError.refreshRejected) { _ = try await session(tmp, mock).credential() }
        #expect(try tmp.read() == before)   // file untouched
    }

    @Test func retriesOnceWhenSiblingRotatedRefreshToken() async throws {
        let tmp = try TempAuthDir()
        let url = tmp.authURL
        let mock = MockRefresher { rt, index in
            if index == 0 {
                // Simulate another process rotating the refresh token (access token still near expiry).
                let update = TokenUpdate(accessToken: "access-OLD", refreshToken: "refresh-SIBLING", expiresAt: nil, createTime: fixedNow)
                let data = try AuthFileStore.merge(original: Data(contentsOf: url), entryID: "https://auth.x.ai::client-1", update: update)
                try AuthFileStore.writeAtomically(data, to: url)
                throw RefreshError.rejected("invalid_grant")
            }
            #expect(rt == "refresh-SIBLING")
            return RefreshedTokens(accessToken: "access-NEW", refreshToken: "refresh-NEWEST", expiresIn: 21_600)
        }
        let result = try await session(tmp, mock).credential()
        #expect(mock.calls == ["refresh-OLD", "refresh-SIBLING"])
        #expect(result.credential.token == "access-NEW")
        #expect(try tmp.json()["https://auth.x.ai::client-1"]?["refresh_token"] as? String == "refresh-NEWEST")
    }

    @Test func transientFailureKeepsUsingValidToken() async throws {
        let tmp = try TempAuthDir()
        let mock = MockRefresher { _, _ in throw RefreshError.transient("offline") }
        let result = try await session(tmp, mock).credential()   // 37 min left: still usable
        #expect(!result.refreshed)
        #expect(result.credential.token == "access-OLD")
        let late = fixedNow.addingTimeInterval(3600)              // expired
        await #expect(throws: AuthError.refreshUnavailable) { _ = try await session(tmp, mock, now: late).credential() }
    }

    @Test func noRefreshTokenExpiredMeansReconnect() async throws {
        let json = #"{"https://auth.x.ai::c":{"key":"k","expires_at":"2026-10-07T06:00:00Z"}}"#
        let tmp = try TempAuthDir(contents: json)
        let mock = MockRefresher { _, _ in throw RefreshError.transient("x") }
        await #expect(throws: AuthError.expired(ISODate.parse("2026-10-07T06:00:00Z")!)) {
            _ = try await session(tmp, mock).credential()
        }
    }
}
