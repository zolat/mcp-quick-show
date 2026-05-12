import Foundation

/// Persistent app settings, backed by `UserDefaults`. Most prefs are
/// read at HUD-creation time so changes from `SettingsWindow` apply
/// only to newly spawned HUDs without affecting ones already on
/// screen (matches PipAnything's "defaults, not global toggles"
/// semantics).
///
/// Exception: `pinHudsToCurrentSpace` is a live toggle. Flipping it
/// posts `pinHudsToCurrentSpaceChanged`; every live HUD observes and
/// updates its `collectionBehavior` immediately.
///
/// The `default*` fallback values are also the v0.1 PRD defaults.
@MainActor
final class Settings {
    static let shared = Settings()

    /// Posted when `pinHudsToCurrentSpace` changes. `HUDWindow`
    /// observers re-apply their `collectionBehavior` on receipt.
    static let pinHudsToCurrentSpaceChanged = Notification.Name("QuickShow.pinHudsToCurrentSpaceChanged")

    private enum Key {
        static let defaultOpacityPercent = "QuickShow.defaultOpacityPercent"
        static let initialSizeCapWidth = "QuickShow.initialSizeCapWidth"
        static let initialSizeCapHeight = "QuickShow.initialSizeCapHeight"
        static let pinHudsToCurrentSpace = "QuickShow.pinHudsToCurrentSpace"
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

    /// When true, each HUD is tied to the macOS Space it was spawned
    /// in and disappears when the user switches Spaces. When false,
    /// HUDs use `.canJoinAllSpaces` and follow the user everywhere.
    /// Default: true (Space-scoped). Live: flipping this immediately
    /// updates every open HUD via `pinHudsToCurrentSpaceChanged`.
    /// Test override: `QUICKSHOW_PIN_TO_SPACE_OVERRIDE` ("1"/"0").
    var pinHudsToCurrentSpace: Bool {
        get {
            if let env = ProcessInfo.processInfo.environment["QUICKSHOW_PIN_TO_SPACE_OVERRIDE"] {
                return env == "1" || env.lowercased() == "true"
            }
            if defaults.object(forKey: Key.pinHudsToCurrentSpace) == nil { return true }
            return defaults.bool(forKey: Key.pinHudsToCurrentSpace)
        }
        set {
            defaults.set(newValue, forKey: Key.pinHudsToCurrentSpace)
        }
    }
}
