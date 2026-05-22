import Foundation

/// Value type for per-group flags driven by the MCP `enable_*` tools.
/// Modeled as a small JSON-shaped sum so flag emission/consumption
/// stays uniform whether the value originates in Swift code
/// (`.bool(true)`) or arrives from the wire via JSONDecoder. First
/// consumers: `markup_events_armed`, `panel_events_armed`.
enum SessionFlagValue: Decodable, Hashable {
    case bool(Bool)
    case string(String)
    case number(Double)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c,
                debugDescription: "expected bool, number, string, or null"
            )
        }
    }

    var asAny: AnyHashable {
        switch self {
        case .bool(let b): return AnyHashable(b)
        case .string(let s): return AnyHashable(s)
        case .number(let n): return AnyHashable(n)
        case .null: return AnyHashable("")
        }
    }

    var asBool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}
