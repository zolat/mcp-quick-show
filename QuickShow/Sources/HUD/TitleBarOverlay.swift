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
    static let height: CGFloat = 28

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
    private let closeButton = TitleBarOverlay.symbolButton(
        "xmark", weight: .medium, ax: "Close")
    private let snapshotButton = TitleBarOverlay.symbolButton(
        "square.and.arrow.down", weight: .medium, ax: "Save snapshot")
    private let markupButton = TitleBarOverlay.symbolButton(
        "pencil.tip", weight: .medium, ax: "Toggle markup")
    private let clearMarkupButton = TitleBarOverlay.symbolButton(
        "delete.left", weight: .medium, ax: "Clear markup strokes")
    private let sendButton = TitleBarOverlay.symbolButton(
        "paperplane.fill", weight: .bold, ax: "Send markup to agent")
    private let badgeView = NSTextField(labelWithString: "")

    /// SF-Symbol-backed icon button — used for every action button in the
    /// bar. Borderless, image-only, tintable via `contentTintColor`. Symbol
    /// rendered at 13pt so it fits comfortably in the current 18pt button
    /// (and the planned 22pt button in step 2 of the revamp). First SF
    /// Symbol usage in the app — `NSImage(systemSymbolName:)` is macOS 11+,
    /// well below our 13.0 deployment target.
    private static func symbolButton(
        _ name: String,
        weight: NSFont.Weight,
        ax: String
    ) -> NSButton {
        let btn = NSButton(title: "", target: nil, action: nil)
        btn.isBordered = false
        btn.imagePosition = .imageOnly
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: weight)
        btn.image = NSImage(systemSymbolName: name, accessibilityDescription: ax)?
            .withSymbolConfiguration(cfg)
        btn.toolTip = ax
        return btn
    }
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

    /// Arthur "elevated" surface — sits one step above the contentHost
    /// background (#1c1c1c). Hex matches the style guide's `elevated`
    /// token; full opacity for now since the top-bar rework is roadmap.
    private static let arthurElevated = NSColor(
        red:  42/255.0, green: 38/255.0, blue: 32/255.0, alpha: 1.0
    )
    /// Arthur `text-muted` — soft sage-gray for icons + the panel name.
    private static let arthurTextMuted = NSColor(
        red: 168/255.0, green: 169/255.0, blue: 158/255.0, alpha: 1.0
    )

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Self.height))
        wantsLayer = true
        layer?.backgroundColor = Self.arthurElevated.cgColor
        layer?.cornerRadius = 6

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = Self.arthurTextMuted
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.font = .systemFont(ofSize: 10, weight: .medium)
        badgeView.textColor = .systemRed
        badgeView.isHidden = true

        snapshotButton.contentTintColor = Self.arthurTextMuted
        snapshotButton.target = self
        snapshotButton.action = #selector(handleSnapshot)
        snapshotButton.toolTip = "Save snapshot to ~/Downloads"

        // Markup, Clear, and Send live between snapshot and close.
        // Markup + Send appear when `setArmed(true)` reveals them; the
        // Clear button additionally requires strokes to exist — it'd
        // be visual noise as a perpetual no-op.
        markupButton.contentTintColor = Self.arthurTextMuted
        markupButton.target = self
        markupButton.action = #selector(handleMarkup)
        markupButton.toolTip = "Toggle markup draw mode"
        markupButton.isHidden = true

        clearMarkupButton.contentTintColor = Self.arthurTextMuted
        clearMarkupButton.target = self
        clearMarkupButton.action = #selector(handleClearMarkup)
        clearMarkupButton.isHidden = true

        sendButton.contentTintColor = .controlAccentColor
        sendButton.target = self
        sendButton.action = #selector(handleSend)
        sendButton.isHidden = true

        closeButton.contentTintColor = Self.arthurTextMuted
        closeButton.target = self
        closeButton.action = #selector(handleClose)

        // Markup cluster: 2pt internal spacing so the three buttons read
        // as one unit. `detachesHiddenViews = false` keeps hidden buttons
        // occupying their slot so the bar doesn't reflow when the armed
        // flag flips — same behaviour the old explicit-constraint chain
        // gave us.
        let markupGroup = NSStackView(views: [
            markupButton, clearMarkupButton, sendButton,
        ])
        markupGroup.orientation = .horizontal
        markupGroup.alignment = .centerY
        markupGroup.spacing = 2
        markupGroup.detachesHiddenViews = false
        markupGroup.translatesAutoresizingMaskIntoConstraints = false

        // Outer chain: title (greedy) → badge → snapshot → markup group →
        // close. 10pt group gutter; tighter custom spacing inside the
        // title+badge pair to keep the orphaned-session indicator close
        // to the panel name.
        let outerStack = NSStackView(views: [
            titleLabel, badgeView, snapshotButton, markupGroup, closeButton,
        ])
        outerStack.orientation = .horizontal
        outerStack.alignment = .centerY
        outerStack.spacing = 10
        outerStack.detachesHiddenViews = false
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        outerStack.setCustomSpacing(6, after: titleLabel)
        outerStack.setCustomSpacing(8, after: badgeView)
        addSubview(outerStack)

        let buttonSize: CGFloat = 22
        NSLayoutConstraint.activate([
            outerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            outerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            outerStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            snapshotButton.widthAnchor.constraint(equalToConstant: buttonSize),
            snapshotButton.heightAnchor.constraint(equalToConstant: buttonSize),
            markupButton.widthAnchor.constraint(equalToConstant: buttonSize),
            markupButton.heightAnchor.constraint(equalToConstant: buttonSize),
            clearMarkupButton.widthAnchor.constraint(equalToConstant: buttonSize),
            clearMarkupButton.heightAnchor.constraint(equalToConstant: buttonSize),
            sendButton.widthAnchor.constraint(equalToConstant: buttonSize),
            sendButton.heightAnchor.constraint(equalToConstant: buttonSize),
            closeButton.widthAnchor.constraint(equalToConstant: buttonSize),
            closeButton.heightAnchor.constraint(equalToConstant: buttonSize),
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
            : Self.arthurTextMuted
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
