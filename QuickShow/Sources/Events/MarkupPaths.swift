import Foundation

/// Resolves the on-disk locations for per-session markup events and
/// artifacts. Sidecar and app derive paths from the same inputs so they
/// stay in lockstep without an extra control-protocol round trip.
///
/// Layout (default):
///   ~/Library/Caches/QuickShow/events/<sessionId>/events.ndjson
///   ~/Library/Caches/QuickShow/events/<sessionId>/artifacts/<id>.png
///
/// Override the base via `QUICKSHOW_EVENTS_DIR` (used by tests pointing
/// at a `$TMPDIR` so they don't clobber a real session's log).
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
}
