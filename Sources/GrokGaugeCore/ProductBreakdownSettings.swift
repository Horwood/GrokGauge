import Foundation

/// How the "Grok by product" rows are ordered.
public enum ProductSort: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The drag order from Settings (the default).
    case custom
    /// Highest share of the pool first; ties keep the drag order.
    case usage
    /// A–Z by name; ties keep the drag order.
    case alphabetical

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .custom: return "My order"
        case .usage: return "Highest usage first"
        case .alphabetical: return "Alphabetical"
        }
    }
}

/// One product row in Settings: its display name (e.g. "Chat", or "App Builder" for a product xAI adds later)
/// and whether it's shown.
public struct ProductToggle: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var visible: Bool
    public init(_ id: String, visible: Bool = true) {
        self.id = id
        self.visible = visible
    }

    enum CodingKeys: String, CodingKey { case id, visible }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        visible = (try? c.decodeIfPresent(Bool.self, forKey: .visible)) ?? true
    }
}

/// Which products the "Grok by product" card shows, and in what order. Part of `GaugeSettings`, so it goes
/// into Export/Import and settings sync.
public struct ProductBreakdownSettings: Codable, Equatable, Sendable {
    /// Chat, Imagine, Voice, Build, API: the shared SuperGrok pool's products, in their default order.
    public static var canonicalNames: [String] { UsageParser.canonical.map(\.name) }
    public static let standard = ProductBreakdownSettings()

    /// The drag order. Always contains the canonical products; products xAI added later appear here once the
    /// user has reordered or hidden something while they were listed.
    public var order: [ProductToggle]
    public var sort: ProductSort

    public init(order: [ProductToggle] = ProductBreakdownSettings.defaultOrder, sort: ProductSort = .custom) {
        self.order = Self.normalized(order)
        self.sort = sort
    }

    public static var defaultOrder: [ProductToggle] { canonicalNames.map { ProductToggle($0) } }

    public var isDefault: Bool { self == .standard }

    public mutating func reset() { self = .standard }

    /// Whether a product is shown. Products not in the list (new ones from xAI) are shown.
    public func isVisible(_ name: String) -> Bool {
        order.first { $0.id == name }?.visible ?? true
    }

    /// The rows for Settings: the saved order, then any product in `current` that isn't in it yet (at the end,
    /// shown), so new products can be hidden or moved like the others.
    public func listing(including current: [ProductShare]) -> [ProductToggle] {
        var out = order
        for p in current where !out.contains(where: { $0.id == p.name }) { out.append(ProductToggle(p.name)) }
        return out
    }

    /// The products to draw, hidden ones removed, in the chosen sort. Unknown products come after the known
    /// ones (in the order the data lists them) for "My order" and as the tie-break for the other sorts.
    public func arrange(_ products: [ProductShare]) -> [ProductShare] {
        let rankOf: [String: Int] = Dictionary(order.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ranked: [(p: ProductShare, rank: Int)] = products.enumerated().compactMap { i, p in
            guard isVisible(p.name) else { return nil }
            return (p, rankOf[p.name] ?? (order.count + i))
        }
        let sorted: [(p: ProductShare, rank: Int)]
        switch sort {
        case .custom:
            sorted = ranked.sorted { $0.rank < $1.rank }
        case .usage:
            sorted = ranked.sorted { a, b in
                let pa = a.p.percent.isFinite ? a.p.percent : 0
                let pb = b.p.percent.isFinite ? b.p.percent : 0
                return pa != pb ? pa > pb : a.rank < b.rank
            }
        case .alphabetical:
            sorted = ranked.sorted { a, b in
                let c = a.p.name.localizedCaseInsensitiveCompare(b.p.name)
                return c != .orderedSame ? c == .orderedAscending : a.rank < b.rank
            }
        }
        return sorted.map(\.p)
    }

    /// Drops duplicates and empty names; adds any missing canonical product after its nearest canonical
    /// predecessor (so a list saved before a product existed still gets it, in a sensible place).
    static func normalized(_ items: [ProductToggle]) -> [ProductToggle] {
        var seen = Set<String>()
        var out: [ProductToggle] = []
        for item in items where !item.id.isEmpty && !seen.contains(item.id) {
            seen.insert(item.id)
            out.append(item)
        }
        let canon = canonicalNames
        for (i, name) in canon.enumerated() where !seen.contains(name) {
            let previous = canon[..<i].reversed().first { p in out.contains { $0.id == p } }
            let at = previous.flatMap { p in out.firstIndex { $0.id == p } }.map { $0 + 1 } ?? 0
            out.insert(ProductToggle(name), at: min(at, out.count))
            seen.insert(name)
        }
        return out
    }

    enum CodingKeys: String, CodingKey { case order, sort }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Entry by entry, so one bad row doesn't drop the whole list; an unknown sort falls back to My order.
        let rows = (try? c.decodeIfPresent([LenientProductToggle].self, forKey: .order))?.compactMap(\.value)
        let sort = (try? c.decodeIfPresent(ProductSort.self, forKey: .sort)) ?? .custom
        self.init(order: rows ?? Self.defaultOrder, sort: sort)
    }
}

private struct LenientProductToggle: Decodable {
    let value: ProductToggle?
    init(from decoder: Decoder) throws { value = try? ProductToggle(from: decoder) }
}

public extension UsageParser {
    /// SF Symbol for a product name (the generic grid for products xAI adds later).
    static func symbol(forProduct name: String) -> String {
        canonical.first { $0.name == name }?.symbol ?? "square.grid.2x2.fill"
    }
}
