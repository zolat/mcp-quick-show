import Cocoa

/// Renders a raster image from a file path into a panel. Uses an
/// `NSImageView` directly — skips the WKWebView base class — because:
/// - HiDPI rendering / image-rep selection happens natively.
/// - Big files don't melt the web process; AppKit's image-rep machine
///   does proper tile-based decode.
/// - The PRD's snapshot return value for `show_image` is *the image
///   itself*, not a screenshot — so we cache the original bytes from
///   the path and return them directly.
///
/// The view is wrapped in a `ZoomableImageScrollView` so zoom + pan
/// match the diagram renderers (PRD user story #35b extended to
/// images by the human's plan). Zoom is purely a viewing affordance;
/// `lastImageData` is still the canonical "what does the agent see"
/// payload returned by `snapshot()`.
@MainActor
final class ImageRenderer: NSObject, PanelRenderer {
    static var typeKey: String { "image" }

    private let imageView = NSImageView()
    private let scrollView = ZoomableImageScrollView()
    private(set) var lastImageData: Data?
    private(set) var lastImageSize: CGSize = .zero

    override init() {
        super.init()
    }

    func makeView() -> NSView {
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = imageView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.25
        scrollView.maxMagnification = 8.0
        scrollView.usesPredominantAxisScrolling = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.wantsLayer = true
        return scrollView
    }

    func update(payload: PanelPayload) async throws -> RenderResult {
        guard payload.form == "path" else {
            throw RenderFailure(
                message: "show_image only supports `form: path` in v0.1",
                line: nil
            )
        }
        let url = URL(fileURLWithPath: payload.body)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RenderFailure(
                message: "failed to read image at '\(payload.body)': \(error.localizedDescription)",
                line: nil
            )
        }
        guard let image = NSImage(data: data) else {
            throw RenderFailure(
                message: "couldn't decode image at '\(payload.body)' (corrupt or unsupported format)",
                line: nil
            )
        }
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        lastImageData = data
        lastImageSize = image.size
        // Schedule a fit pass after the scroll view has been sized by
        // its host. Doing this synchronously here would magnify against
        // the previous frame.
        DispatchQueue.main.async { [weak self] in
            self?.scrollView.fitToContainer()
        }
        return RenderResult(width: Double(image.size.width), height: Double(image.size.height))
    }

    func snapshot() async throws -> Data {
        // The PRD specifies that show_image returns the image *bytes
        // themselves*, not a snapshot of the rendered panel. Cached
        // from the last update.
        if let data = lastImageData {
            return data
        }
        return try SnapshotService.snapshotView(imageView)
    }
}

/// Custom `NSScrollView` that adds:
///   - Wheel-to-zoom (plain wheel = zoom centered on cursor;
///     shift-wheel falls through to default scroll-while-zoomed).
///   - mouseDown+drag pan when zoomed in (cursor switches to
///     open-/closed-hand).
///   - Double-click reset-to-fit.
@MainActor
final class ZoomableImageScrollView: NSScrollView {
    private var isPanning = false
    private var panStart: NSPoint = .zero
    private var panStartScrollOrigin: NSPoint = .zero

    override var acceptsFirstResponder: Bool { true }

    func fitToContainer() {
        guard let doc = documentView else { return }
        magnify(toFit: doc.bounds)
    }

    override func scrollWheel(with event: NSEvent) {
        // Shift-wheel and trackpad two-finger scrolls (when zoomed)
        // should pan/scroll normally — only plain mouse-wheel zooms.
        // NSEvent.subtype isn't reliable for trackpad-vs-mouse; use
        // `event.hasPreciseScrollingDeltas` as the trackpad signal.
        let isPreciseTrackpadScroll = event.hasPreciseScrollingDeltas
        let isShiftHeld = event.modifierFlags.contains(.shift)
        if isPreciseTrackpadScroll || isShiftHeld {
            super.scrollWheel(with: event)
            return
        }
        // Plain wheel → zoom.
        let delta = event.scrollingDeltaY
        let factor = exp(delta * 0.005)
        let cursor = convert(event.locationInWindow, from: nil)
        let newMag = max(minMagnification, min(maxMagnification, magnification * factor))
        setMagnification(newMag, centeredAt: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            fitToContainer()
            return
        }
        // Only treat as pan when zoomed in enough that there's
        // somewhere to pan to.
        guard magnification > minMagnification + 0.01 else {
            super.mouseDown(with: event)
            return
        }
        isPanning = true
        panStart = NSEvent.mouseLocation
        if let doc = documentView, let clip = contentView as NSClipView? {
            panStartScrollOrigin = clip.bounds.origin
            _ = doc
        }
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPanning else {
            super.mouseDragged(with: event)
            return
        }
        let now = NSEvent.mouseLocation
        // Drag deltas are in screen points; pan is in scroll-view
        // coords. Magnification factor inverts the relationship.
        let dx = (now.x - panStart.x) / magnification
        let dy = (now.y - panStart.y) / magnification
        let clip = contentView
        var newOrigin = panStartScrollOrigin
        // Y increases upward on macOS; dragging up moves content down,
        // so the origin moves up by dy.
        newOrigin.x -= dx
        newOrigin.y += dy
        clip.setBoundsOrigin(newOrigin)
        reflectScrolledClipView(clip)
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
        // Show the open-hand cue when zoomed in; default cursor otherwise.
        if magnification > minMagnification + 0.01 {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}
