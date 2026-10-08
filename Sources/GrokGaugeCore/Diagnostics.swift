import Foundation

/// Status of one usage source, as shown on the Diagnostics tab.
/// Holds only times and short status words: never tokens, emails, account ids, or file paths.
public struct SourceDiagnostics: Equatable, Sendable {
    public var name: String
    public var status: String
    public var lastSuccess: Date?
    public var lastError: String?
    public var lastErrorAt: Date?
    /// When the login used by this source expires (time only, never the token).
    public var tokenExpiresAt: Date?

    public init(name: String, status: String, lastSuccess: Date? = nil, lastError: String? = nil,
                lastErrorAt: Date? = nil, tokenExpiresAt: Date? = nil) {
        self.name = name
        self.status = status
        self.lastSuccess = lastSuccess
        self.lastError = lastError
        self.lastErrorAt = lastErrorAt
        self.tokenExpiresAt = tokenExpiresAt
    }
}

public struct DiagnosticsReport: Equatable, Sendable {
    public var appVersion: String
    public var macOSVersion: String
    public var architecture: String
    public var sources: [SourceDiagnostics]
    public var settingsSummary: [String]
    public var generatedAt: Date

    public init(appVersion: String, macOSVersion: String, architecture: String, sources: [SourceDiagnostics],
                settingsSummary: [String] = [], generatedAt: Date = Date()) {
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
        self.architecture = architecture
        self.sources = sources
        self.settingsSummary = settingsSummary
        self.generatedAt = generatedAt
    }

    /// Plain text for "Copy report" / bug reports. Times are UTC ISO-8601 so they read the same anywhere.
    public var text: String {
        var lines = [
            "GrokGauge diagnostics",
            "App: \(appVersion)",
            "macOS: \(macOSVersion) (\(architecture))",
            "Generated: \(Self.stamp(generatedAt))",
        ]
        for s in sources {
            lines.append("")
            lines.append("[\(s.name)]")
            lines.append("Status: \(Self.scrub(s.status))")
            lines.append("Last success: \(s.lastSuccess.map(Self.stamp) ?? "never")")
            if let e = s.lastError {
                lines.append("Last error: \(Self.scrub(e))\(s.lastErrorAt.map { " at \(Self.stamp($0))" } ?? "")")
            } else {
                lines.append("Last error: none")
            }
            if let t = s.tokenExpiresAt { lines.append("Login expires: \(Self.stamp(t))") }
        }
        if !settingsSummary.isEmpty {
            lines.append("")
            lines.append("[Settings]")
            lines += settingsSummary.map(Self.scrub)
        }
        return lines.joined(separator: "\n")
    }

    public static func stamp(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    /// Belt and braces: masks anything that looks like an email, a JWT/long token, a user id, or a home path,
    /// in case one ever sneaks into an error string.
    public static func scrub(_ s: String) -> String {
        var out = s
        let patterns = [
            #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,          // emails
            #"eyJ[A-Za-z0-9_-]{8,}(\.[A-Za-z0-9_-]+)*"#,                   // JWTs
            #"(user|grok|acct|account)[_|:-][A-Za-z0-9_-]{6,}"#,            // account / user ids
            #"[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}"#, // UUIDs
            #"/Users/[^/\s]+"#,                                             // home paths (user name)
            #"[A-Za-z0-9_-]{32,}"#,                                         // any other long opaque string
        ]
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: "‹redacted›", options: .regularExpression)
        }
        return out
    }
}
