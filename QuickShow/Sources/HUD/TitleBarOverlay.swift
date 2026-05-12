import Cocoa

/// Slim title bar that floats over the top of the HUD content. Shows
/// the panel name and an × close button. Auto-hides when the cursor
/// leaves the HUD (Phase 1 default: always-visible; auto-hide lands
/// with the tab strip in Phase 3).
///
/// Click on the bar background drags the window (forwards via
/// `mouseDownCanMoveWindow = true`); the close button consumes its
/// own click via `mouseDownCanMoveWindow = false`.
final class TitleBarOverlay: NSView {
    static let height: CGFloat = 22

    var onClose: (() -> Void)?
    var onSnapshot: (() -> Void)?
    /// Fired once when a drag gesture starts (after a 3-pt threshold,
    /// so a click on the title bar doesn't accidentally trigger a
    /// "drag" with zero movement).
    var onDragStart: (() -> Void)?
    /// Fired on every drag event; argument is the cursor's screen
    /// location. SessionManager uses this to detect drop targets.
    var onDragMove: ((NSPoint) -> Void)?
    /// Fired on mouseUp after a drag; argument is the cursor's final
    /// screen location.
    var onDragEnd: ((NSPoint) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    private let snapshotButton = NSButton(title: "⇩", target: nil, action: nil)
    private let badgeView = NSTextField(labelWithString: "")
    private let backgroundLayer = CALayer()

    private var mouseDownPoint: NSPoint = .zero
    private var initialWindowFrame: NSRect = .zero
    private var isDragging = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Self.height))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(0.85).cgColor
        layer?.cornerRadius = 6

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.font = .systemFont(ofSize: 10, weight: .medium)
        badgeView.textColor = .systemRed
        badgeView.isHidden = true
        addSubview(badgeView)

        snapshotButton.translatesAutoresizingMaskIntoConstraints = false
        snapshotButton.isBordered = false
        snapshotButton.font = .systemFont(ofSize: 13, weight: .medium)
        snapshotButton.contentTintColor = .secondaryLabelColor
        snapshotButton.target = self
        snapshotButton.action = #selector(handleSnapshot)
        snapshotButton.toolTip = "Save snapshot to ~/Downloads"
        addSubview(snapshotButton)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 14, weight: .medium)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(handleClose)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeView.leadingAnchor, constant: -6),
            badgeView.trailingAnchor.constraint(equalTo: snapshotButton.leadingAnchor, constant: -8),
            badgeView.centerYAnchor.constraint(equalTo: centerYAnchor),
            snapshotButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            snapshotButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            snapshotButton.widthAnchor.constraint(equalToConstant: 18),
            snapshotButton.heightAnchor.constraint(equalToConstant: 18),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    /// Show or hide the "session ended" badge. When shown, the HUD is
    /// orphaned: the sidecar has disconnected and didn't reconnect
    /// within the grace window.
    func setSessionEnded(_ ended: Bool) {
        badgeView.isHidden = !ended
        badgeView.stringValue = ended ? "● session ended" : ""
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// We take over the window-drag manually so we can observe the
    /// cursor during drag (for reattach drop-target detection). The
    /// strip background still has `mouseDownCanMoveWindow = true` as
    /// an escape hatch that uses AppKit's native drag (no drop
    /// detection, but always works as plain move).
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = NSEvent.mouseLocation
        initialWindowFrame = window?.frame ?? .zero
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        if !isDragging {
            let dx = now.x - mouseDownPoint.x
            let dy = now.y - mouseDownPoint.y
            if hypot(dx, dy) < 3 { return }   // dead zone — treat as click
            isDragging = true
            onDragStart?()
        }
        let dx = now.x - mouseDownPoint.x
        let dy = now.y - mouseDownPoint.y
        window?.setFrameOrigin(NSPoint(
            x: initialWindowFrame.origin.x + dx,
            y: initialWindowFrame.origin.y + dy
        ))
        onDragMove?(now)
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            onDragEnd?(NSEvent.mouseLocation)
        }
        isDragging = false
    }

    func setTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    @objc private func handleClose() {
        onClose?()
    }

    @objc private func handleSnapshot() {
        onSnapshot?()
    }
}
