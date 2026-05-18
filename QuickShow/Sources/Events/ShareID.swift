import Foundation

/// Identifier minted when the user hits Send on a user-initiated HUD.
/// Goes onto the clipboard wrapped in a `[quickshow-share:<id>]` token
/// and used as the panel name (`share-<id>`) after migration, so a
/// 12-char lowercase-hex shape that's:
///   - Short enough to read out / paste comfortably.
///   - Wide enough for collision-freedom in practice (48 bits ≈ 2.8e14).
///   - Trivial to regex on the sidecar side (matches `[0-9a-f]{12}`).
///
/// Mirrored sidecar-side as `SHARE_ID_PATTERN` in `getShare.ts`.
enum ShareID {
    static let length = 12
    static let pattern = "^[0-9a-f]{\(length)}$"

    /// Mint a fresh share id. Takes the first `length` hex characters of
    /// a UUID — UUID's pseudo-random bits are sufficient here (this is
    /// a clipboard token the user re-presents to a peer, not a security
    /// boundary), and we avoid pulling in a base32 dependency just to
    /// shave four characters.
    static func mint() -> String {
        let uuid = UUID().uuidString.lowercased()
        let hex = uuid.replacingOccurrences(of: "-", with: "")
        return String(hex.prefix(length))
    }

    /// True iff `id` is well-formed — used by `claim_share` to refuse
    /// arbitrary strings as filesystem path components.
    static func isValid(_ id: String) -> Bool {
        id.range(of: pattern, options: .regularExpression) != nil
    }
}

/// Sidecar-readable metadata for an unclaimed share. Written next to
/// the PNG so `claim_share` can find the originating HUD (in the
/// user-windows session) and rehome it into a Claude session.
struct ShareMetadata: Codable {
    /// The panel name inside the user-windows session that produced
    /// this share. Used to locate the HUDInstance + Panel pair at claim
    /// time.
    let sourcePanelName: String
    /// The HUD instance id (UUID string) inside the user-windows
    /// session. Belt-and-braces lookup hint — panel name alone is
    /// enough in practice, but this avoids ambiguity if the user
    /// somehow ended up with two panels of the same name in the
    /// pseudo-session (shouldn't happen — each Send produces a unique
    /// shareId so panel name should be unique too — but cheap to log).
    let sourceHudId: String
    /// Content type of the panel at Send time (`"image"`, `"url"`,
    /// `"markdown"`, …). Echoed back to Claude via the `get_share`
    /// response text so it knows what kind of payload it's getting.
    let contentType: String
    /// Optional human-readable label (e.g. the original file name).
    let displayName: String?
    /// ISO-8601 timestamp at Send time — only used for log forensics.
    let createdAt: String
}
