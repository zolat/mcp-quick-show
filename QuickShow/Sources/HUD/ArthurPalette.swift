import Cocoa

/// Shared HUD chrome palette. Originally defined `private static` on
/// `TitleBarOverlay`; lifted out as new chrome surfaces (description
/// banner, future tab-strip polish) started reaching for the same
/// constants. Keep additions here — every Arthur token belongs in one
/// place so contrast and warmth stay aligned across views.
enum ArthurPalette {
    /// Warm dark surface that sits one step above the contentHost
    /// background (#1c1c1c). Used by the title bar and the description
    /// banner so the chrome stack reads as one continuous layer.
    static let elevated = NSColor(
        red:  42/255.0, green: 38/255.0, blue: 32/255.0, alpha: 1.0
    )

    /// Soft sage-gray — primary text + icon tint for HUD chrome. Has
    /// enough contrast against `elevated` to read, without competing
    /// with rendered content for attention.
    static let textMuted = NSColor(
        red: 168/255.0, green: 169/255.0, blue: 158/255.0, alpha: 1.0
    )

    /// Default stroke color shown by the title-bar color picker.
    /// Matches `markup-canvas.js`'s `DEFAULT_COLOR`.
    static let defaultStrokeRed = NSColor(
        red: 216/255.0, green: 57/255.0, blue: 44/255.0, alpha: 1.0
    )

    /// Primary-action accent — sage olive (#88904a). Replaces the
    /// system `controlAccentColor` (Apple blue) on the Send / Copy
    /// pills so chrome reads as one warm palette instead of borrowing
    /// the user's system tint.
    static let accent = NSColor(
        red: 136/255.0, green: 144/255.0, blue: 74/255.0, alpha: 1.0
    )
}
