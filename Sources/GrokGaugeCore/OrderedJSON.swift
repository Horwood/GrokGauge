import Foundation

/// A tiny order-preserving JSON tree used only to rewrite `~/.grok/auth.json`.
///
/// Scalars keep their exact source text, so values GrokGauge doesn't touch are
/// written back byte-for-byte, and keys keep their original order. Output uses
/// the same layout as the Grok CLI (serde_json's pretty printer: two-space
/// indent, `"key": value`).
indirect enum JSONNode: Equatable {
    case object([Member])
    case array([JSONNode])
    case scalar(String)          // raw literal: "string", number, true, false, null

    struct Member: Equatable {
        var rawKey: String       // key exactly as written, including quotes
        var key: String          // decoded key
        var value: JSONNode
    }

    static func string(_ s: String) -> JSONNode { .scalar(JSONNode.quote(s)) }

    subscript(key: String) -> JSONNode? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    /// Replaces (in place) or appends a member. No-op for non-objects.
    mutating func set(_ key: String, _ value: JSONNode) {
        guard case .object(var members) = self else { return }
        if let i = members.firstIndex(where: { $0.key == key }) {
            members[i].value = value
        } else {
            members.append(Member(rawKey: JSONNode.quote(key), key: key, value: value))
        }
        self = .object(members)
    }

    // MARK: Serialization (serde_json `to_string_pretty` layout)

    func serialized(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch self {
        case .scalar(let raw):
            return raw
        case .array(let items):
            if items.isEmpty { return "[]" }
            return "[\n" + items.map { inner + $0.serialized(indent: indent + 1) }.joined(separator: ",\n") + "\n" + pad + "]"
        case .object(let members):
            if members.isEmpty { return "{}" }
            return "{\n" + members.map { inner + $0.rawKey + ": " + $0.value.serialized(indent: indent + 1) }
                .joined(separator: ",\n") + "\n" + pad + "}"
        }
    }

    /// JSON string literal, escaping like serde_json (", \, and control characters only).
    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: Parsing

    struct ParseError: Error {}

    static func parse(_ data: Data) throws -> JSONNode {
        var p = Parser(bytes: [UInt8](data))
        p.skipWhitespace()
        let node = try p.value()
        p.skipWhitespace()
        guard p.atEnd else { throw ParseError() }
        return node
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0
        var atEnd: Bool { i >= bytes.count }

        mutating func skipWhitespace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        mutating func value() throws -> JSONNode {
            guard i < bytes.count else { throw ParseError() }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .scalar(try rawString())
            default: return .scalar(try literal())
            }
        }

        mutating func object() throws -> JSONNode {
            i += 1
            var members: [Member] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw ParseError() }
                let rawKey = try rawString()
                guard let key = try? JSONSerialization.jsonObject(with: Data(rawKey.utf8), options: .fragmentsAllowed) as? String
                else { throw ParseError() }
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw ParseError() }
                i += 1
                skipWhitespace()
                members.append(Member(rawKey: rawKey, key: key, value: try value()))
                skipWhitespace()
                guard i < bytes.count else { throw ParseError() }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                throw ParseError()
            }
        }

        mutating func array() throws -> JSONNode {
            i += 1
            var items: [JSONNode] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try value())
                skipWhitespace()
                guard i < bytes.count else { throw ParseError() }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw ParseError()
            }
        }

        mutating func rawString() throws -> String {
            let start = i
            i += 1
            while i < bytes.count {
                switch bytes[i] {
                case UInt8(ascii: "\\"): i += 2
                case UInt8(ascii: "\""):
                    i += 1
                    guard let s = String(bytes: bytes[start..<i], encoding: .utf8) else { throw ParseError() }
                    return s
                default: i += 1
                }
            }
            throw ParseError()
        }

        mutating func literal() throws -> String {
            let start = i
            while i < bytes.count, ![0x20, 0x09, 0x0A, 0x0D, UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]")].contains(bytes[i]) {
                i += 1
            }
            guard i > start, let s = String(bytes: bytes[start..<i], encoding: .utf8) else { throw ParseError() }
            // Validate it's a real JSON literal.
            guard (try? JSONSerialization.jsonObject(with: Data(s.utf8), options: .fragmentsAllowed)) != nil else {
                throw ParseError()
            }
            return s
        }
    }
}
