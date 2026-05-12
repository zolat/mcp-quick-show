import Cocoa

/// Transparent overlay used in "draw mode" to capture user annotations
/// on top of a panel's renderer view. Lives in `HUDWindow.contentHost`
/// as the topmost subview; `isHidden = true` by default so mouse events
/// pass through to the renderer below. When draw mode is on the host
/// HUD shows the overlay and makes it first responder.
///
/// Strokes are captured in the overlay's local point space. The owner
/// is expected to mirror them to the active panel's `strokes` field on
/// every `onStrokesChanged` so they survive tab switches + tear-out.
@MainActor
final class MarkupOverlayView: NSView {
    /// A single freehand stroke. Stored as a complete `NSBezierPath` so
    /// drawing is a single `.stroke()` per stroke regardless of how
    /// many segments it contains. Not `Sendable` — NSBezierPath isn't,
    /// and we deliberately keep strokes on the MainActor where the
    /// owning Panel + overlay live.
    ///
    /// `anchorScroll` is the WebView's scroll position (CSS pixels, X
    /// + Y-down) AT THE MOMENT THE STROKE WAS DRAWN. The path's points
    /// are in viewport-local overlay coords (Cocoa Y-up) at that same
    /// moment. When `currentScroll` differs from `anchorScroll`, the
    /// overlay translates the stroke during rendering so it tracks the
    /// content beneath it: scroll down → content moves up → stroke
    /// moves up by the same amount.
    struct Stroke {
        var path: NSBezierPath
        var color: NSColor
        var width: CGFloat
        var anchorScroll: NSPoint = .zero
    }

    /// Visual defaults — single-color freehand for v0.1.
    static let defaultColor: NSColor = .systemRed
    static let defaultWidth: CGFloat = 3.0

    private var strokes: [Stroke] = []
    private var currentStroke: Stroke?

    private(set) var isCurrentlyDragging = false

    /// Fired on every stroke commit (mouseUp), every undo, and every
    /// `clear()`. The owner persists `currentStrokes()` to the active
    /// panel.
    var onStrokesChanged: (() -> Void)?

    /// Fired on Escape keypress. Owner exits draw mode but keeps
    /// strokes (toggling the markup button off again has the same
    /// effect from the user's POV).
    var onEscape: (() -> Void)?

    /// Fired when the user finishes a drag with no points captured
    /// (a click on the overlay with no movement). Used as a "you
    /// haven't drawn anything yet" hint by the host; default is nil.
    var onEmptyClick: (() -> Void)?

    /// When true, the overlay still renders strokes but does NOT
    /// capture mouse events — clicks fall through to the panel
    /// renderer below. The host HUD flips this in lockstep with
    /// its `isInDrawMode`: draw mode = capture, otherwise =
    /// pass-through. Keeping the overlay visible (rather than
    /// hiding it) is what lets sent strokes remain on screen as
    /// proof the action took.
    var isPassthrough: Bool = true {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }

    /// The current scroll position of the underlying renderer
    /// (CSS pixels, X + Y-down). Updated by the host whenever the
    /// renderer's WebView reports a scroll event. Used to translate
    /// stored strokes so they appear anchored to the content under
    /// them rather than fixed to the screen.
    private(set) var currentScroll: NSPoint = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    /// HUDWindow has `isMovableByWindowBackground = true`; an overlay
    /// that doesn't shadow it would let a drawing drag move the
    /// window. Block that explicitly.
    override var mouseDownCanMoveWindow: Bool { false }

    /// When in pass-through mode, AppKit hit-testing skips us so
    /// clicks reach the renderer view below. When capturing (draw
    /// mode), we participate in hit-test normally.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if isPassthrough { return nil }
        return super.hitTest(point)
    }

    /// In draw mode (overlay capturing input), absorb scroll wheel
    /// events so the WebView below stays frozen — strokes captured
    /// during scroll would visually drift from the cursor. Matches
    /// the "content is suspended while drawing" mental model
    /// already enforced by `suspendInteraction()` for panzoom.
    /// In pass-through mode, `hitTest` returns nil so this method
    /// isn't even routed to us; the WebView gets scroll wheel
    /// directly, as expected.
    override func scrollWheel(with event: NSEvent) {
        // intentional no-op while we have input focus
    }

    /// Crosshair cursor only while we're capturing input (draw mode).
    /// Pass-through state means the user is just looking at strokes,
    /// not editing them — keep the default arrow.
    override func resetCursorRects() {
        super.resetCursorRects()
        if !isPassthrough {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    // MARK: - Stroke API

    /// Replace the strokes shown by this overlay. Called when the host
    /// HUD activates a panel — strokes are loaded from the panel's
    /// stored array.
    func loadStrokes(_ next: [Stroke]) {
        strokes = next
        currentStroke = nil
        isCurrentlyDragging = false
        needsDisplay = true
    }

    /// Snapshot of the current committed strokes. Does not include any
    /// in-progress drag.
    func currentStrokes() -> [Stroke] { strokes }

    /// Drop all strokes (used by the Send flow after the composite is
    /// recorded).
    func clear() {
        strokes.removeAll()
        currentStroke = nil
        isCurrentlyDragging = false
        needsDisplay = true
        onStrokesChanged?()
    }

    /// Pop the most recently committed stroke. Cmd+Z entry point.
    func popLastStroke() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        needsDisplay = true
        onStrokesChanged?()
    }

    /// Test-only: synthesize a stroke straight into the committed
    /// array. The smoke test uses this to assert that the composite
    /// PNG has overlay pixels in the right region without driving a
    /// real mouse drag.
    func appendStrokeForTest(_ stroke: Stroke) {
        strokes.append(stroke)
        needsDisplay = true
        onStrokesChanged?()
    }

    /// Update the cached scroll position of the underlying renderer.
    /// Called by the host whenever the WebView posts a scroll event.
    /// Triggers a redraw so existing strokes shift to stay anchored
    /// to their content.
    func setCurrentScroll(_ scroll: NSPoint) {
        guard scroll != currentScroll else { return }
        currentScroll = scroll
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for stroke in strokes {
            drawStroke(stroke)
        }
        if let current = currentStroke {
            drawStroke(current)
        }
    }

    /// Draw one stroke with its scroll-following translation applied.
    /// `dx = anchor.x - current.x` (so a scroll-right shifts the
    /// stroke left), and `dy = current.y - anchor.y` because overlay
    /// space is Y-up while scroll is reported Y-down — a positive
    /// scroll delta moves content up, which is +Y in overlay coords.
    private func drawStroke(_ stroke: Stroke) {
        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        let dx = stroke.anchorScroll.x - currentScroll.x
        let dy = currentScroll.y - stroke.anchorScroll.y
        let xform = NSAffineTransform()
        xform.translateX(by: dx, yBy: dy)
        xform.concat()
        stroke.color.setStroke()
        stroke.path.lineWidth = stroke.width
        stroke.path.lineCapStyle = .round
        stroke.path.lineJoinStyle = .round
        stroke.path.stroke()
    }

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        // The mouseDown point is in window coords; convert to local.
        // We also snapshot the scroll *now* so the stroke remembers
        // where in the document it was drawn, even if the user
        // scrolls before mouseUp.
        let point = convert(event.locationInWindow, from: nil)
        let path = NSBezierPath()
        path.move(to: point)
        currentStroke = Stroke(
            path: path,
            color: Self.defaultColor,
            width: Self.defaultWidth,
            anchorScroll: currentScroll
        )
        isCurrentlyDragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard currentStroke != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        currentStroke?.path.line(to: point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let stroke = currentStroke else {
            isCurrentlyDragging = false
            return
        }
        // A bezier path with only the moveTo and no line segments has
        // elementCount == 1. Treat that as a "click without drag" —
        // commit nothing, but fire the empty-click hook.
        if stroke.path.elementCount > 1 {
            strokes.append(stroke)
            onStrokesChanged?()
        } else {
            onEmptyClick?()
        }
        currentStroke = nil
        isCurrentlyDragging = false
        needsDisplay = true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Cmd+Z = undo last stroke. Modifier check uses .deviceIndependentFlagsMask
        // so caps-lock / etc. don't break the shortcut.
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""
        if modifiers == .command && chars == "z" {
            popLastStroke()
            return
        }
        // Esc — owner exits draw mode (strokes preserved).
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - PNG export

    /// Render the current strokes into a transparent PNG at the given
    /// pixel size. The overlay's point-space bounds are mapped onto the
    /// pixel canvas via a scale transform so the result aligns with the
    /// underlying renderer snapshot at the same pixel dimensions.
    ///
    /// Returns nil if either dimension is zero or PNG encoding fails.
    func renderToPNG(pixelSize: NSSize) -> Data? {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let pixelW = Int(pixelSize.width.rounded())
        let pixelH = Int(pixelSize.height.rounded())
        guard let rep = NSBitmapImageRep(
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
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx

        // Clear to transparent.
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: pixelSize).fill()

        // Map point-space coordinates to pixel space. NSBitmapImageRep's
        // graphics context is in pixels; our strokes are in points.
        // Scale = pixelSize / boundsSize.
        let sx = pixelSize.width / bounds.width
        let sy = pixelSize.height / bounds.height
        let xform = AffineTransform(scaleByX: sx, byY: sy)
        (xform as NSAffineTransform).concat()

        for stroke in strokes {
            stroke.color.setStroke()
            // Stroke widths are in points; the scale transform above
            // takes care of converting to pixel widths.
            stroke.path.lineWidth = stroke.width
            stroke.path.lineCapStyle = .round
            stroke.path.lineJoinStyle = .round
            stroke.path.stroke()
        }

        return rep.representation(using: .png, properties: [:])
    }
}
