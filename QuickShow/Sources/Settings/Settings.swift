import Foundation

/// Persistent app settings, backed by `UserDefaults`. Most prefs are
/// read at HUD-creation time so changes from `SettingsWindow` apply
/// only to newly spawned HUDs without affecting ones already on
/// screen (matches PipAnything's "defaults, not global toggles"
/// semantics).
///
/// Exception: `hudSpacePolicy` is a live toggle. Flipping it posts
/// `hudSpacePolicyChanged`; every live HUD observes and updates its
/// `collectionBehavior` immediately.
///
/// The `default*` fallback values are also the v0.1 PRD defaults.
@MainActor
final class Settings {
    static let shared = Settings()

    /// Posted when `hudSpacePolicy` changes. `HUDWindow` observers
    /// re-apply their `collectionBehavior` on receipt.
    static let hudSpacePolicyChanged = Notification.Name("QuickShow.hudSpacePolicyChanged")

    private enum Key {
        static let defaultOpacityPercent = "QuickShow.defaultOpacityPercent"
        static let initialSizeCapWidth = "QuickShow.initialSizeCapWidth"
        static let initialSizeCapHeight = "QuickShow.initialSizeCapHeight"
        /// New v0.2+ enum-shaped setting. See `HudSpacePolicy`.
        static let hudSpacePolicy = "QuickShow.hudSpacePolicy"
        /// Legacy v0.1 bool key. Read once at first access of the new
        /// `hudSpacePolicy` setting, then deleted. true → .userSpace,
        /// false → .allSpaces. The new `.claudeSpace` mode is opt-in
        /// for migrated users (they get today's behaviour preserved).
        static let legacyPinHudsToCurrentSpace = "QuickShow.pinHudsToCurrentSpace"
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

    /// Where new HUD windows should open and how they behave across
    /// macOS Spaces. Default: `.claudeSpace`. Live: flipping this
    /// immediately re-applies `collectionBehavior` on every open HUD
    /// via `hudSpacePolicyChanged`.
    /// Test override: `QUICKSHOW_HUD_SPACE_POLICY_OVERRIDE` accepts
    /// the raw enum string ("userSpace" / "claudeSpace" / "allSpaces").
    var hudSpacePolicy: HudSpacePolicy {
        get {
            if let env = ProcessInfo.processInfo.environment["QUICKSHOW_HUD_SPACE_POLICY_OVERRIDE"],
               let v = HudSpacePolicy(rawValue: env) {
                return v
            }
            if let raw = defaults.string(forKey: Key.hudSpacePolicy),
               let v = HudSpacePolicy(rawValue: raw) {
                return v
            }
            // One-time migration from the v0.1 bool key. true → userSpace,
            // false → allSpaces. Preserves existing-user behaviour; new
            // installs get the .claudeSpace default below.
            if defaults.object(forKey: Key.legacyPinHudsToCurrentSpace) != nil {
                let legacyPinned = defaults.bool(forKey: Key.legacyPinHudsToCurrentSpace)
                let migrated: HudSpacePolicy = legacyPinned ? .userSpace : .allSpaces
                defaults.set(migrated.rawValue, forKey: Key.hudSpacePolicy)
                defaults.removeObject(forKey: Key.legacyPinHudsToCurrentSpace)
                return migrated
            }
            return .claudeSpace
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.hudSpacePolicy)
        }
    }
}

/// Where new HUDs open relative to macOS Spaces, and how they behave
/// once placed. Replaces the v0.1 `pinHudsToCurrentSpace` bool.
///
/// `.userSpace` and `.claudeSpace` share the same `collectionBehavior`
/// (`.fullScreenAuxiliary`) — they differ only in **where** the window
/// is placed on first show. `.claudeSpace` calls
/// `CGSAddWindowsToSpaces` to nudge the panel onto the Space that
/// contains Claude's terminal; `.userSpace` lets AppKit pick whichever
/// Space the user is looking at right now.
enum HudSpacePolicy: String, CaseIterable, Sendable {
    /// Panel opens on whichever Space the user is currently looking
    /// at, and stays there when the user switches Spaces. v0.1 default.
    case userSpace

    /// Panel opens on the Space containing the terminal hosting the
    /// Claude session (resolved via parent_pid → process tree →
    /// CGWindowList lookup). v0.2 default. Falls back to `.userSpace`
    /// behaviour when the lookup fails or private CGS APIs are
    /// unavailable.
    case claudeSpace

    /// Panel is visible on every Space and ignores Space switches.
    /// v0.1 unpinned behaviour. Useful when the user wants ambient
    /// presence regardless of which desktop they're using.
    case allSpaces

    /// User-facing label for the Settings UI.
    var displayName: String {
        switch self {
        case .userSpace:   return "My current Space"
        case .claudeSpace: return "Claude's Space"
        case .allSpaces:   return "All Spaces"
        }
    }

    /// Trailing helper text under the picker, one line per option.
    var helpText: String {
        switch self {
        case .userSpace:
            return "Open new panels where I'm looking now."
        case .claudeSpace:
            return "Open new panels on the desktop where the Claude terminal lives."
        case .allSpaces:
            return "Panels appear on every Space and follow you across them."
        }
    }
}
