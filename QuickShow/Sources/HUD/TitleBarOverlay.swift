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
    /// Fired when the user clicks the markup pencil — host toggles
    /// draw mode on the active panel.
    var onToggleDrawMode: (() -> Void)?
    /// Fired when the user clicks the Send check mark — host captures
    /// the active panel + any strokes into a composite PNG and emits
    /// a `markup_sent` event.
    var onSend: (() -> Void)?
    /// Fired when the user clicks the clear ⌫ button — host wipes
    /// the current panel's strokes (no event emission; this is a
    /// local UI escape hatch, not a feedback signal).
    var onClearMarkup: (() -> Void)?
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
    private let markupButton = NSButton(title: "✏︎", target: nil, action: nil)
    private let clearMarkupButton = NSButton(title: "⌫", target: nil, action: nil)
    private let sendButton = NSButton(title: "✓", target: nil, action: nil)
    private let badgeView = NSTextField(labelWithString: "")
    private let backgroundLayer = CALayer()

    private var mouseDownPoint: NSPoint = .zero
    private var initialWindowFrame: NSRect = .zero
    private var isDragging = false

    /// Session id this title bar belongs to, used to filter the
    /// `quickShowSessionFlagChanged` notification so cross-session
    /// flag flips don't toggle our buttons.
    private var owningSessionId: String?
    /// Current draw-mode visual state — `markupButton` highlights when
    /// true. Host (HUDWindow) flips this in lockstep with its own
    /// `isInDrawMode`.
    private var drawModeActive: Bool = false
    /// Whether the session is armed for markup events. The markup +
    /// send buttons appear when this is true; the clear button needs
    /// `armed && hasStrokes` (see `refreshClearButtonVisibility`).
    private var armed: Bool = false
    /// Whether the active panel has any strokes drawn. Drives the
    /// clear button's visibility so it only shows when there's
    /// something to clear.
    private var hasStrokes: Bool = false

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

        // Markup, Clear, and Send live between snapshot and close.
        // Markup + Send appear when `setArmed(true)` reveals them; the
        // Clear button additionally requires strokes to exist — it'd
        // be visual noise as a perpetual no-op.
        markupButton.translatesAutoresizingMaskIntoConstraints = false
        markupButton.isBordered = false
        markupButton.font = .systemFont(ofSize: 13, weight: .medium)
        markupButton.contentTintColor = .secondaryLabelColor
        markupButton.target = self
        markupButton.action = #selector(handleMarkup)
        markupButton.toolTip = "Toggle markup draw mode"
        markupButton.isHidden = true
        addSubview(markupButton)

        clearMarkupButton.translatesAutoresizingMaskIntoConstraints = false
        clearMarkupButton.isBordered = false
        clearMarkupButton.font = .systemFont(ofSize: 13, weight: .medium)
        clearMarkupButton.contentTintColor = .secondaryLabelColor
        clearMarkupButton.target = self
        clearMarkupButton.action = #selector(handleClearMarkup)
        clearMarkupButton.toolTip = "Clear markup strokes"
        clearMarkupButton.isHidden = true
        addSubview(clearMarkupButton)

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.isBordered = false
        sendButton.font = .systemFont(ofSize: 13, weight: .bold)
        sendButton.contentTintColor = .controlAccentColor
        sendButton.target = self
        sendButton.action = #selector(handleSend)
        sendButton.toolTip = "Send markup to agent"
        sendButton.isHidden = true
        addSubview(sendButton)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 14, weight: .medium)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(handleClose)
        addSubview(closeButton)

        // Layout chain right-to-left from the closeButton anchor. The
        // markup + send buttons are part of the chain even when hidden
        // (their width constraints keep the spacing consistent if/when
        // they become visible) — visibility is toggled via `isHidden`,
        // not by removing them from the constraint graph.
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeView.leadingAnchor, constant: -6),
            badgeView.trailingAnchor.constraint(equalTo: snapshotButton.leadingAnchor, constant: -8),
            badgeView.centerYAnchor.constraint(equalTo: centerYAnchor),
            snapshotButton.trailingAnchor.constraint(equalTo: markupButton.leadingAnchor, constant: -4),
            snapshotButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            snapshotButton.widthAnchor.constraint(equalToConstant: 18),
            snapshotButton.heightAnchor.constraint(equalToConstant: 18),
            markupButton.trailingAnchor.constraint(equalTo: clearMarkupButton.leadingAnchor, constant: -4),
            markupButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            markupButton.widthAnchor.constraint(equalToConstant: 18),
            markupButton.heightAnchor.constraint(equalToConstant: 18),
            clearMarkupButton.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -4),
            clearMarkupButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearMarkupButton.widthAnchor.constraint(equalToConstant: 18),
            clearMarkupButton.heightAnchor.constraint(equalToConstant: 18),
            sendButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            sendButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 18),
            sendButton.heightAnchor.constraint(equalToConstant: 18),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionFlagChanged(_:)),
            name: .quickShowSessionFlagChanged,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Show or hide the "session ended" badge. When shown, the HUD is
    /// orphaned: the sidecar has disconnected and didn't reconnect
    /// within the grace window.
    func setSessionEnded(_ ended: Bool) {
        badgeView.isHidden = !ended
        badgeView.stringValue = ended ? "● session ended" : ""
    }

    /// Bind this title bar to its owning session. Required for the
    /// armed-flag observer to filter notifications correctly.
    func setOwningSessionId(_ id: String) {
        owningSessionId = id
    }

    /// Show or hide the markup + send buttons. Called by the host HUD
    /// (a) synchronously right after `setOwningSessionId` to pick up
    /// the initial flag state, and (b) from `handleSessionFlagChanged`
    /// when the flag flips at runtime.
    func setArmed(_ on: Bool) {
        armed = on
        markupButton.isHidden = !on
        sendButton.isHidden = !on
        refreshClearButtonVisibility()
    }

    /// Reflect whether the active panel has any strokes. Called by
    /// the host HUD on every overlay change + tab switch so the clear
    /// button can vanish when there's nothing to clear.
    func setHasStrokes(_ has: Bool) {
        hasStrokes = has
        refreshClearButtonVisibility()
    }

    private func refreshClearButtonVisibility() {
        clearMarkupButton.isHidden = !(armed && hasStrokes)
    }

    /// Reflect the host HUD's draw-mode state so the markup pencil
    /// shows an "active" tint while drawing.
    func setDrawModeActive(_ active: Bool) {
        drawModeActive = active
        markupButton.contentTintColor = active
            ? .controlAccentColor
            : .secondaryLabelColor
    }

    @objc private func handleSessionFlagChanged(_ note: Notification) {
        guard let info = note.userInfo as? [String: Any],
              let session = info["sessionId"] as? String,
              session == owningSessionId,
              let key = info["key"] as? String,
              key == "markup_events_armed" else { return }
        // Re-pull via the host so the source of truth stays one place.
        if let host = window as? HUDWindow {
            host.syncArmedFromSession()
        }
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

    @objc private func handleMarkup() {
        onToggleDrawMode?()
    }

    @objc private func handleSend() {
        onSend?()
    }

    @objc private func handleClearMarkup() {
        onClearMarkup?()
    }

    // MARK: - Test affordances
    //
    // These let the QUICKSHOW_TEST_MARKUP_UI smoke assert on the
    // armed-flag visibility race + drive a real Send click without
    // synthesizing an NSEvent.

    var isSendButtonVisibleForTest: Bool { !sendButton.isHidden }
    var isMarkupButtonVisibleForTest: Bool { !markupButton.isHidden }

    /// Programmatic Send click — exercises the same action selector
    /// the user's click would fire.
    func performSendForTest() {
        sendButton.performClick(nil)
    }
}
