import Foundation
import GrokGaugeCore

/// `GrokGauge --print-usage`: one fetch, human-readable output. The token is never printed.
enum DebugCLI {
    static func printUsage(json: Bool) async -> Int32 {
        let botResult = Result { try GrokBotUsageReader.read() }
        let grokCode = await printGrok(json: json, bot: botResult)
        if !json { printBot(botResult) }
        return grokCode
    }

    private static func printGrok(json: Bool, bot: Result<GrokBotSnapshot, Error>) async -> Int32 {
        let client = BillingClient(appVersion: AppInfo.version)
        do {
            let s = try await client.fetch()
            if json { printJSON(s, bot: bot) } else { printText(s) }
            return 0
        } catch let e as FetchError {
            let message: String
            switch e {
            case .auth(.notSignedIn): message = "Not signed in: no usable token in \(AuthStore.authFileURL.path). Run `grok login`."
            case .auth(.unreadable): message = "Could not read \(AuthStore.authFileURL.path). Run `grok login`."
            case .auth(.expired(let d)): message = "Grok login expired at \(UsageFormat.resetDate(d)) and has no refresh token. Run `grok login` to reconnect."
            case .auth(.refreshRejected): message = "auth.x.ai refused to renew the Grok login (refresh token revoked or expired). Run `grok login` to reconnect."
            case .auth(.refreshUnavailable): message = "Couldn't renew the Grok login right now (network or auth.x.ai unavailable)."
            case .unauthorized(let code): message = "HTTP \(code): the Grok login was rejected. Run `grok login` to reconnect."
            case .http(let code): message = "HTTP \(code) from the billing endpoint."
            case .network(let m): message = "Network error: \(m)"
            case .badResponse: message = "The billing endpoint returned something that isn't JSON."
            case .unexpectedShape: message = "xAI changed something: the billing reply is JSON but not in the expected shape (no config or period). Not showing a number rather than guessing."
            }
            FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
            return 1
        } catch {
            FileHandle.standardError.write(Data("error: request failed\n".utf8))
            return 1
        }
    }

    /// `GrokGauge --refresh-now`: renew the Grok login once, right now. Prints expiry times only.
    static func refreshNow() async -> Int32 {
        let url = AuthStore.authFileURL
        let before = try? AuthStore.readBest(from: url)
        do {
            let result = try await AuthSession(authURL: url).credential(force: true)
            let c = result.credential
            print("Auth file:        \(url.path)")
            print("Previous expiry:  \(before?.expiresAt.map { UsageFormat.resetDate($0) } ?? "unknown")")
            print("New expiry:       \(c.expiresAt.map { UsageFormat.resetDate($0) } ?? "unknown")")
            print("Renewed:          \(result.refreshed ? "yes" : "no")\(result.adopted ? " (adopted a token the CLI already renewed)" : "")")
            print("Refresh token rotated: \(result.refreshTokenRotated ? "yes" : "no")")
            return result.refreshed || result.adopted ? 0 : 1
        } catch let e as AuthError {
            let why: String
            switch e {
            case .notSignedIn: why = "not signed in. Run `grok login`."
            case .unreadable: why = "couldn't read \(url.path)."
            case .expired: why = "the login has no refresh token. Run `grok login`."
            case .refreshRejected: why = "auth.x.ai rejected the refresh token. Run `grok login`."
            case .refreshUnavailable: why = "couldn't reach auth.x.ai (or the auth file lock was busy)."
            }
            FileHandle.standardError.write(Data("error: renewal failed: \(why)\n".utf8))
            return 1
        } catch {
            FileHandle.standardError.write(Data("error: renewal failed while writing \(url.path)\n".utf8))
            return 1
        }
    }

    private static func printText(_ s: UsageSnapshot) {
        var lines: [String] = []
        lines.append("GrokGauge \(AppInfo.version)")
        lines.append("Usage:        \(s.roundedPercent)% (\(String(format: "%.2f", s.percent))%)\(s.percentInferred ? " [creditUsagePercent omitted -> 0]" : "")  level=\(s.level.rawValue)")
        lines.append("Period:       \(s.period.label)")
        if let start = s.periodStart { lines.append("Period start: \(UsageFormat.resetDate(start)) | \(iso(start))") }
        if let end = s.periodEnd {
            lines.append("Resets:       \(UsageFormat.resetDate(end)) | \(iso(end))")
            let left = s.timeUntilReset() ?? 0
            lines.append("Time left:    \(UsageFormat.countdown(left)) (\(UsageFormat.wholeDays(left)) whole days)")
        }
        lines.append("Products:")
        for p in s.products {
            lines.append("  - \(p.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(String(format: "%.1f", p.percent))%  [\(p.key)]")
        }
        lines.append("Extra Usage Credits (prepaid): \(UsageFormat.dollars(fromCents: s.prepaidBalanceCents))")
        lines.append("On-demand:    \(UsageFormat.dollars(fromCents: s.onDemandUsedCents)) used of \(UsageFormat.dollars(fromCents: s.onDemandCapCents)) cap")
        lines.append("Fetched:      \(UsageFormat.resetDate(s.fetchedAt))")
        print(lines.joined(separator: "\n"))
    }

    private static func printBot(_ result: Result<GrokBotSnapshot, Error>) {
        var lines = ["", "Grok Bot (read from \(GrokBotUsageReader.persistenceDirectory().path), no network):"]
        switch result {
        case .success(let b):
            lines.append(contentsOf: botLines(b))
        case .failure(let e):
            switch e as? GrokBotUsageError {
            case .notInstalled?: lines.append("  Not installed (no \(GrokBotUsageReader.dataDirectory.path)).")
            case .noReading?: lines.append("  No cached reading for the signed-in account. Open Grok Bot to reconnect.")
            case .unavailable?: lines.append("  Grok Bot reports no personal weekly limit.")
            case .stale(let b)?:
                lines.append("  STALE (cache expired or the week already reset). Open Grok Bot to update. Last reading:")
                lines.append(contentsOf: botLines(b))
            case .unrecognized?, nil: lines.append("  Couldn't understand Grok Bot's usage cache (format changed?).")
            }
        }
        print(lines.joined(separator: "\n"))
    }

    private static func botLines(_ b: GrokBotSnapshot) -> [String] {
        var lines = ["  Usage:      \(b.roundedPercent)% (\(String(format: "%.2f", b.percent))%)  level=\(b.level.rawValue)"]
        if let end = b.nextReset {
            lines.append("  Resets:     \(UsageFormat.resetDate(end)) | \(iso(end))")
            let left = b.timeUntilReset() ?? 0
            lines.append("  Time left:  \(UsageFormat.countdown(left)) (\(UsageFormat.wholeDays(left)) whole days)")
        }
        if let plan = b.planLabel { lines.append("  Plan:       \(plan)") }
        if let used = b.onDemandUsedCents, let limit = b.onDemandLimitCents {
            lines.append("  On-demand:  \(UsageFormat.dollars(fromCents: used)) of \(UsageFormat.dollars(fromCents: limit))")
        }
        lines.append("  Read by Grok Bot: \(UsageFormat.resetDate(b.readAt))")
        if let exp = b.expiresAt { lines.append("  Cache expires:    \(UsageFormat.resetDate(exp))") }
        return lines
    }

    private static func printJSON(_ s: UsageSnapshot, bot: Result<GrokBotSnapshot, Error>) {
        var obj: [String: Any] = [
            "percent": s.percent,
            "roundedPercent": s.roundedPercent,
            "percentInferred": s.percentInferred,
            "level": s.level.rawValue,
            "period": s.period.rawValue,
            "products": s.products.map { ["product": $0.key, "name": $0.name, "percent": $0.percent] },
            "prepaidBalanceCents": s.prepaidBalanceCents,
            "onDemandUsedCents": s.onDemandUsedCents,
            "onDemandCapCents": s.onDemandCapCents,
            "fetchedAt": iso(s.fetchedAt),
        ]
        if let start = s.periodStart { obj["periodStart"] = iso(start) }
        if let end = s.periodEnd { obj["periodEnd"] = iso(end) }
        switch bot {
        case .success(let b):
            obj["grokBot"] = botJSON(b, status: "ok")
        case .failure(let e):
            if case .stale(let b)? = e as? GrokBotUsageError {
                obj["grokBot"] = botJSON(b, status: "stale")
            } else {
                obj["grokBot"] = ["status": String(describing: e)]
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    private static func botJSON(_ b: GrokBotSnapshot, status: String) -> [String: Any] {
        var o: [String: Any] = ["status": status, "percent": b.percent, "roundedPercent": b.roundedPercent,
                                "level": b.level.rawValue, "readAt": iso(b.readAt)]
        if let end = b.nextReset { o["nextReset"] = iso(end) }
        if let exp = b.expiresAt { o["expiresAt"] = iso(exp) }
        if let plan = b.planLabel { o["planLabel"] = plan }
        return o
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }
}
