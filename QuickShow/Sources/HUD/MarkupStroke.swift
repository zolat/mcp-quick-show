import Foundation

/// A single freehand stroke in the WebView canvas's CSS-pixel coord
/// space. Drawn into a `<canvas>` element injected into every WebView
/// by `markup-canvas.js`; persisted Swift-side on `Panel.strokes` so
/// strokes survive tear-out, reattach, and re-render.
///
/// Codable: shipped over the JS bridge as JSON in both directions
/// (Swift → JS via `setStrokes`, JS → Swift via the `markupStroke`
/// message channel).
struct MarkupStroke: Codable, Equatable, Sendable {
    struct Point: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
    }
    var points: [Point]
    /// CSS-color string ("#d8392c" or "rgba(216,57,44,1)"). Default
    /// matches the JS-side `DEFAULT_COLOR` so a stroke without an
    /// explicit color round-trips the same on both sides.
    var color: String
    var width: Double

    static let defaultColor = "#d8392c"
    static let defaultWidth: Double = 3
}
