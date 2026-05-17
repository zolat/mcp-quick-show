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
    /// Fired when the user picks a stroke color from the popover.
    /// Argument is the hex string (`"#d8392c"`). No-op for now — the
    /// markup-canvas JS bridge wiring is a follow-up; this slot just
    /// exists so SessionManager can bind ahead of time.
    var onPickMarkupColor: ((String) -> Void)?
    /// Fired when the user picks a stroke weight from the popover.
    /// Argument is the line width in points. Same "no wiring yet"
    /// caveat as `onPickMarkupColor`.
    var onPickMarkupWeight: ((CGFloat) -> Void)?
    /// Fired when the user clicks the undo `↶` button. Wiring deferred
    /// — needs a `canUndo` JS→Swift channel before the button can
    /// honestly gate its enabled state. Slot in place for symmetry.
    var onUndoMarkup: (() -> Void)?
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

    /// Which bar layout is active. Flipped by `setDrawModeActive(_:)`
    /// from the host HUD. `.idle` shows title + snapshot + markup
    /// toggle + overflow + close. `.draw` swaps that for the markup
    /// palette (exit + color/weight pickers + undo + clear + Send).
    private enum Mode { case idle, draw }
    private var mode: Mode = .idle

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = TitleBarOverlay.symbolButton(
        "xmark", weight: .medium, ax: "Close")
    private let snapshotButton = TitleBarOverlay.symbolButton(
        "square.and.arrow.down", weight: .medium, ax: "Save snapshot")
    private let markupButton = TitleBarOverlay.symbolButton(
        "pencil.tip", weight: .medium, ax: "Toggle markup")
    private let overflowButton = TitleBarOverlay.symbolButton(
        "ellipsis", weight: .medium, ax: "More")
    private let exitDrawButton = TitleBarOverlay.symbolButton(
        "arrow.left", weight: .medium, ax: "Exit draw mode")
    private let colorPickerButton = TitleBarOverlay.symbolButton(
        "circle.fill", weight: .regular, ax: "Stroke color")
    private let weightPickerButton = TitleBarOverlay.symbolButton(
        "minus", weight: .bold, ax: "Stroke weight")
    private let undoButton = TitleBarOverlay.symbolButton(
        "arrow.uturn.backward", weight: .medium, ax: "Undo last stroke")
    private let clearMarkupButton = TitleBarOverlay.symbolButton(
        "delete.left", weight: .medium, ax: "Clear markup strokes")
    private let sendButton = TitleBarOverlay.symbolButton(
        "paperplane.fill", weight: .bold, ax: "Send markup to agent")
    private let badgeView = NSTextField(labelWithString: "")

    /// Containers for the two bar layouts. Both are pinned to the bar's
    /// leading/trailing/centerY edges; we toggle `isHidden` on each
    /// when `setMode(_:)` flips. Kept as properties so we don't have to
    /// rebuild them or chase them through the view hierarchy.
    private var idleContents: NSStackView!
    private var drawContents: NSStackView!

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
    /// Default stroke color shown by the color picker. Matches
    /// `markup-canvas.js`'s `DEFAULT_COLOR`. Lives here as a starting
    /// indicator until the picker selection becomes load-bearing.
    private static let defaultStrokeRed = NSColor(
        red: 216/255.0, green: 57/255.0, blue: 44/255.0, alpha: 1.0
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

        // --- Per-button config (target/action, tint, tooltip overrides).

        snapshotButton.contentTintColor = Self.arthurTextMuted
        snapshotButton.target = self
        snapshotButton.action = #selector(handleSnapshot)
        snapshotButton.toolTip = "Save snapshot to ~/Downloads"

        markupButton.contentTintColor = Self.arthurTextMuted
        markupButton.target = self
        markupButton.action = #selector(handleMarkup)
        markupButton.toolTip = "Toggle markup draw mode"
        markupButton.isHidden = true   // only revealed when armed

        overflowButton.contentTintColor = Self.arthurTextMuted
        overflowButton.target = self
        overflowButton.action = #selector(handleOverflow)
        // Empty for now — once a third top-bar item earns its keep
        // (per-HUD opacity, pin-to-Space toggle), this hosts the menu.
        overflowButton.isHidden = true

        closeButton.contentTintColor = Self.arthurTextMuted
        closeButton.target = self
        closeButton.action = #selector(handleClose)

        exitDrawButton.contentTintColor = Self.arthurTextMuted
        exitDrawButton.target = self
        exitDrawButton.action = #selector(handleMarkup)  // same toggle path

        // Default color = the existing stroke red `#d8392c`. Tint the
        // `circle.fill` symbol directly so the button reads as a colored
        // dot. Step 4 swaps this for a real `NSPopover` selection.
        colorPickerButton.contentTintColor = Self.defaultStrokeRed
        colorPickerButton.target = self
        colorPickerButton.action = #selector(handleColorPicker)

        // Weight picker shows the current stroke weight via the `minus`
        // SF Symbol. Bold weight gives a medium-thickness line — step 4
        // will pull a real popover and switch the symbol weight to track
        // the user's selection.
        weightPickerButton.contentTintColor = Self.arthurTextMuted
        weightPickerButton.target = self
        weightPickerButton.action = #selector(handleWeightPicker)

        undoButton.contentTintColor = Self.arthurTextMuted
        undoButton.target = self
        undoButton.action = #selector(handleUndo)

        clearMarkupButton.contentTintColor = Self.arthurTextMuted
        clearMarkupButton.target = self
        clearMarkupButton.action = #selector(handleClearMarkup)
        clearMarkupButton.isHidden = true   // depends on hasStrokes

        sendButton.contentTintColor = .controlAccentColor
        sendButton.target = self
        sendButton.action = #selector(handleSend)

        // --- Layout: two parallel stacks (idle + draw) pinned to the
        // same edges of the bar. `setMode(_:)` flips `isHidden` on each.
        //
        // Idle layout: [ title (greedy) | badge | ⇩ | ✏︎ | ⋯ ✕ ]
        // Draw layout: [ ← | ● ━ |    ...    | ↶ ⌫ | ✓ ]
        //
        // 10pt group gutter on the outer level, 2pt intra-group spacing
        // for clusters that read as one unit.

        let idleRightGroup = NSStackView(views: [overflowButton, closeButton])
        idleRightGroup.orientation = .horizontal
        idleRightGroup.alignment = .centerY
        idleRightGroup.spacing = 2
        idleRightGroup.detachesHiddenViews = false

        idleContents = NSStackView(views: [
            titleLabel, badgeView, snapshotButton, markupButton, idleRightGroup,
        ])
        idleContents.orientation = .horizontal
        idleContents.alignment = .centerY
        idleContents.spacing = 10
        idleContents.detachesHiddenViews = false
        idleContents.translatesAutoresizingMaskIntoConstraints = false
        idleContents.setCustomSpacing(6, after: titleLabel)
        idleContents.setCustomSpacing(8, after: badgeView)

        let drawToolsGroup = NSStackView(views: [
            colorPickerButton, weightPickerButton,
        ])
        drawToolsGroup.orientation = .horizontal
        drawToolsGroup.alignment = .centerY
        drawToolsGroup.spacing = 2

        let drawLeftGroup = NSStackView(views: [exitDrawButton, drawToolsGroup])
        drawLeftGroup.orientation = .horizontal
        drawLeftGroup.alignment = .centerY
        drawLeftGroup.spacing = 10

        let drawActionsGroup = NSStackView(views: [undoButton, clearMarkupButton])
        drawActionsGroup.orientation = .horizontal
        drawActionsGroup.alignment = .centerY
        drawActionsGroup.spacing = 2
        drawActionsGroup.detachesHiddenViews = false

        let drawRightGroup = NSStackView(views: [drawActionsGroup, sendButton])
        drawRightGroup.orientation = .horizontal
        drawRightGroup.alignment = .centerY
        drawRightGroup.spacing = 10

        // `equalSpacing` pushes the two children to the bar's edges; the
        // visual midline gap grows or shrinks with the window width.
        drawContents = NSStackView(views: [drawLeftGroup, drawRightGroup])
        drawContents.orientation = .horizontal
        drawContents.alignment = .centerY
        drawContents.distribution = .equalSpacing
        drawContents.translatesAutoresizingMaskIntoConstraints = false
        drawContents.isHidden = true   // idle is the default mode

        addSubview(idleContents)
        addSubview(drawContents)

        let buttonSize: CGFloat = 22
        NSLayoutConstraint.activate([
            idleContents.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            idleContents.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            idleContents.centerYAnchor.constraint(equalTo: centerYAnchor),

            drawContents.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            drawContents.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            drawContents.centerYAnchor.constraint(equalTo: centerYAnchor),

            snapshotButton.widthAnchor.constraint(equalToConstant: buttonSize),
            snapshotButton.heightAnchor.constraint(equalToConstant: buttonSize),
            markupButton.widthAnchor.constraint(equalToConstant: buttonSize),
            markupButton.heightAnchor.constraint(equalToConstant: buttonSize),
            overflowButton.widthAnchor.constraint(equalToConstant: buttonSize),
            overflowButton.heightAnchor.constraint(equalToConstant: buttonSize),
            closeButton.widthAnchor.constraint(equalToConstant: buttonSize),
            closeButton.heightAnchor.constraint(equalToConstant: buttonSize),

            exitDrawButton.widthAnchor.constraint(equalToConstant: buttonSize),
            exitDrawButton.heightAnchor.constraint(equalToConstant: buttonSize),
            colorPickerButton.widthAnchor.constraint(equalToConstant: buttonSize),
            colorPickerButton.heightAnchor.constraint(equalToConstant: buttonSize),
            weightPickerButton.widthAnchor.constraint(equalToConstant: buttonSize),
            weightPickerButton.heightAnchor.constraint(equalToConstant: buttonSize),
            undoButton.widthAnchor.constraint(equalToConstant: buttonSize),
            undoButton.heightAnchor.constraint(equalToConstant: buttonSize),
            clearMarkupButton.widthAnchor.constraint(equalToConstant: buttonSize),
            clearMarkupButton.heightAnchor.constraint(equalToConstant: buttonSize),
            sendButton.widthAnchor.constraint(equalToConstant: buttonSize),
            sendButton.heightAnchor.constraint(equalToConstant: buttonSize),
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

    /// Show or hide the markup-toggle button on the idle bar. The
    /// armed flag means "this session has the markup channel armed";
    /// without it the `✏︎` toggle has no path to a useful action so
    /// it stays hidden. Send + clear live on the draw-mode bar and
    /// are visibility-gated separately (`setMode`, `setHasStrokes`).
    /// Called by the host HUD (a) synchronously right after
    /// `setOwningSessionId` to pick up the initial flag state, and
    /// (b) from `handleSessionFlagChanged` when the flag flips at
    /// runtime.
    func setArmed(_ on: Bool) {
        armed = on
        markupButton.isHidden = !on
        refreshClearButtonVisibility()
    }

    /// Reflect whether the active panel has any strokes. Called by
    /// the host HUD on every overlay change + tab switch so the clear
    /// button can vanish when there's nothing to clear.
    func setHasStrokes(_ has: Bool) {
        hasStrokes = has
        refreshClearButtonVisibility()
    }

    /// Clear is meaningful only when the user has strokes to wipe.
    /// The button lives on the draw bar; idle mode never sees it
    /// regardless of `hasStrokes`, so we only need the strokes gate
    /// here — `armed` is implicit (no armed ⇒ no draw mode ⇒ no
    /// draw bar to show the button on).
    private func refreshClearButtonVisibility() {
        clearMarkupButton.isHidden = !hasStrokes
    }

    /// Reflect the host HUD's draw-mode state. The bar swaps its
    /// contents (idle → palette) rather than recoloring an icon.
    func setDrawModeActive(_ active: Bool) {
        drawModeActive = active
        setMode(active ? .draw : .idle)
    }

    /// Single chokepoint for the layout swap — flips `isHidden` on
    /// each container stack. Kept private; outside callers go through
    /// `setDrawModeActive(_:)` so the public surface stays small.
    private func setMode(_ newMode: Mode) {
        mode = newMode
        idleContents.isHidden = (newMode != .idle)
        drawContents.isHidden = (newMode != .draw)
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

    @objc private func handleOverflow() {
        // Placeholder. Wired in a follow-up once a permanent home for
        // per-HUD opacity / pin-to-Space / etc. earns its keep here.
    }

    @objc private func handleColorPicker() {
        // Placeholder. Step 4 swaps this for an `NSPopover` presenting
        // the swatch grid. Selection then fires `onPickMarkupColor`.
    }

    @objc private func handleWeightPicker() {
        // Placeholder. Step 4 swaps this for an `NSPopover` presenting
        // the three stroke samples. Selection fires `onPickMarkupWeight`.
    }

    @objc private func handleUndo() {
        onUndoMarkup?()
    }

    // MARK: - Test affordances
    //
    // These let the QUICKSHOW_TEST_MARKUP_UI smoke assert on the
    // armed-flag visibility race + drive a real Send click without
    // synthesizing an NSEvent.

    var isSendButtonVisibleForTest: Bool { !sendButton.isHidden && !drawContents.isHidden }
    var isMarkupButtonVisibleForTest: Bool { !markupButton.isHidden && !idleContents.isHidden }
    var isColorPickerVisibleForTest: Bool { !drawContents.isHidden }
    var isWeightPickerVisibleForTest: Bool { !drawContents.isHidden }

    /// Programmatic Send click — exercises the same action selector
    /// the user's click would fire.
    func performSendForTest() {
        sendButton.performClick(nil)
    }
}
