import Cocoa
import WebKit

/// Captures PNG snapshots of renderer views. Two paths:
/// - WKWebView: `takeSnapshot(with:)` with explicit pixel-width cap.
/// - Non-WebView NSView (e.g. NSImageView in Phase 2): bitmap rep
///   via `bitmapImageRepForCachingDisplay(in:)`.
///
/// Caps: 1600 px wide × 4000 px tall, at 2× scale. Wider/taller
/// content is downscaled to fit (preserves aspect for WK by setting
/// `snapshotWidth`; for non-WK we'd resample, but Phase 1 doesn't
/// exercise the non-WK path).
enum SnapshotService {
    static let maxPixelWidth: CGFloat = 1600
    static let maxPixelHeight: CGFloat = 4000
    static let scale: CGFloat = 2.0

    /// Snapshot a WKWebView. The web view should already be sized to
    /// fit its content (the HUD's resize-to-fit on first render means
    /// the visible bounds *are* the full rendered content most of the
    /// time). Anything beyond the visible bounds is clipped — the user
    /// can scroll within the HUD to see overflow, but the snapshot
    /// represents what's visible right now.
    @MainActor
    static func snapshotWebView(_ webView: WKWebView) async throws -> Data {
        let config = WKSnapshotConfiguration()
        let bounds = webView.bounds
        // Compute the target pixel width: scale × points, capped at maxPixelWidth.
        let targetWidthPx = min(bounds.width * scale, maxPixelWidth)
        // WKSnapshotConfiguration.snapshotWidth is **points** (despite
        // the docs being unclear) — passing 800 with no scale change
        // yields an image with `representations.first?.pixelsWide` =
        // 800 * window.backingScaleFactor. We want crisp 2× output;
        // set snapshotWidth to points-equivalent of our pixel target.
        let snapshotWidthPoints = targetWidthPx / NSScreen.main!.backingScaleFactor
        config.snapshotWidth = NSNumber(value: Double(snapshotWidthPoints))
        config.afterScreenUpdates = true

        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: config) { image, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let image = image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "QuickShow.Snapshot",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "takeSnapshot returned no image"]
                        )
                    )
                }
            }
        }

        return try encodePNG(image)
    }

    /// Snapshot an arbitrary NSView via NSBitmapImageRep. Used by
    /// `ImageRenderer` (Phase 2) which renders into an NSImageView.
    @MainActor
    static func snapshotView(_ view: NSView) throws -> Data {
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw NSError(
                domain: "QuickShow.Snapshot",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "bitmapImageRepForCachingDisplay returned nil"]
            )
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw NSError(
                domain: "QuickShow.Snapshot",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "failed to encode PNG"]
            )
        }
        return pngData
    }

    @MainActor
    private static func encodePNG(_ image: NSImage) throws -> Data {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(
                domain: "QuickShow.Snapshot",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "NSImage has no CGImage representation"]
            )
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(
                domain: "QuickShow.Snapshot",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "PNG representation failed"]
            )
        }
        return png
    }
}
