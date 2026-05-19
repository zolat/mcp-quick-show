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
    /// Argument is the hex string (`"#d8392c"`). SessionManager
    /// forwards through `WebViewPanelRenderer.setMarkupColor(_:)` →
    /// `window.__qsMarkup.setColor(hex)`, which seeds `DEFAULT_COLOR`
    /// for subsequent strokes. Committed strokes keep their captured
    /// color (per-stroke fields persist in the JS canvas).
    var onPickMarkupColor: ((String) -> Void)?
    /// Symmetric counterpart for stroke weight in points.
    var onPickMarkupWeight: ((CGFloat) -> Void)?
    /// Fired when the user clicks the undo `↶` button. SessionManager
    /// forwards to `WebViewPanelRenderer.popLastStroke()`. The button's
    /// enabled state is gated on `hasStrokes` (re-used signal — no
    /// dedicated canUndo channel since we don't have batched undo).
    var onUndoMarkup: (() -> Void)?
    /// Fired when the user clicks the eraser button. Argument is the
    /// new erasing state (`true` = enter erase mode, `false` = back to
    /// draw mode). SessionManager forwards to
    /// `WebViewPanelRenderer.setMarkupTool("erase"/"draw")` which
    /// flips `currentTool` in `markup-canvas.js`.
    var onToggleEraser: ((Bool) -> Void)?
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
    private let eraserButton = TitleBarOverlay.symbolButton(
        "eraser.line.dashed", weight: .medium, ax: "Eraser")
    private let undoButton = TitleBarOverlay.symbolButton(
        "arrow.uturn.backward", weight: .medium, ax: "Undo last stroke")
    private let clearMarkupButton = TitleBarOverlay.symbolButton(
        "delete.left", weight: .medium, ax: "Clear markup strokes")
    private let sendButton = TitleBarOverlay.symbolButton(
        "paperplane.fill", weight: .bold, ax: "Send markup to agent")
    /// Sibling of `sendButton` parked in the idle bar's right cluster.
    /// Hidden by default — revealed for user-initiated HUDs where
    /// "share this with Claude" is the primary action and we don't want
    /// to force the user through draw mode to access it.
    private let idleSendButton = TitleBarOverlay.symbolButton(
        "paperplane.fill", weight: .bold, ax: "Share with Claude")
    private let badgeView = NSTextField(labelWithString: "")

    /// Containers for the two bar layouts. Both are pinned to the bar's
    /// leading/trailing/centerY edges; we toggle `isHidden` on each
    /// when `setMode(_:)` flips. Kept as properties so we don't have to
    /// rebuild them or chase them through the view hierarchy.
    private var idleContents: NSStackView!
    private var drawContents: NSStackView!

    /// Current stroke color (drives the color picker indicator). The
    /// picker's selection writes here and fires `onPickMarkupColor`;
    /// the JS-bridge wiring that makes the canvas actually draw in
    /// this color is a separate post-merge follow-up.
    private var currentColor: StrokeColor = .red
    private var currentWeight: StrokeWeight = .medium

    /// Popovers presenting the swatch / weight option grids. Created
    /// eagerly so they can be re-shown without rebuilding the VC.
    private let colorPopover = NSPopover()
    private let weightPopover = NSPopover()

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
    /// User-initiated HUDs (born in `SessionManager.userWindowsSessionID`)
    /// expose Send in the idle bar so the user doesn't have to enter
    /// draw mode just to share. Agent-panel HUDs leave this at the
    /// default `false` — their Send remains gated on
    /// `armed && drawing` exactly as before.
    private var alwaysShowSend: Bool = false
    /// Whether the active panel has any strokes drawn. Drives the
    /// clear button's visibility so it only shows when there's
    /// something to clear.
    private var hasStrokes: Bool = false
    /// Whether the eraser tool is currently active. Drives the
    /// eraser button's "active" background tint. Flipped by
    /// `handleEraser`; cleared automatically when the user picks a
    /// color (color pick = "draw with this", which is incompatible
    /// with erase mode).
    private var erasing: Bool = false

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
        // `isHidden = true` is set AFTER the parent stack is built — see
        // the "hide-after-stack" block below. NSStackView reads
        // `isHidden` on `init(views:)` with the default
        // `detachesHiddenViews = true`, which permanently detaches the
        // view from the arranged subviews even if you flip the flag
        // back later. Setting `detachesHiddenViews = false` afterwards
        // doesn't re-attach. So we hide AFTER the flag is in place.

        overflowButton.contentTintColor = Self.arthurTextMuted
        overflowButton.target = self
        overflowButton.action = #selector(handleOverflow)
        // Empty for now — once a third top-bar item earns its keep
        // (per-HUD opacity, pin-to-Space toggle), this hosts the menu.

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

        // Eraser button: layer-backed so we can paint a faint background
        // when active (the visual "you're in erase mode" hint). Toggles
        // `erasing` state and fires `onToggleEraser`.
        eraserButton.contentTintColor = Self.arthurTextMuted
        eraserButton.target = self
        eraserButton.action = #selector(handleEraser)
        eraserButton.wantsLayer = true
        eraserButton.layer?.cornerRadius = 5

        undoButton.contentTintColor = Self.arthurTextMuted
        undoButton.target = self
        undoButton.action = #selector(handleUndo)

        clearMarkupButton.contentTintColor = Self.arthurTextMuted
        clearMarkupButton.target = self
        clearMarkupButton.action = #selector(handleClearMarkup)
        // `isHidden = true` deferred until after the stack is set up
        // (see comment on markupButton above).

        // Send is the only labelled button in the bar — accent-filled pill
        // with a small `paperplane.fill` glyph + "Send" label. Highest
        // visual emphasis in the draw palette (it's the primary commit
        // point of the markup loop).
        sendButton.wantsLayer = true
        sendButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        sendButton.layer?.cornerRadius = 11
        sendButton.imagePosition = .imageLeading
        sendButton.imageHugsTitle = true
        // Use a smaller / less heavy glyph so it pairs visually with the
        // label rather than dominating it.
        let sendCfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        sendButton.image = NSImage(
            systemSymbolName: "paperplane.fill",
            accessibilityDescription: "Send markup to agent"
        )?.withSymbolConfiguration(sendCfg)
        sendButton.contentTintColor = .white
        sendButton.attributedTitle = NSAttributedString(
            string: "Send",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
        )
        sendButton.target = self
        sendButton.action = #selector(handleSend)

        // Idle-mode Send pill — same look + same handler as the draw-
        // mode Send, but parked in the idle bar's right cluster so user-
        // initiated HUDs can ship without forcing draw mode first.
        idleSendButton.wantsLayer = true
        idleSendButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        idleSendButton.layer?.cornerRadius = 11
        idleSendButton.imagePosition = .imageLeading
        idleSendButton.imageHugsTitle = true
        idleSendButton.image = NSImage(
            systemSymbolName: "paperplane.fill",
            accessibilityDescription: "Share with Claude"
        )?.withSymbolConfiguration(sendCfg)
        idleSendButton.contentTintColor = .white
        idleSendButton.attributedTitle = NSAttributedString(
            string: "Send",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
        )
        idleSendButton.target = self
        idleSendButton.action = #selector(handleSend)
        idleSendButton.toolTip = "Share with Claude (copies token to clipboard)"

        // --- Layout: two parallel stacks (idle + draw) pinned to the
        // same edges of the bar. `setMode(_:)` flips `isHidden` on each.
        //
        // Idle layout: [ title (greedy) | badge | ⇩ | ✏︎ | ⋯ ✕ ]
        // Draw layout: [ ← | ● ━ |    ...    | ↶ ⌫ | ✓ ]
        //
        // 10pt group gutter on the outer level, 2pt intra-group spacing
        // for clusters that read as one unit.

        let idleRightGroup = NSStackView(views: [idleSendButton, overflowButton, closeButton])
        idleRightGroup.orientation = .horizontal
        idleRightGroup.alignment = .centerY
        idleRightGroup.spacing = 6
        idleRightGroup.detachesHiddenViews = false
        idleRightGroup.setCustomSpacing(8, after: idleSendButton)

        // Flex spacer between the markup toggle and the right cluster.
        // NSStackView's default `.fill` distribution doesn't actually pin
        // the rightmost child to the trailing edge — we need a view with
        // the lowest hugging priority to soak up slack. Without this the
        // close button drifts inward as soon as title + visible icons
        // total less than the bar's width.
        let idleSpacer = NSView()
        idleSpacer.translatesAutoresizingMaskIntoConstraints = false
        idleSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        idleSpacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        idleContents = NSStackView(views: [
            titleLabel, badgeView, snapshotButton, markupButton, idleSpacer, idleRightGroup,
        ])
        idleContents.orientation = .horizontal
        idleContents.alignment = .centerY
        idleContents.spacing = 10
        idleContents.detachesHiddenViews = false
        idleContents.translatesAutoresizingMaskIntoConstraints = false
        idleContents.setCustomSpacing(6, after: titleLabel)
        idleContents.setCustomSpacing(8, after: badgeView)

        // Hide-after-stack: now that the parent stacks have
        // `detachesHiddenViews = false`, it's safe to mark these
        // buttons hidden — they'll stay in the arranged-subviews list
        // and reappear cleanly when `setArmed(true)` / `setHasStrokes`
        // flip them back on.
        markupButton.isHidden = true       // revealed by setArmed
        overflowButton.isHidden = true     // empty until a third item exists
        clearMarkupButton.isHidden = true  // revealed by setHasStrokes
        idleSendButton.isHidden = true     // revealed by setAlwaysShowSend

        let drawToolsGroup = NSStackView(views: [
            colorPickerButton, weightPickerButton, eraserButton,
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
            eraserButton.widthAnchor.constraint(equalToConstant: buttonSize),
            eraserButton.heightAnchor.constraint(equalToConstant: buttonSize),
            undoButton.widthAnchor.constraint(equalToConstant: buttonSize),
            undoButton.heightAnchor.constraint(equalToConstant: buttonSize),
            clearMarkupButton.widthAnchor.constraint(equalToConstant: buttonSize),
            clearMarkupButton.heightAnchor.constraint(equalToConstant: buttonSize),
            sendButton.widthAnchor.constraint(equalToConstant: 58),
            sendButton.heightAnchor.constraint(equalToConstant: buttonSize),
            idleSendButton.widthAnchor.constraint(equalToConstant: 58),
            idleSendButton.heightAnchor.constraint(equalToConstant: buttonSize),
        ])

        // Pickers — content view controllers are reused across opens.
        let colorVC = ColorPickerViewController(
            initial: currentColor,
            onSelect: { [weak self] color in
                self?.applyColor(color)
                self?.colorPopover.performClose(nil)
            }
        )
        colorPopover.contentViewController = colorVC
        colorPopover.behavior = .transient
        colorPopover.appearance = NSAppearance(named: .darkAqua)

        let weightVC = WeightPickerViewController(
            initial: currentWeight,
            onSelect: { [weak self] weight in
                self?.applyWeight(weight)
                self?.weightPopover.performClose(nil)
            }
        )
        weightPopover.contentViewController = weightVC
        weightPopover.behavior = .transient
        weightPopover.appearance = NSAppearance(named: .darkAqua)

        // Initial indicator state — drives the symbol weight + tint to
        // match the (default) currentColor / currentWeight. Also seed
        // the stroke-dependent buttons (undo dim, clear hidden) since
        // hasStrokes starts false.
        applyColor(currentColor)
        applyWeight(currentWeight)
        refreshStrokeDependentButtons()

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
        refreshStrokeDependentButtons()
    }

    /// Reflect whether the active panel has any strokes. Called by
    /// the host HUD on every overlay change + tab switch. Drives:
    /// (a) the clear button's visibility — vanishes when nothing
    /// to clear — and (b) the undo button's enabled state — stays
    /// visible but dims when no strokes to undo.
    func setHasStrokes(_ has: Bool) {
        hasStrokes = has
        refreshStrokeDependentButtons()
    }

    /// Show or hide the idle-mode Send pill. User-initiated HUDs
    /// (born under `SessionManager.userWindowsSessionID`) call this
    /// with `true` so the user can ship without forcing draw mode;
    /// agent-panel HUDs leave it `false`. Independent of `armed` and
    /// `setMode` — those still gate the draw-bar Send + markup pencil.
    func setAlwaysShowSend(_ on: Bool) {
        alwaysShowSend = on
        idleSendButton.isHidden = !on
    }

    /// Centralized gate for buttons whose meaning depends on
    /// `hasStrokes`. Clear is hidden entirely when no strokes;
    /// undo stays visible but goes muted + disabled (a permanent
    /// affordance with feedback rather than something that
    /// teleports in and out of the bar).
    private func refreshStrokeDependentButtons() {
        clearMarkupButton.isHidden = !hasStrokes
        undoButton.isEnabled = hasStrokes
        undoButton.contentTintColor = hasStrokes
            ? Self.arthurTextMuted
            : Self.arthurTextMuted.withAlphaComponent(0.35)
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
    /// Dismisses any open picker popover on transition so it doesn't
    /// linger pointing at a now-hidden trigger button.
    private func setMode(_ newMode: Mode) {
        mode = newMode
        idleContents.isHidden = (newMode != .idle)
        drawContents.isHidden = (newMode != .draw)
        if newMode == .idle {
            if colorPopover.isShown { colorPopover.performClose(nil) }
            if weightPopover.isShown { weightPopover.performClose(nil) }
        }
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
        toggle(popover: colorPopover, anchor: colorPickerButton)
    }

    @objc private func handleWeightPicker() {
        toggle(popover: weightPopover, anchor: weightPickerButton)
    }

    @objc private func handleUndo() {
        onUndoMarkup?()
    }

    @objc private func handleEraser() {
        setErasing(!erasing)
        onToggleEraser?(erasing)
    }

    /// Internal state-flip + visual refresh for the eraser button.
    /// Also called from `applyColor` to auto-deactivate when the user
    /// picks a swatch.
    private func setErasing(_ on: Bool) {
        erasing = on
        eraserButton.layer?.backgroundColor = on
            ? NSColor.white.withAlphaComponent(0.08).cgColor
            : NSColor.clear.cgColor
        eraserButton.contentTintColor = on
            ? .controlAccentColor
            : Self.arthurTextMuted
    }

    /// Toggle a popover anchored below its trigger button. Closing on
    /// re-click keeps the picker buttons behaving as toggles rather
    /// than re-presenting a fresh popover each click.
    private func toggle(popover: NSPopover, anchor: NSView) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        }
    }

    /// Persist the chosen color, refresh the trigger indicator, and
    /// notify SessionManager (→ JS bridge → `setColor`). If the
    /// eraser was active, picking a color implicitly returns to draw
    /// mode — selecting a color reads as "I want to draw with this",
    /// which is incompatible with erasing.
    private func applyColor(_ color: StrokeColor) {
        currentColor = color
        colorPickerButton.contentTintColor = color.nsColor
        if let vc = colorPopover.contentViewController as? ColorPickerViewController {
            vc.setActive(color)
        }
        if erasing {
            setErasing(false)
            onToggleEraser?(false)
        }
        onPickMarkupColor?(color.rawValue)
    }

    /// Persist the chosen weight + refresh the trigger indicator. The
    /// `minus` SF Symbol's weight tracks the choice (`.regular` →
    /// `.bold` → `.heavy`) so the button silhouette grows/shrinks
    /// with the user's selection. Wiring through to the actual
    /// stroke width on the canvas is the follow-up.
    private func applyWeight(_ weight: StrokeWeight) {
        currentWeight = weight
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: weight.symbolWeight)
        weightPickerButton.image = NSImage(
            systemSymbolName: "minus",
            accessibilityDescription: "Stroke weight"
        )?.withSymbolConfiguration(cfg)
        if let vc = weightPopover.contentViewController as? WeightPickerViewController {
            vc.setActive(weight)
        }
        onPickMarkupWeight?(weight.points)
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

    /// Programmatic open of the color picker popover — lets tests
    /// assert on the popover's content + presentation without
    /// synthesizing an NSEvent.
    func openColorPickerForTest() {
        handleColorPicker()
    }

    /// Programmatic open of the weight picker popover.
    func openWeightPickerForTest() {
        handleWeightPicker()
    }
}

// MARK: - Picker types

/// Four semantic stroke colors. Hex strings match the swatches in the
/// approved mockup and the eventual `markup-canvas.js` palette.
fileprivate enum StrokeColor: String, CaseIterable {
    case red    = "#d8392c"
    case green  = "#4ade80"
    case blue   = "#60a5fa"
    case yellow = "#fbbf24"

    /// Display label — used for the popover swatch tooltips.
    var label: String {
        switch self {
        case .red:    return "Red — fix"
        case .green:  return "Green — good"
        case .blue:   return "Blue — note"
        case .yellow: return "Yellow — caution"
        }
    }

    var nsColor: NSColor {
        let hex = rawValue.dropFirst()  // strip leading "#"
        var v: UInt64 = 0
        Scanner(string: String(hex)).scanHexInt64(&v)
        let r = CGFloat((v >> 16) & 0xFF) / 255.0
        let g = CGFloat((v >>  8) & 0xFF) / 255.0
        let b = CGFloat( v        & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }
}

/// Three stroke widths, in points. Matches the mockup's thin / medium
/// / thick triplet. The medium 3pt value mirrors
/// `markup-canvas.js`'s current `DEFAULT_WIDTH`.
fileprivate enum StrokeWeight: CGFloat, CaseIterable {
    case thin   = 1.5
    case medium = 3.0
    case thick  = 5.0

    var points: CGFloat { rawValue }

    /// SF Symbol weight that produces a `minus` glyph at roughly the
    /// matching visual thickness. Approximate — SF Symbol weights
    /// don't map exactly to stroke widths, but the trio reads as
    /// three distinct line thicknesses.
    var symbolWeight: NSFont.Weight {
        switch self {
        case .thin:   return .regular
        case .medium: return .bold
        case .thick:  return .black
        }
    }

    var label: String {
        switch self {
        case .thin:   return "Thin (1.5pt)"
        case .medium: return "Medium (3pt)"
        case .thick:  return "Thick (5pt)"
        }
    }
}

// MARK: - Swatch + weight option views (popover content)

/// Single swatch in the color popover. Draws a filled 14pt circle
/// with an optional white ring when active.
fileprivate final class SwatchView: NSView {
    let color: StrokeColor
    var isActive: Bool = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    init(color: StrokeColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        toolTip = color.label
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let circle = NSRect(x: 4, y: 4, width: 14, height: 14)
        color.nsColor.setFill()
        NSBezierPath(ovalIn: circle).fill()
        if isActive {
            let ring = NSRect(x: 1, y: 1, width: 20, height: 20)
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let path = NSBezierPath(ovalIn: ring)
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// Single stroke-weight option in the weight popover. Draws a
/// horizontal sample at the given weight. Faint background when
/// active.
fileprivate final class WeightOptionView: NSView {
    let weight: StrokeWeight
    var isActive: Bool = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    init(weight: StrokeWeight) {
        self.weight = weight
        super.init(frame: NSRect(x: 0, y: 0, width: 44, height: 22))
        toolTip = weight.label
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 44),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isActive {
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        let path = NSBezierPath()
        let y = bounds.midY
        path.move(to: NSPoint(x: 10, y: y))
        path.line(to: NSPoint(x: bounds.width - 10, y: y))
        path.lineWidth = weight.points
        path.lineCapStyle = .round
        // Match the bar's muted icon tint so the sample reads as a
        // neutral preview rather than as the active stroke color.
        NSColor(red: 168/255.0, green: 169/255.0, blue: 158/255.0, alpha: 1.0).setStroke()
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

// MARK: - Picker view controllers

fileprivate final class ColorPickerViewController: NSViewController {
    private let onSelect: (StrokeColor) -> Void
    private var swatchViews: [SwatchView] = []

    init(initial: StrokeColor, onSelect: @escaping (StrokeColor) -> Void) {
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
        loadSwatches(active: initial)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func loadSwatches(active: StrokeColor) {
        let container = NSView()
        let stack = NSStackView(views: StrokeColor.allCases.map { color in
            let v = SwatchView(color: color)
            v.isActive = (color == active)
            v.onClick = { [weak self] in self?.onSelect(color) }
            swatchViews.append(v)
            return v
        })
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        // 4 swatches × 22 + 3 × 6 gap + 10+10 insets = 128 wide,
        // 22 + 8+8 = 38 tall. NSPopover sizes itself to this hint —
        // without it, the popover defaults to ~50pt and crushes
        // the swatches into the left edge.
        preferredContentSize = NSSize(width: 128, height: 38)
    }

    func setActive(_ color: StrokeColor) {
        for v in swatchViews { v.isActive = (v.color == color) }
    }
}

fileprivate final class WeightPickerViewController: NSViewController {
    private let onSelect: (StrokeWeight) -> Void
    private var optionViews: [WeightOptionView] = []

    init(initial: StrokeWeight, onSelect: @escaping (StrokeWeight) -> Void) {
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
        loadOptions(active: initial)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func loadOptions(active: StrokeWeight) {
        let container = NSView()
        let stack = NSStackView(views: StrokeWeight.allCases.map { weight in
            let v = WeightOptionView(weight: weight)
            v.isActive = (weight == active)
            v.onClick = { [weak self] in self?.onSelect(weight) }
            optionViews.append(v)
            return v
        })
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        // 44 wide + 8+8 insets = 60, 3 × 22 + 2 × 4 gap + 8+8 = 82.
        preferredContentSize = NSSize(width: 60, height: 82)
    }

    func setActive(_ weight: StrokeWeight) {
        for v in optionViews { v.isActive = (v.weight == weight) }
    }
}
