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

    /// Composite a set of markup strokes (in point space, with their
    /// origin at the view's top-left in flipped Cocoa terms — i.e.,
    /// drawn the way they appear in `MarkupOverlayView.draw(_:)`) over
    /// an underlying PNG. The output PNG matches the underlying's
    /// pixel dimensions so the two layers line up.
    ///
    /// Returns nil on any failure — the caller falls back to emitting
    /// the underlying snapshot unchanged.
    @MainActor
    static func compositeMarkup(underlyingPNG: Data,
                                strokes: [MarkupOverlayView.Stroke],
                                viewBoundsPt: NSSize) -> Data? {
        guard let underlyingRep = NSBitmapImageRep(data: underlyingPNG) else {
            return nil
        }
        let pixelW = underlyingRep.pixelsWide
        let pixelH = underlyingRep.pixelsHigh
        guard pixelW > 0, pixelH > 0 else { return nil }
        guard viewBoundsPt.width > 0, viewBoundsPt.height > 0 else { return nil }

        // Build a new bitmap rep at the underlying's pixel size and
        // draw both layers into it. The bitmap context's coordinate
        // system has its origin at top-left when we paint a previous
        // NSImage via `draw(in:)`, so we mirror that for the overlay
        // by drawing it in the same downward-Y orientation: an
        // explicit Y-flip transform after scaling.
        guard let outRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW,
            pixelsHigh: pixelH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: outRep) else { return nil }
        NSGraphicsContext.current = ctx

        let outRect = NSRect(x: 0, y: 0, width: pixelW, height: pixelH)
        // 1. Underlying snapshot fills the whole canvas.
        let underlyingImage = NSImage(size: NSSize(width: pixelW, height: pixelH))
        underlyingImage.addRepresentation(underlyingRep)
        underlyingImage.draw(in: outRect, from: .zero, operation: .copy, fraction: 1.0)

        // 2. Overlay strokes on top. The strokes were captured in the
        //    overlay's local point space (Y-up, origin at bottom-left
        //    of the overlay = the renderer view's bottom-left). The
        //    underlying snapshot's bottom-left maps to (0, 0) in the
        //    output's drawing coordinate space too, so a uniform
        //    point→pixel scale is all that's needed.
        let sx = CGFloat(pixelW) / viewBoundsPt.width
        let sy = CGFloat(pixelH) / viewBoundsPt.height
        let xform = NSAffineTransform()
        xform.scaleX(by: sx, yBy: sy)
        xform.concat()

        for stroke in strokes {
            stroke.color.setStroke()
            stroke.path.lineWidth = stroke.width
            stroke.path.lineCapStyle = .round
            stroke.path.lineJoinStyle = .round
            stroke.path.stroke()
        }

        return outRep.representation(using: .png, properties: [:])
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
