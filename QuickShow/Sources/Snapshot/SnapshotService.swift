import Cocoa
import WebKit

/// Internal navigation-delegate helper used by `snapshotFullDocument`
/// to know when the offscreen WebView's `loadHTMLString` has finished
/// laying out + running scripts. One-shot: each instance is bound to
/// a single async continuation.
@MainActor
private final class OffscreenNavigationDelegate: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Error>?

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            self.continuation?.resume()
            self.continuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFail navigation: WKNavigation!,
                             withError error: any Error) {
        MainActor.assumeIsolated {
            self.continuation?.resume(throwing: error)
            self.continuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: any Error) {
        MainActor.assumeIsolated {
            self.continuation?.resume(throwing: error)
            self.continuation = nil
        }
    }
}

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

    /// Capture the full scrollable document of a `WKWebView`, not
    /// just the visible viewport. Used by the markup Send flow so the
    /// agent sees the whole design, with the user's annotations
    /// positioned wherever they drew them (translated from viewport
    /// coords into document coords).
    ///
    /// Implementation: reads the live DOM via `outerHTML` + reports
    /// scroll position / document size, then re-renders the captured
    /// HTML in an OFFSCREEN `WKWebView` sized to the document's full
    /// scroll height. The visible panel is not disturbed (no flicker,
    /// no reflow). Scripts in the captured HTML will re-execute in
    /// the offscreen copy — for typical design content this is
    /// idempotent, but it's the reason the caller may skip this path
    /// for static-or-fits-in-viewport panels.
    ///
    /// Returns:
    ///   - data: the full-document PNG bytes
    ///   - docSize: document size in points
    ///   - viewBounds: original (visible) view bounds in points,
    ///     needed to translate strokes from viewport→document space
    ///   - scrollOffset: original scroll position in CSS pixels
    @MainActor
    static func snapshotFullDocument(_ webView: WKWebView) async throws ->
        (data: Data, docSize: NSSize, viewBounds: NSSize, scrollOffset: NSPoint)
    {
        // 1. Pull metadata + the live HTML in one round-trip each.
        let metaJS = """
        (function(){
            var de = document.documentElement;
            var b = document.body || de;
            return [
                Math.max(de.scrollWidth||0, b.scrollWidth||0, de.clientWidth||0),
                Math.max(de.scrollHeight||0, b.scrollHeight||0, de.clientHeight||0),
                window.scrollX || de.scrollLeft || 0,
                window.scrollY || de.scrollTop || 0
            ];
        })()
        """
        let metaResult = try await webView.evaluateJavaScript(metaJS)
        guard let arr = metaResult as? [Any], arr.count == 4,
              let docW = (arr[0] as? NSNumber)?.doubleValue,
              let docH = (arr[1] as? NSNumber)?.doubleValue,
              let sX = (arr[2] as? NSNumber)?.doubleValue,
              let sY = (arr[3] as? NSNumber)?.doubleValue else {
            throw NSError(
                domain: "QuickShow.Snapshot",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "could not read document size"]
            )
        }
        // Keep the offscreen rendering at the ORIGINAL viewport width
        // so responsive CSS lays out identically. The vertical
        // dimension expands to the full document height.
        let viewBounds = webView.bounds.size
        let docSize = NSSize(
            width: max(viewBounds.width, docW),
            height: max(viewBounds.height, docH)
        )
        let scrollOffset = NSPoint(x: sX, y: sY)

        guard let outerHTML = try await webView.evaluateJavaScript(
            "document.documentElement.outerHTML"
        ) as? String else {
            throw NSError(
                domain: "QuickShow.Snapshot",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "could not read outerHTML"]
            )
        }

        // 2. Build the offscreen WebView. Sized to original viewport
        //    width × full doc height so responsive layout matches.
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let offFrame = NSRect(origin: .zero, size: docSize)
        let offscreen = WKWebView(frame: offFrame, configuration: cfg)
        offscreen.setValue(false, forKey: "drawsBackground")
        // Attach to a transient host so layout runs deterministically.
        // The host is local, not added to any window — it dies with
        // the function frame.
        let host = NSView(frame: offFrame)
        host.addSubview(offscreen)

        // 3. Load + wait for didFinish.
        let nav = OffscreenNavigationDelegate()
        offscreen.navigationDelegate = nav
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nav.continuation = cont
            offscreen.loadHTMLString(outerHTML, baseURL: nil)
        }
        // Give scripts a moment to settle (mermaid + panzoom both
        // schedule async work after DOM ready).
        try await Task.sleep(nanoseconds: 250_000_000)

        // 4. Snapshot the entire bounds. Skip the visible-viewport
        //    width cap — tall full-page captures are the whole point.
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        let targetWidthPx = min(docSize.width * scale, maxPixelWidth)
        let backing = NSScreen.main?.backingScaleFactor ?? 2.0
        config.snapshotWidth = NSNumber(value: Double(targetWidthPx / backing))

        let image: NSImage = try await withCheckedThrowingContinuation { cont in
            offscreen.takeSnapshot(with: config) { img, err in
                if let err = err {
                    cont.resume(throwing: err)
                } else if let img = img {
                    cont.resume(returning: img)
                } else {
                    cont.resume(throwing: NSError(
                        domain: "QuickShow.Snapshot",
                        code: 12,
                        userInfo: [NSLocalizedDescriptionKey: "full-doc snapshot returned no image"]
                    ))
                }
            }
        }

        // 5. Tear down. Releasing offscreen + host immediately
        //    triggers WKWebView cleanup; nav delegate is reset so
        //    in-flight callbacks don't fire post-return.
        offscreen.navigationDelegate = nil
        offscreen.removeFromSuperview()
        _ = host

        return (try encodePNG(image), docSize, viewBounds, scrollOffset)
    }

    /// Composite strokes onto a full-document PNG. Each stroke
    /// remembers the scroll position it was drawn against
    /// (`anchorScroll`), so the doc-Y-up offset is computed
    /// per-stroke: viewport bottom in doc-Y-up =
    /// `docH - stroke.anchorScroll.y - viewH`. This lets strokes
    /// drawn at different scroll positions land in different
    /// document regions — the right behavior for tall designs the
    /// user scrolls through while annotating.
    @MainActor
    static func compositeMarkupFullPage(documentPNG: Data,
                                        strokes: [MarkupOverlayView.Stroke],
                                        viewBoundsPt: NSSize,
                                        docSizePt: NSSize) -> Data?
    {
        guard let docRep = NSBitmapImageRep(data: documentPNG) else { return nil }
        let pixelW = docRep.pixelsWide
        let pixelH = docRep.pixelsHigh
        guard pixelW > 0, pixelH > 0 else { return nil }
        guard docSizePt.width > 0, docSizePt.height > 0 else { return nil }
        guard viewBoundsPt.width > 0, viewBoundsPt.height > 0 else { return nil }

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
        let docImage = NSImage(size: NSSize(width: pixelW, height: pixelH))
        docImage.addRepresentation(docRep)
        docImage.draw(in: outRect, from: .zero, operation: .copy, fraction: 1.0)

        let sxScale = CGFloat(pixelW) / docSizePt.width
        let syScale = CGFloat(pixelH) / docSizePt.height

        for stroke in strokes {
            let docYupOffset = docSizePt.height - stroke.anchorScroll.y - viewBoundsPt.height
            let docXOffset = stroke.anchorScroll.x
            NSGraphicsContext.current?.saveGraphicsState()
            let xform = NSAffineTransform()
            xform.scaleX(by: sxScale, yBy: syScale)
            xform.translateX(by: docXOffset, yBy: docYupOffset)
            xform.concat()
            stroke.color.setStroke()
            stroke.path.lineWidth = stroke.width
            stroke.path.lineCapStyle = .round
            stroke.path.lineJoinStyle = .round
            stroke.path.stroke()
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        return outRep.representation(using: .png, properties: [:])
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
