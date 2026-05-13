import Foundation

// Wire format for the control socket. Mirrored in
// `sidecar/src/protocol.ts` — changes must touch both files in the
// same commit.
//
// Envelope shape (per PRD § "Wire-protocol envelope"):
//   sidecar → app:  {"id", "kind":"hello|ping|upsert|close|list|inspect|set_session_flag", ...}
//   app → sidecar:  {"id", "kind":"ok|render_error|protocol_error", ...}
//
// The discriminator and payload fields are flat at the same level;
// handlers decode the entire line as their typed payload after
// switching on `kind`.

enum ControlProtocol {
    static let version = "0.1"

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}

// MARK: - Envelope

struct ControlRequest {
    let id: String?
    let kind: String
    /// The raw JSON bytes of the request line. Handlers decode this
    /// into their kind-specific typed payload (e.g. `HelloRequest`).
    let raw: Data

    static func decode(line: Data) throws -> ControlRequest {
        guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw ControlError.protocolError("expected JSON object")
        }
        let id = obj["id"] as? String
        guard let kind = obj["kind"] as? String else {
            throw ControlError.protocolError("missing 'kind'")
        }
        return ControlRequest(id: id, kind: kind, raw: line)
    }

    func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
        try ControlProtocol.decoder.decode(type, from: raw)
    }
}

// MARK: - Responses

/// Successful response. `kind: "ok"` with an arbitrary result payload.
struct ControlOk: Encodable {
    let id: String?
    let kind: String = "ok"
    let result: AnyEncodable?

    init(id: String?, result: (some Encodable)? = nil as Int?) {
        self.id = id
        self.result = result.map(AnyEncodable.init)
    }
}

/// Render-side error — the request was valid, but the renderer failed.
/// Includes an optional screenshot of the in-DOM error UI.
struct ControlRenderError: Encodable {
    let id: String?
    let kind: String = "render_error"
    let error: String
    let line: Int?
    let screenshotB64: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, error, line
        case screenshotB64 = "screenshot_b64"
    }
}

/// Protocol-level error — malformed request, unknown kind, etc.
struct ControlProtocolError: Encodable {
    let id: String?
    let kind: String = "protocol_error"
    let error: String
}

struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init(_ value: some Encodable) {
        _encode = value.encode
    }
    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}

// MARK: - Errors

enum ControlError: Error {
    case protocolError(String)
    case unknownKind(String)
    case invalidPayload(String)
    case renderError(String, line: Int?)

    var protocolMessage: String {
        switch self {
        case .protocolError(let s): return s
        case .unknownKind(let s): return "unknown kind: '\(s)'"
        case .invalidPayload(let s): return "invalid payload: \(s)"
        case .renderError(let s, _): return s
        }
    }
}

// MARK: - Per-kind payload types

/// `kind: "hello"` — handshake. Sidecar identifies itself + session.
struct HelloRequest: Decodable {
    let id: String?
    let kind: String
    let sessionId: String
    let client: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, client
        case sessionId = "session_id"
    }
}

struct HelloResult: Encodable {
    let version: String
    let pid: Int32
}

/// `kind: "ping"` — round-trip liveness check. No payload.
struct PingResult: Encodable {
    let version: String
    let pid: Int32
}

/// `kind: "upsert"` — render content into a named panel slot.
struct UpsertRequest: Decodable {
    let id: String?
    let kind: String
    let session: String
    let name: String
    let contentType: String
    let form: String           // "inline" | "path"
    let body: String
    /// Optional canvas-width hint, in points. Used by HTMLRenderer
    /// (and potentially others) to size the WebView's CSS viewport
    /// before rendering — so responsive designs lay out at the
    /// intended width rather than the default 400pt.
    let width: Double?

    enum CodingKeys: String, CodingKey {
        case id, kind, session, name, form, body, width
        case contentType = "content_type"
    }
}

struct UpsertResult: Encodable {
    let width: Double
    let height: Double
    let screenshotB64: String?

    enum CodingKeys: String, CodingKey {
        case width, height
        case screenshotB64 = "screenshot_b64"
    }
}

/// `kind: "close"` — close a panel by name in a session.
struct CloseRequest: Decodable {
    let id: String?
    let kind: String
    let session: String
    let name: String
}

/// `kind: "list"` — list all panels in a session.
struct ListRequest: Decodable {
    let id: String?
    let kind: String
    let session: String
}

struct PanelInfo: Encodable {
    let name: String
    let contentType: String
    let width: Double
    let height: Double

    enum CodingKeys: String, CodingKey {
        case name, width, height
        case contentType = "content_type"
    }
}

/// `kind: "inspect"` — re-snapshot an existing panel.
struct InspectRequest: Decodable {
    let id: String?
    let kind: String
    let session: String
    let name: String
}

/// `kind: "set_session_flag"` — set a per-session flag on the app. The
/// first consumer is `markup_events_armed`, gating the HUD's Send
/// button on markup-capable panels. The value column accepts bool /
/// string / number / null to keep the verb generic for future flags.
struct SetSessionFlagRequest: Decodable {
    let id: String?
    let kind: String
    let session: String
    let key: String
    let value: SessionFlagValue
}

/// Loose-typed value column for `set_session_flag`. Decoded into the
/// app's `[String: AnyHashable]` flag dictionary.
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
