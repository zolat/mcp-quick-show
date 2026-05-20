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

    /// When true, the scroll view auto-fits its content to its own
    /// bounds on every frame change (window resize), using NSScrollView
    /// magnification — the inner WebView's CSS viewport is never
    /// touched, so the in-DOM markup canvas stays pixel-aligned with
    /// the content beneath it. Initialised from
    /// `Settings.fitContentToWindow`; kept in sync via
    /// `Settings.fitContentToWindowChanged`. Note: manual scroll-wheel
    /// zoom still works while this is on, but the next window resize
    /// snaps back to fit.
    var fitToWindow: Bool {
        didSet {
            guard oldValue != fitToWindow else { return }
            if fitToWindow { refitIfReady() }
        }
    }

    override init(frame frameRect: NSRect) {
        self.fitToWindow = Settings.shared.fitContentToWindow
        super.init(frame: frameRect)
        installCenteringClipView()
        installFrameChangeObserver()
        installSettingsObserver()
    }

    required init?(coder: NSCoder) {
        self.fitToWindow = Settings.shared.fitContentToWindow
        super.init(coder: coder)
        installCenteringClipView()
        installFrameChangeObserver()
        installSettingsObserver()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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

    /// Subscribe to our own frame-change notifications so we can
    /// re-fit when the host HUD window resizes. NSView only posts
    /// these when `postsFrameChangedNotifications` is true (default
    /// is true, but set explicitly so we're not relying on AppKit
    /// defaults).
    private func installFrameChangeObserver() {
        postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFrameChanged(_:)),
            name: NSView.frameDidChangeNotification,
            object: self
        )
    }

    /// Sync the `fitToWindow` ivar with `Settings.shared` whenever the
    /// user toggles the checkbox in `SettingsWindow`. The didSet on
    /// `fitToWindow` handles the snap-to-fit when flipping on.
    private func installSettingsObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFitContentSettingChanged(_:)),
            name: Settings.fitContentToWindowChanged,
            object: nil
        )
    }

    @objc private func handleFrameChanged(_ note: Notification) {
        guard fitToWindow else { return }
        refitIfReady()
    }

    @objc private func handleFitContentSettingChanged(_ note: Notification) {
        fitToWindow = Settings.shared.fitContentToWindow
    }

    /// Call `smartFit()` only if a documentView is installed and has
    /// a non-zero size. Skips the early-init window where the scroll
    /// view has been sized but the renderer hasn't reported a canvas
    /// size yet — fitting against a 0×0 document would be a no-op at
    /// best and undefined at worst.
    private func refitIfReady() {
        guard let doc = documentView, doc.bounds.width > 0, doc.bounds.height > 0 else { return }
        smartFit()
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
        // Belt-and-braces — in draw mode the in-DOM canvas captures
        // mouseDown via pointer-events:auto, so this branch normally
        // doesn't fire. But if the WebView's hit-test ever misses
        // (e.g. mouse in the letterbox area around a smaller-than-
        // bounds canvas), we'd otherwise enter pan + closed-hand
        // cursor and visually compete with the canvas's crosshair.
        guard !isInDrawMode else {
            super.mouseDown(with: event)
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
        if isInDrawMode {
            // Cover the whole scroll view in a crosshair rect so the
            // cursor stays consistent even in the letterbox area
            // around the WebView's CSS-styled canvas. Without this,
            // areas of the scroll view outside the canvas fall back
            // to whatever cursor was last set (closedHand from a
            // prior pan, openHand from before draw mode armed) and
            // visibly compete with the canvas's crosshair.
            addCursorRect(bounds, cursor: .crosshair)
            return
        }
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
