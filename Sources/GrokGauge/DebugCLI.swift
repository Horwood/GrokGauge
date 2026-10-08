import Foundation
import GrokGaugeCore

/// `GrokGauge --print-usage`: one fetch, human-readable output. The token is never printed.
enum DebugCLI {
    static func printUsage(json: Bool) async -> Int32 {
        let client = BillingClient(appVersion: AppInfo.version)
        do {
            let s = try await client.fetch()
            if json { printJSON(s) } else { printText(s) }
            return 0
        } catch let e as FetchError {
            let message: String
            switch e {
            case .auth(.notSignedIn): message = "Not signed in: no usable token in \(AuthStore.authFileURL.path). Run `grok login`."
            case .auth(.unreadable): message = "Could not read \(AuthStore.authFileURL.path). Run `grok login`."
            case .auth(.expired(let d)): message = "Grok login expired at \(UsageFormat.resetDate(d)). Run `grok login` to reconnect."
            case .unauthorized(let code): message = "HTTP \(code): the Grok login was rejected. Run `grok login` to reconnect."
            case .http(let code): message = "HTTP \(code) from the billing endpoint."
            case .network(let m): message = "Network error: \(m)"
            case .badResponse: message = "Unexpected response format (the unofficial endpoint may have changed)."
            }
            FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
            return 1
        } catch {
            FileHandle.standardError.write(Data("error: request failed\n".utf8))
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

    private static func printJSON(_ s: UsageSnapshot) {
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
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }
}
