import Foundation

public enum UsageParserError: Error, Equatable {
    /// The body isn't JSON at all (an HTML error page, a proxy, a truncated body).
    case notJSON
    /// JSON, but without the `config` object the gauge is built from.
    case missingConfig
    /// `config` is there but has no usable period end (`currentPeriod.end` / `billingPeriodEnd`).
    case missingPeriod
    /// Known fields came back with types GrokGauge doesn't understand.
    case unexpectedTypes

    /// True when the reply is JSON but its shape changed, i.e. xAI changed something.
    /// Showing 0% in that case would be misleading, so callers show a distinct state instead.
    public var isShapeChange: Bool { self != .notJSON }
}

public enum UsageParser {
    /// The five products of the shared SuperGrok pool, in display order.
    /// They are always listed (0% when the payload omits them) so the breakdown reads consistently.
    static let canonical: [(name: String, symbol: String, aliases: [String])] = [
        ("Chat", "bubble.left.and.bubble.right.fill", ["grokchat", "chat"]),
        ("Imagine", "photo.on.rectangle.angled", ["grokimagine", "imagine"]),
        ("Voice", "waveform", ["grokvoice", "voice"]),
        ("Build", "hammer.fill", ["grokbuild", "build"]),
        ("API", "curlybraces", ["api", "grokapi"]),
    ]

    public static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw UsageParserError.notJSON
        }
        let envelope: BillingEnvelope
        do {
            envelope = try JSONDecoder().decode(BillingEnvelope.self, from: data)
        } catch {
            throw UsageParserError.unexpectedTypes
        }
        guard let cfg = envelope.config else { throw UsageParserError.missingConfig }
        try validateShape(cfg)
        return snapshot(from: cfg, now: now)
    }

    /// The "missing creditUsagePercent means 0%" rule is only safe when the rest of the
    /// reply looks like a normal billing config. Without a period end it doesn't.
    static func validateShape(_ cfg: BillingConfig) throws {
        let end = (cfg.currentPeriod?.end).flatMap(ISODate.parse) ?? cfg.billingPeriodEnd.flatMap(ISODate.parse)
        guard end != nil else { throw UsageParserError.missingPeriod }
    }

    public static func snapshot(from cfg: BillingConfig, now: Date = Date()) -> UsageSnapshot {
        let cap = cfg.onDemandCap?.cents ?? 0
        let used = cfg.onDemandUsed?.cents ?? 0

        var inferred = false
        let percent: Double
        if let p = cfg.creditUsagePercent?.value, p.isFinite {
            percent = p
        } else {
            // proto3 omits zero-valued scalars; grok.com's own web client reads a missing
            // credit_usage_percent as 0 for an active period.
            inferred = true
            percent = 0
        }

        let start = (cfg.currentPeriod?.start).flatMap(ISODate.parse)
            ?? cfg.billingPeriodStart.flatMap(ISODate.parse)
        let end = (cfg.currentPeriod?.end).flatMap(ISODate.parse)
            ?? cfg.billingPeriodEnd.flatMap(ISODate.parse)

        return UsageSnapshot(
            percent: percent,
            percentInferred: inferred,
            period: PeriodKind(wire: cfg.currentPeriod?.type),
            periodStart: start,
            periodEnd: end,
            products: products(from: cfg.productUsage ?? []),
            prepaidBalanceCents: cfg.prepaidBalance?.cents ?? 0,
            onDemandUsedCents: used,
            onDemandCapCents: cap,
            fetchedAt: now
        )
    }

    static func normalizedKey(_ raw: String) -> String {
        var s = raw.lowercased()
        for prefix in ["product_type_", "product_", "grok_product_"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
        }
        return s.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
    }

    static func products(from usage: [BillingConfig.ProductUsage]) -> [ProductShare] {
        var byCanonical: [String: (key: String, percent: Double)] = [:]
        var extras: [ProductShare] = []

        for entry in usage {
            guard let raw = entry.product, !raw.isEmpty else { continue }
            let pct = entry.usagePercent?.value ?? 0
            let key = normalizedKey(raw)
            if let match = canonical.first(where: { $0.aliases.contains(key) }) {
                let existing = byCanonical[match.name]?.percent ?? 0
                byCanonical[match.name] = (raw, existing + pct)
            } else {
                extras.append(ProductShare(key: raw, name: displayName(for: raw),
                                           symbol: "square.grid.2x2.fill", percent: pct))
            }
        }

        let fixed = canonical.map { c in
            ProductShare(key: byCanonical[c.name]?.key ?? c.name, name: c.name,
                         symbol: c.symbol, percent: byCanonical[c.name]?.percent ?? 0)
        }
        return fixed + extras.sorted { $0.percent > $1.percent }
    }

    /// "GrokAppBuilder" -> "App Builder", "PRODUCT_FOO_BAR" -> "Foo Bar"
    static func displayName(for raw: String) -> String {
        var s = raw
        if s.uppercased() == s {
            s = s.lowercased()
            for prefix in ["product_type_", "product_"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
            return s.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
        }
        if s.hasPrefix("Grok"), s.count > 4 { s.removeFirst(4) }
        var out = ""
        for ch in s {
            if ch.isUppercase, let last = out.last, last.isLowercase { out.append(" ") }
            out.append(ch)
        }
        return out
    }
}

/// ISO-8601 parsing that tolerates microsecond fractions ("…54.858014+00:00"),
/// which `ISO8601DateFormatter` does not accept on every macOS release.
public enum ISODate {
    public static func parse(_ string: String) -> Date? {
        var s = string.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
            let digits = s[r].dropFirst()
            let millis = String((digits + "000").prefix(3))
            s.replaceSubrange(r, with: "." + millis)
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}
