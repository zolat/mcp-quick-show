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
    static let version = "0.2"

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

/// `kind: "hello"` — handshake. `sessionId` is a CLAIM the sidecar
/// computed from its cwd; the app's allocator inspects its per-FD
/// session map and either grants it or mints a fresh UUID when the
/// claim is contested by another live connection. The granted id
/// rides back in `HelloResult.sessionId`.
struct HelloRequest: Decodable {
    let id: String?
    let kind: String
    let sessionId: String
    let client: String?
    /// Informational — logged when a claim contest is resolved.
    let parentPid: Int32?

    enum CodingKeys: String, CodingKey {
        case id, kind, client
        case sessionId = "session_id"
        case parentPid = "parent_pid"
    }
}

/// `sessionId` is the GRANTED id — sidecar adopts unconditionally.
struct HelloResult: Encodable {
    let version: String
    let pid: Int32
    let sessionId: String

    enum CodingKeys: String, CodingKey {
        case version, pid
        case sessionId = "session_id"
    }
}

/// `kind: "ping"` — round-trip liveness check. No payload.
struct PingResult: Encodable {
    let version: String
    let pid: Int32
}

/// `kind: "upsert"` — render content into a named panel slot.
///
/// `contentType` is one of: "markdown" | "svg" | "image" | "mermaid" |
/// "html" | "url" — paired with `sidecar/src/protocol.ts`.
struct UpsertRequest: Decodable {
    let id: String?
    let kind: String
    let session: String
    let name: String
    let contentType: String
    let form: String           // "inline" | "path" | "url"
    let body: String
    /// Optional canvas-width hint, in points. Used by HTMLRenderer
    /// and URLRenderer to size the WebView's CSS viewport before
    /// content loads — so responsive designs lay out at the intended
    /// width rather than the default 400pt.
    let width: Double?
    /// Optional grouping key. Panels sharing a `group` land in the
    /// same HUD; each distinct `group` spawns its own HUD with its
    /// own cascade origin. Omitted → the session's default (unnamed)
    /// HUD. Ignored on same-`name` updates: `name` is sticky to the
    /// HUD where it was first created.
    let group: String?
    /// Optional per-panel framing paragraph rendered in the HUD's
    /// description banner above the content. Empty string clears.
    let description: String?
    /// Optional HUD-level framing paragraph rendered in the
    /// description banner above per-tab `description`. Last-writer-
    /// wins across calls that route to the same HUD. Empty string
    /// clears.
    let hudDescription: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, session, name, form, body, width, group, description
        case contentType = "content_type"
        case hudDescription = "hud_description"
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

/// `kind: "claim_share"` — handed off from the sidecar's `get_share`
/// MCP tool. The user opened a HUD from the menu bar, optionally
/// marked it up, hit Send → the app wrote a flattened PNG + JSON
/// sidecar to `MarkupPaths.sharesBaseDir` and put a
/// `[quickshow-share:<share_id>]` token on the clipboard. The user
/// pastes the token into Claude; Claude calls `get_share(<id>)`; the
/// sidecar forwards here with `session = <claimer_session_id>`.
///
/// Side effects on the app:
///   1. The HUDInstance backing the share migrates from the
///      reserved "user-windows" session into the claimer session.
///   2. The panel is renamed to `share-<share_id>` so Claude can
///      address it with subsequent `show_*` calls.
///   3. The share PNG is moved into the claimer session's artifacts
///      directory at `<share_id>.png` so the sidecar's `get_share`
///      can read it through the same path discipline as
///      `get_markup` (and a second `get_share` of the same id from a
///      different session gets a clean "already consumed" answer).
struct ClaimShareRequest: Decodable {
    let id: String?
    let kind: String
    /// Target session — the Claude session calling `get_share`.
    let session: String
    let shareId: String

    enum CodingKeys: String, CodingKey {
        case id, kind, session
        case shareId = "share_id"
    }
}

/// Returned in `ControlOk.result` on a successful claim. The panel
/// name lets Claude continue to address the now-migrated HUD with
/// `show_url` / `show_image` / `show_html` / `show_markdown`.
struct ClaimShareResult: Encodable {
    let panelName: String
    let contentType: String

    enum CodingKeys: String, CodingKey {
        case contentType = "content_type"
        case panelName = "panel_name"
    }
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
