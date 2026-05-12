import Cocoa

/// Bottom-right resize grip for the HUD. Lifted from PipAnything's
/// `ResizeHandle` — same shape, but with `lockAspect = false` by
/// default (static panels don't need the video aspect ratio dance).
/// Consumes mouseDown / mouseDragged so the HUD's
/// `isMovableByWindowBackground` doesn't fight the resize.
final class ResizeHandle: NSView {
    static let size: CGFloat = 18

    var minSize: NSSize = NSSize(width: 200, height: 140)
    var maxSize: NSSize = NSSize(width: 1600, height: 2400)

    private var startFrame: NSRect = .zero
    private var startMouse: NSPoint = .zero

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Prevents `isMovableByWindowBackground` from stealing the drag.
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : super.hitTest(point)
    }

    override func resetCursorRects() {
        // Public macOS doesn't expose a diagonal resize cursor; crosshair
        // signals "you can drag here" without misleading the user.
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window = self.window else { return }
        startFrame = window.frame
        startMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = self.window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - startMouse.x
        // Dragging down (negative dy in screen coords) should grow height.
        let dy = startMouse.y - now.y

        var newWidth = max(minSize.width, min(maxSize.width, startFrame.size.width + dx))
        var newHeight = max(minSize.height, min(maxSize.height, startFrame.size.height + dy))
        if !newWidth.isFinite { newWidth = minSize.width }
        if !newHeight.isFinite { newHeight = minSize.height }

        // Keep top-left fixed (the grip is bottom-right; that corner moves).
        var newFrame = startFrame
        newFrame.origin.y = startFrame.origin.y + (startFrame.size.height - newHeight)
        newFrame.size = NSSize(width: newWidth, height: newHeight)
        window.setFrame(newFrame, display: true, animate: false)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let color = NSColor.secondaryLabelColor.withAlphaComponent(0.5)
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        let inset: CGFloat = 4
        for i in 0..<3 {
            let offset = CGFloat(i) * 4
            path.move(to: NSPoint(x: bounds.width - inset - offset, y: inset))
            path.line(to: NSPoint(x: bounds.width - inset, y: inset + offset))
        }
        path.stroke()
    }
}
