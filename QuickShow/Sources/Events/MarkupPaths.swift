import Foundation

/// Resolves the on-disk locations for per-session markup events and
/// artifacts. Sidecar and app derive paths from the same inputs so they
/// stay in lockstep without an extra control-protocol round trip.
///
/// Layout (default):
///   ~/Library/Caches/QuickShow/events/<sessionId>/events.ndjson
///   ~/Library/Caches/QuickShow/events/<sessionId>/artifacts/<id>.png
///   ~/Library/Caches/QuickShow/shares/<shareId>.png            (user-initiated shares)
///   ~/Library/Caches/QuickShow/shares/<shareId>.json
///
/// Override the events base via `QUICKSHOW_EVENTS_DIR` and the shares
/// base via `QUICKSHOW_SHARES_DIR` (tests pointing at `$TMPDIR` so they
/// don't clobber a real session's log or an unclaimed share).
enum MarkupPaths {
    /// Base events directory shared across all sessions.
    static var baseDir: URL {
        if let override = ProcessInfo.processInfo.environment["QUICKSHOW_EVENTS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("QuickShow/events", isDirectory: true)
    }

    /// Per-session directory; parent of the events log and artifacts dir.
    static func sessionDir(_ sessionId: String) -> URL {
        baseDir.appendingPathComponent(sessionId, isDirectory: true)
    }

    /// NDJSON log of Claude-actionable events (markup_sent / markup_dismissed).
    static func eventsLog(_ sessionId: String) -> URL {
        sessionDir(sessionId).appendingPathComponent("events.ndjson", isDirectory: false)
    }

    /// Directory holding the flattened markup PNGs by artifact-uuid.
    static func artifactsDir(_ sessionId: String) -> URL {
        sessionDir(sessionId).appendingPathComponent("artifacts", isDirectory: true)
    }

    /// Concrete path for one artifact PNG.
    static func artifact(_ sessionId: String, id: String) -> URL {
        artifactsDir(sessionId).appendingPathComponent("\(id).png", isDirectory: false)
    }

    /// Ensure the per-session events + artifacts directories exist.
    /// Returns the events-log URL for convenience.
    @discardableResult
    static func ensureDirs(_ sessionId: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: sessionDir(sessionId), withIntermediateDirectories: true)
        try fm.createDirectory(at: artifactsDir(sessionId), withIntermediateDirectories: true)
        return eventsLog(sessionId)
    }

    // MARK: - Shares (user-initiated windows)
    //
    // The user can open a HUD from the menu bar, optionally mark it up,
    // and Send it to a Claude session via a clipboard share token. The
    // resulting PNG + a small JSON sidecar live in a session-agnostic
    // `shares/` dir until a Claude calls `get_share(<id>)` — at which
    // point the app reads the metadata to locate the HUD, migrates the
    // window into Claude's session, and moves the artifacts to
    // `shares/.consumed/`.

    /// Base shares directory — session-agnostic.
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
