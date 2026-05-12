import Foundation

/// Persistent app settings, backed by `UserDefaults`. Read at HUD-
/// creation time so changes from `SettingsWindow` apply to newly
/// spawned HUDs without affecting ones already on screen (matches
/// PipAnything's "defaults, not global toggles" semantics).
///
/// The `default*` fallback values are also the v0.1 PRD defaults.
@MainActor
final class Settings {
    static let shared = Settings()

    private enum Key {
        static let defaultOpacityPercent = "QuickShow.defaultOpacityPercent"
        static let initialSizeCapWidth = "QuickShow.initialSizeCapWidth"
        static let initialSizeCapHeight = "QuickShow.initialSizeCapHeight"
    }

    private let defaults = UserDefaults.standard

    /// Opacity (0-100) applied as `NSWindow.alphaValue` to each new HUD.
    /// Default: 100 %.
    /// Test override: `QUICKSHOW_OPACITY_OVERRIDE`.
    var defaultOpacityPercent: Int {
        get {
            if let env = ProcessInfo.processInfo.environment["QUICKSHOW_OPACITY_OVERRIDE"],
               let v = Int(env) { return max(10, min(100, v)) }
            let raw = defaults.integer(forKey: Key.defaultOpacityPercent)
            return raw == 0 ? 100 : max(10, min(100, raw))
        }
        set {
            defaults.set(max(10, min(100, newValue)), forKey: Key.defaultOpacityPercent)
        }
    }

    /// Initial size cap, width (in points). Default: 800 pt.
    /// Test override: `QUICKSHOW_SIZE_CAP_WIDTH_OVERRIDE`.
    var initialSizeCapWidth: Int {
        get {
            if let env = ProcessInfo.processInfo.environment["QUICKSHOW_SIZE_CAP_WIDTH_OVERRIDE"],
               let v = Int(env) { return max(200, v) }
            let raw = defaults.integer(forKey: Key.initialSizeCapWidth)
            return raw == 0 ? 800 : max(280, raw)
        }
        set {
            defaults.set(max(280, newValue), forKey: Key.initialSizeCapWidth)
        }
    }

    /// Initial size cap, height (in points). Default: 1000 pt.
    /// Test override: `QUICKSHOW_SIZE_CAP_HEIGHT_OVERRIDE`.
    var initialSizeCapHeight: Int {
        get {
            if let env = ProcessInfo.processInfo.environment["QUICKSHOW_SIZE_CAP_HEIGHT_OVERRIDE"],
               let v = Int(env) { return max(200, v) }
            let raw = defaults.integer(forKey: Key.initialSizeCapHeight)
            return raw == 0 ? 1000 : max(200, raw)
        }
        set {
            defaults.set(max(200, newValue), forKey: Key.initialSizeCapHeight)
        }
    }
}
