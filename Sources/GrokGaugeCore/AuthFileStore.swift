import Darwin
import Foundation

/// New token material to merge into one auth.json entry.
public struct TokenUpdate: Sendable {
    public var accessToken: String
    /// `nil` when the IdP didn't rotate the refresh token (keep the existing one).
    public var refreshToken: String?
    public var expiresAt: Date?
    public var createTime: Date

    public init(accessToken: String, refreshToken: String?, expiresAt: Date?, createTime: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.createTime = createTime
    }
}

extension TokenUpdate: CustomStringConvertible {
    public var description: String { "TokenUpdate(expiresAt: \(String(describing: expiresAt)), tokens: <redacted>)" }
}

public enum AuthFileError: Error, Equatable {
    case unparseable
    case entryMissing
    case writeFailed(Int32)
    case lockTimeout
    case lockFailed(Int32)
}

/// Reading-for-write, merging, locking, and atomic replacement of `~/.grok/auth.json`.
public enum AuthFileStore {
    /// Merge new tokens into `original`, preserving every other entry and field, key order, and layout.
    /// Mirrors what the Grok CLI stores after a refresh: `key`, `refresh_token` (if rotated),
    /// `expires_at`, and a fresh `create_time`.
    public static func merge(original: Data, entryID: String, update: TokenUpdate) throws -> Data {
        guard var root = try? JSONNode.parse(original), case .object = root else { throw AuthFileError.unparseable }
        guard var entry = root[entryID], case .object = entry else { throw AuthFileError.entryMissing }

        entry.set("key", .string(update.accessToken))
        if let rt = update.refreshToken, !rt.isEmpty {
            entry.set("refresh_token", .string(rt))
        }
        if let exp = update.expiresAt {
            entry.set("expires_at", .string(timestamp(exp)))
        }
        entry.set("create_time", .string(timestamp(update.createTime)))
        root.set(entryID, entry)

        var text = root.serialized()
        if original.last == 0x0A { text += "\n" }
        let data = Data(text.utf8)
        // Sanity check before anything touches disk.
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw AuthFileError.unparseable }
        return data
    }

    /// RFC 3339 UTC with microseconds, the same shape chrono writes ("2026-10-08T07:37:02.380497Z").
    public static func timestamp(_ date: Date) -> String {
        let totalMicros = (date.timeIntervalSince1970 * 1_000_000).rounded()
        let seconds = floor(totalMicros / 1_000_000)
        let micros = Int(totalMicros - seconds * 1_000_000)
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withInternetDateTime]
        let base = f.string(from: Date(timeIntervalSince1970: seconds))   // ...:02Z
        return String(base.dropLast()) + String(format: ".%06dZ", micros)
    }

    /// Atomic replace, falling back to an in-place rewrite (like the Grok CLI) if the atomic path fails,
    /// because losing a freshly rotated refresh token would sign the CLI out too.
    public static func write(_ data: Data, to url: URL) throws {
        do {
            try writeAtomically(data, to: url)
        } catch {
            try writeInPlace(data, to: url)
        }
    }

    static func writeInPlace(_ data: Data, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        let fd = open(target.path, O_WRONLY | O_TRUNC | O_CLOEXEC)
        guard fd >= 0 else { throw AuthFileError.writeFailed(errno) }
        defer { close(fd) }
        let written = data.withUnsafeBytes { buf -> Int in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return -1 }
                off += n
            }
            return off
        }
        fchmod(fd, 0o600)
        guard written == data.count, fsync(fd) == 0 else { throw AuthFileError.writeFailed(errno) }
    }

    /// Atomically replace the file at `url` (following a symlink to its target): write a 0600 temp
    /// file in the same directory, fsync, then rename over the original.
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        let dir = target.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(target.lastPathComponent).grokgauge-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).tmp")

        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AuthFileError.writeFailed(errno) }
        var ok = false
        defer {
            if !ok { unlink(tmp.path) }
        }
        let written = data.withUnsafeBytes { buf -> Int in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return -1 }
                off += n
            }
            return off
        }
        fchmod(fd, 0o600)
        let synced = fsync(fd) == 0
        close(fd)
        guard written == data.count, synced else { throw AuthFileError.writeFailed(errno) }
        guard rename(tmp.path, target.path) == 0 else { throw AuthFileError.writeFailed(errno) }
        ok = true
        chmod(target.path, 0o600)
    }
}

/// Advisory lock shared with the Grok CLI: `flock(LOCK_EX)` on `auth.json.lock` next to auth.json.
/// Like the CLI, the lock file is never deleted, and the holder stamp is `PID:UNIX_TS`.
final class AuthFileLock {
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    static func lockURL(for authURL: URL) -> URL {
        authURL.deletingLastPathComponent().appendingPathComponent("auth.json.lock")
    }

    static func acquire(for authURL: URL, timeout: TimeInterval) async throws -> AuthFileLock {
        let path = lockURL(for: authURL).path
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw AuthFileError.lockFailed(errno) }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                // Make sure nobody replaced the lock file between open and flock.
                var held = Darwin.stat()
                let onDisk = try? FileManager.default.attributesOfItem(atPath: path)
                if fstat(fd, &held) == 0,
                   (onDisk?[.systemFileNumber] as? NSNumber)?.uint64Value == UInt64(held.st_ino),
                   (onDisk?[.systemNumber] as? NSNumber)?.int64Value == Int64(held.st_dev) {
                    let lock = AuthFileLock(fd: fd)
                    lock.stampHolder()
                    return lock
                }
                flock(fd, LOCK_UN)
                close(fd)
                continue
            }
            let err = errno
            close(fd)
            guard err == EWOULDBLOCK || err == EINTR else { throw AuthFileError.lockFailed(err) }
            if Date() >= deadline { throw AuthFileError.lockTimeout }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func stampHolder() {
        let stamp = "\(getpid()):\(Int(Date().timeIntervalSince1970))"
        ftruncate(fd, 0)
        _ = stamp.withCString { pwrite(fd, $0, strlen($0), 0) }
        fsync(fd)
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}
