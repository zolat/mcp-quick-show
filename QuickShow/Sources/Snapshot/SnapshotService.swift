import Cocoa
import WebKit

/// Captures PNG snapshots of renderer views. Two paths:
/// - `snapshotWebView` — visible-bounds capture for the live snapshot
///   returned in MCP responses (sized to fit the user's HUD).
/// - `snapshotWebViewFullDoc` — full-document capture for Send: the
///   WebView is pinned to `scrollWidth × scrollHeight` on each render,
///   so passing `config.rect = webView.bounds` produces a PNG of the
///   ENTIRE canvas — markup pixels included (the in-DOM `<canvas>`
///   sits in the same DOM the snapshot captures).
///
/// Caps: 1600 px wide × 4000 px tall, at 2× scale. Wider/taller
/// content is downscaled to fit (preserves aspect via `snapshotWidth`).
enum SnapshotService {
    static let maxPixelWidth: CGFloat = 1600
    static let maxPixelHeight: CGFloat = 4000
    static let scale: CGFloat = 2.0

    /// Snapshot a WKWebView at its current visible bounds. Used for
    /// the live snapshot returned in MCP responses — sized to fit
    /// the user's HUD without overshooting the pixel-width cap.
    @MainActor
    static func snapshotWebView(_ webView: WKWebView) async throws -> Data {
        let config = WKSnapshotConfiguration()
        let bounds = webView.bounds
        let targetWidthPx = min(bounds.width * scale, maxPixelWidth)
        let snapshotWidthPoints = targetWidthPx / NSScreen.main!.backingScaleFactor
        config.snapshotWidth = NSNumber(value: Double(snapshotWidthPoints))
        config.afterScreenUpdates = true
        return try await runTakeSnapshot(webView, config: config)
    }

    /// Full-document snapshot for Send. The WebView's bounds match
    /// the canvas size (pinned in `applyCanvasSize` on every render),
    /// so passing `config.rect = bounds` captures the entire document
    /// — including the in-DOM `<canvas>` strokes. No separate
    /// composite step needed; the markup IS part of the page.
    @MainActor
    static func snapshotWebViewFullDoc(_ webView: WKWebView) async throws -> Data {
        let config = WKSnapshotConfiguration()
        let bounds = webView.bounds
        config.rect = NSRect(origin: .zero, size: bounds.size)
        let targetWidthPx = min(bounds.width * scale, maxPixelWidth)
        let snapshotWidthPoints = targetWidthPx / NSScreen.main!.backingScaleFactor
        config.snapshotWidth = NSNumber(value: Double(snapshotWidthPoints))
        config.afterScreenUpdates = true
        return try await runTakeSnapshot(webView, config: config)
    }

    @MainActor
    private static func runTakeSnapshot(_ webView: WKWebView,
                                        config: WKSnapshotConfiguration) async throws -> Data {
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
