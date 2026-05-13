import Cocoa

/// A pan-and-zoom container for renderer canvases (WKWebView,
/// NSImageView, anything). Generalization of the original
/// `ZoomableImageScrollView` from `ImageRenderer.swift`.
///
/// Features:
///   - Wheel-to-zoom (plain wheel = zoom centered on cursor;
///     shift-wheel + trackpad two-finger fall through to default
///     pan/scroll).
///   - mouseDown+drag pan when zoomed in (cursor switches to
///     open-/closed-hand).
///   - Double-click → reset fit. `smartFit()` picks fit-to-width for
///     tall content (designer ergonomic, matches Figma/Sketch) and
///     fit-to-bounds-capped-at-1.0 otherwise.
///   - `onTransformChanged` fires whenever magnification or pan
///     origin changes — the markup overlay subscribes to invalidate
///     its rendering against the new transform.
///
/// IMPORTANT: When using a `WKWebView` as a leaf content under
/// `documentView`, wrap it in a thin host whose `scrollWheel` calls
/// `super.scrollWheel(with:)` — otherwise WKWebView consumes wheel
/// events before they reach this scroll view's clip view. See
/// `WebViewHostView` in `WebViewPanelRenderer.swift`.
@MainActor
final class ZoomableCanvasScrollView: NSScrollView {
    private var isPanning = false
    private var panStart: NSPoint = .zero
    private var panStartScrollOrigin: NSPoint = .zero

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installCenteringClipView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installCenteringClipView()
    }

    /// Swap the default clip view for one that centers the document
    /// when it's smaller than the visible bounds. Must run before
    /// `documentView` is assigned (assigning `contentView` clears the
    /// existing documentView). Our caller — WebViewPanelRenderer's
    /// `makeView()` — assigns documentView after construction, so the
    /// init-time replacement here is safe.
    private func installCenteringClipView() {
        let clip = CenteringClipView()
        clip.drawsBackground = false
        self.contentView = clip
    }

    /// Fired any time the canvas → screen transform changes:
    /// magnification flips, pan origin moves, fit recompute. The
    /// markup overlay binds this to invalidate its display so its
    /// canvas-space strokes re-render at the right screen positions.
    var onTransformChanged: (() -> Void)?

    /// When true, suppress the open-/closed-hand pan cursor — the
    /// active panel is in draw mode and the WebView's in-DOM canvas
    /// has its own (crosshair) cursor that should show through. Pan
    /// itself is naturally blocked in draw mode anyway (the canvas
    /// captures mouseDown), so the cursor would have been lying.
    var isInDrawMode: Bool = false {
        didSet {
            guard oldValue != isInDrawMode else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    // MARK: - Fit modes

    /// Fit the entire document into the visible bounds (preserves
    /// aspect, possibly shrinks below 1.0). Right default for
    /// square-ish content (images).
    func fitToContainer() {
        guard let doc = documentView else { return }
        magnify(toFit: doc.bounds)
        onTransformChanged?()
    }

    /// Fit width of document into visible bounds; let height
    /// overflow vertically (user pans down). Right default for
    /// designer-canvas content where the doc may be much taller
    /// than wide.
    func fitToContainerByWidth() {
        guard let doc = documentView, doc.bounds.width > 0 else { return }
        let containerW = contentView.bounds.width
        let target = max(minMagnification,
                         min(maxMagnification,
                             containerW / doc.bounds.width))
        let topLeft = NSPoint(x: 0, y: doc.bounds.height)
        setMagnification(target, centeredAt: topLeft)
        // Scroll clip view to the top of the document.
        contentView.scroll(to: NSPoint(x: 0, y: doc.bounds.height))
        reflectScrolledClipView(contentView)
        onTransformChanged?()
    }

    /// Pick the fit mode based on document shape: fit-to-width when
    /// the document is appreciably taller than wide (designer
    /// canvas), fit-to-bounds capped at 1.0 otherwise. Caller doesn't
    /// have to know which is which.
    func smartFit() {
        guard let doc = documentView else { return }
        let w = doc.bounds.width
        let h = doc.bounds.height
        guard w > 0, h > 0 else { return }
        if h / w > 1.5 {
            fitToContainerByWidth()
        } else {
            magnify(toFit: doc.bounds)
            // Don't enlarge content past 1× even if the container
            // could host it.
            if magnification > 1.0 {
                let center = NSPoint(x: doc.bounds.midX, y: doc.bounds.midY)
                setMagnification(1.0, centeredAt: center)
            }
            onTransformChanged?()
        }
    }

    // MARK: - Wheel: zoom (plain wheel) / pan (precise trackpad / shift)

    override func scrollWheel(with event: NSEvent) {
        let isPreciseTrackpadScroll = event.hasPreciseScrollingDeltas
        let isShiftHeld = event.modifierFlags.contains(.shift)
        if isPreciseTrackpadScroll || isShiftHeld {
            super.scrollWheel(with: event)
            // Precise scroll changes the clip origin, which counts
            // as a pan from the overlay's POV — invalidate.
            onTransformChanged?()
            return
        }
        let delta = event.scrollingDeltaY
        let factor = exp(delta * 0.005)
        let cursor = convert(event.locationInWindow, from: nil)
        let newMag = max(minMagnification, min(maxMagnification,
                                               magnification * factor))
        setMagnification(newMag, centeredAt: cursor)
        onTransformChanged?()
    }

    // MARK: - Drag: pan when zoomed in

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            smartFit()
            return
        }
        guard magnification > minMagnification + 0.01 else {
            super.mouseDown(with: event)
            return
        }
        isPanning = true
        panStart = NSEvent.mouseLocation
        if let clip = contentView as NSClipView? {
            panStartScrollOrigin = clip.bounds.origin
        }
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPanning else {
            super.mouseDragged(with: event)
            return
        }
        let now = NSEvent.mouseLocation
        let dx = (now.x - panStart.x) / magnification
        let dy = (now.y - panStart.y) / magnification
        let clip = contentView
        var newOrigin = panStartScrollOrigin
        newOrigin.x -= dx
        newOrigin.y += dy
        clip.setBoundsOrigin(newOrigin)
        reflectScrolledClipView(clip)
        onTransformChanged?()
    }

    override func mouseUp(with event: NSEvent) {
        if isPanning {
            isPanning = false
            NSCursor.arrow.set()
        } else {
            super.mouseUp(with: event)
        }
    }

    override func resetCursorRects() {
        if isInDrawMode { return }
        if magnification > minMagnification + 0.01 {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

// MARK: - Centering clip view

/// NSClipView subclass that pulls the document toward the center of
/// the visible bounds when the document is smaller than the clip. The
/// standard AppKit recipe: override `constrainBoundsRect` to shift the
/// clip's bounds origin into negative territory by the half-difference
/// on each axis. When the doc is larger (zoomed in), the parent's
/// implementation clamps the origin so panning works normally.
@MainActor
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        let docFrame = doc.frame
        if rect.size.width > docFrame.size.width {
            rect.origin.x = (docFrame.size.width - rect.size.width) / 2
        }
        if rect.size.height > docFrame.size.height {
            rect.origin.y = (docFrame.size.height - rect.size.height) / 2
        }
        return rect
    }
}
