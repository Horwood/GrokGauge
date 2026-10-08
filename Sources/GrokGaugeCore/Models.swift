import Foundation

// MARK: - Wire format (GET /v1/billing?format=credits)

/// A number that may arrive as a JSON number or as a string (proto int64 / float fields).
public struct FlexibleNumber: Decodable, Equatable, Sendable {
    public let value: Double

    public init(_ value: Double) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let d = try? container.decode(Double.self) {
            value = d
        } else if let s = try? container.decode(String.self), let d = Double(s) {
            value = d
        } else if container.decodeNil() {
            value = 0
        } else {
            throw DecodingError.typeMismatch(
                Double.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected a number")
            )
        }
    }
}

/// xAI's `Cent` message: `{ "val": 1446 }` means $14.46. `{}` is a confirmed zero.
public struct CentAmount: Decodable, Equatable, Sendable {
    public let val: FlexibleNumber?
    public var cents: Double { val?.value ?? 0 }
}

public struct BillingEnvelope: Decodable, Sendable {
    public let config: BillingConfig?
}

public struct BillingConfig: Decodable, Sendable {
    public struct Period: Decodable, Sendable {
        public let type: String?
        public let start: String?
        public let end: String?
    }

    public struct ProductUsage: Decodable, Sendable {
        public let product: String?
        public let usagePercent: FlexibleNumber?
    }

    public let currentPeriod: Period?
    public let creditUsagePercent: FlexibleNumber?
    public let onDemandCap: CentAmount?
    public let onDemandUsed: CentAmount?
    public let prepaidBalance: CentAmount?
    public let productUsage: [ProductUsage]?
    public let isUnifiedBillingUser: Bool?
    public let billingPeriodStart: String?
    public let billingPeriodEnd: String?
}

// MARK: - App model

public enum UsageLevel: String, Sendable {
    case normal    // <= 80%   green
    case warning   // 81–90%   orange
    case critical  // > 90%    red

    /// Thresholds use the whole-number percent that is displayed to the user.
    public static func forPercent(_ roundedPercent: Int) -> UsageLevel {
        if roundedPercent > 90 { return .critical }
        if roundedPercent > 80 { return .warning }
        return .normal
    }
}

public enum PeriodKind: String, Sendable {
    case weekly, monthly, daily, unknown

    public init(wire: String?) {
        let t = (wire ?? "").uppercased()
        if t.contains("WEEK") { self = .weekly }
        else if t.contains("MONTH") { self = .monthly }
        else if t.contains("DAY") || t.contains("DAILY") { self = .daily }
        else { self = .unknown }
    }

    public var label: String {
        switch self {
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .daily: return "Daily"
        case .unknown: return "Current period"
        }
    }
}

public struct ProductShare: Identifiable, Hashable, Sendable {
    public let key: String        // raw wire name, e.g. "GrokChat"
    public let name: String       // display name, e.g. "Chat"
    public let symbol: String     // SF Symbol name
    public let percent: Double    // share of the same weekly pool (0–100)
    public var id: String { key }

    public init(key: String, name: String, symbol: String, percent: Double) {
        self.key = key
        self.name = name
        self.symbol = symbol
        self.percent = percent
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public var percent: Double
    /// True when the payload omitted `creditUsagePercent` (proto3 drops zeros), so 0% was inferred.
    public var percentInferred: Bool
    public var period: PeriodKind
    public var periodStart: Date?
    public var periodEnd: Date?
    public var products: [ProductShare]
    public var prepaidBalanceCents: Double
    public var onDemandUsedCents: Double
    public var onDemandCapCents: Double
    public var fetchedAt: Date

    public init(percent: Double, percentInferred: Bool, period: PeriodKind, periodStart: Date?, periodEnd: Date?,
                products: [ProductShare], prepaidBalanceCents: Double, onDemandUsedCents: Double,
                onDemandCapCents: Double, fetchedAt: Date) {
        self.percent = percent
        self.percentInferred = percentInferred
        self.period = period
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.products = products
        self.prepaidBalanceCents = prepaidBalanceCents
        self.onDemandUsedCents = onDemandUsedCents
        self.onDemandCapCents = onDemandCapCents
        self.fetchedAt = fetchedAt
    }

    public var roundedPercent: Int { Int(max(0, percent).rounded()) }
    public var level: UsageLevel { .forPercent(roundedPercent) }

    public var hasExtraCredits: Bool {
        prepaidBalanceCents > 0 || onDemandCapCents > 0 || onDemandUsedCents > 0
    }

    /// Stable identifier for the current billing window (used to send each alert once per period).
    public var periodKey: String {
        if let end = periodEnd { return String(Int(end.timeIntervalSince1970)) }
        return "unknown"
    }

    public func timeUntilReset(now: Date = Date()) -> TimeInterval? {
        guard let end = periodEnd else { return nil }
        return max(0, end.timeIntervalSince(now))
    }
}

// MARK: - Formatting helpers shared by the app and the CLI

public enum UsageFormat {
    public static func dollars(fromCents cents: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        return f.string(from: NSNumber(value: cents / 100)) ?? String(format: "$%.2f", cents / 100)
    }

    /// "5 days, 19 hr" / "19 hr, 4 min" / "4 min"
    public static func countdown(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days) \(days == 1 ? "day" : "days"), \(hours) hr" }
        if hours > 0 { return "\(hours) hr, \(minutes) min" }
        return "\(minutes) min"
    }

    /// Whole days left (0–7 for a weekly pool). Partial days round down.
    public static func wholeDays(_ interval: TimeInterval) -> Int {
        Int(max(0, interval) / 86_400)
    }

    /// e.g. "Tue, Oct 13 at 10:57 AM HST" in the given (default: current) time zone.
    public static func resetDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEE MMM d jmm z")
        return f.string(from: date)
    }
}
