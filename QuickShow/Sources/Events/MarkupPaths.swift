import Foundation

/// Resolves the on-disk locations for per-group markup events and
/// artifacts. Sidecar and app derive paths from the same inputs so they
/// stay in lockstep without an extra control-protocol round trip.
///
/// `group` is the canonical content namespace (Phase 2): every show_*
/// call lands in a group (defaulting to `mcpSessionId` when omitted at
/// the wire), and events.ndjson / artifacts/ are scoped per group so
/// parallel MCP sessions writing to the same group share an events
/// stream + artifact pool.
///
/// Layout (default):
///   ~/Library/Caches/QuickShow/events/<group>/events.ndjson
///   ~/Library/Caches/QuickShow/events/<group>/artifacts/<id>.png
///   ~/Library/Caches/QuickShow/shares/<shareId>.png            (user-initiated shares)
///   ~/Library/Caches/QuickShow/shares/<shareId>.json
///
/// Override the events base via `QUICKSHOW_EVENTS_DIR` and the shares
/// base via `QUICKSHOW_SHARES_DIR` (tests pointing at `$TMPDIR` so they
/// don't clobber a real group's log or an unclaimed share).
enum MarkupPaths {
    /// Base events directory shared across all groups.
    static var baseDir: URL {
        if let override = ProcessInfo.processInfo.environment["QUICKSHOW_EVENTS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("QuickShow/events", isDirectory: true)
    }

    /// Per-group directory; parent of the events log and artifacts dir.
    static func sessionDir(_ group: String) -> URL {
        baseDir.appendingPathComponent(group, isDirectory: true)
    }

    /// NDJSON log of Claude-actionable events (markup_sent / markup_dismissed).
    static func eventsLog(_ group: String) -> URL {
        sessionDir(group).appendingPathComponent("events.ndjson", isDirectory: false)
    }

    /// Directory holding the flattened markup PNGs by artifact-uuid.
    static func artifactsDir(_ group: String) -> URL {
        sessionDir(group).appendingPathComponent("artifacts", isDirectory: true)
    }

    /// Concrete path for one artifact PNG.
    static func artifact(_ group: String, id: String) -> URL {
        artifactsDir(group).appendingPathComponent("\(id).png", isDirectory: false)
    }

    /// Ensure the per-group events + artifacts directories exist.
    /// Returns the events-log URL for convenience.
    @discardableResult
    static func ensureDirs(_ group: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: sessionDir(group), withIntermediateDirectories: true)
        try fm.createDirectory(at: artifactsDir(group), withIntermediateDirectories: true)
        return eventsLog(group)
    }

    // MARK: - Shares (user-initiated windows)
    //
    // The user can open a HUD from the menu bar, optionally mark it up,
    // and Send it to a Claude session via a clipboard share token. The
    // resulting PNG + a small JSON sidecar live in a group-agnostic
    // `shares/` dir until a Claude calls `get_share(<id>)` — at which
    // point the app reads the metadata to locate the HUD, migrates the
    // window into the claimer's group, and moves the artifacts to
    // `shares/.consumed/`.

    /// Base shares directory — group-agnostic.
    static var sharesBaseDir: URL {
        if let override = ProcessInfo.processInfo.environment["QUICKSHOW_SHARES_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("QuickShow/shares", isDirectory: true)
    }

    /// `.consumed/` sibling inside the shares dir — destination for
    /// claimed artifacts so a second `get_share(<same-id>)` can tell
    /// "claimed by someone else" apart from "never existed."
    static var consumedSharesDir: URL {
        sharesBaseDir.appendingPathComponent(".consumed", isDirectory: true)
    }

    /// Flattened PNG for an unclaimed share.
    static func sharePNG(id: String) -> URL {
        sharesBaseDir.appendingPathComponent("\(id).png", isDirectory: false)
    }

    /// JSON metadata for an unclaimed share (panel name, content type,
    /// source HUD id, etc. — see `ShareMetadata` for the shape).
    static func shareMeta(id: String) -> URL {
        sharesBaseDir.appendingPathComponent("\(id).json", isDirectory: false)
    }

    /// PNG location after `get_share` has consumed the share.
    static func consumedSharePNG(id: String) -> URL {
        consumedSharesDir.appendingPathComponent("\(id).png", isDirectory: false)
    }

    /// Metadata location after `get_share` has consumed the share.
    static func consumedShareMeta(id: String) -> URL {
        consumedSharesDir.appendingPathComponent("\(id).json", isDirectory: false)
    }

    /// Ensure the shares + `.consumed/` directories exist.
    static func ensureShareDirs() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: sharesBaseDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: consumedSharesDir, withIntermediateDirectories: true)
    }
}
