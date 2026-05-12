import Cocoa

/// Borderless floating window. Always-on-top via `.floating` level.
/// Space scoping is driven by `Settings.pinHudsToCurrentSpace`:
/// pinned = Space-bound (`.fullScreenAuxiliary`); unpinned = cross-
/// Space (`.canJoinAllSpaces + .fullScreenAuxiliary + .stationary`).
/// The window observes `Settings.pinHudsToCurrentSpaceChanged` and
/// re-applies `collectionBehavior` live.
/// Lifted-from-and-simplified from PipAnything's `OverlayWindow`.
///
/// Phase 3 update: multi-panel. The HUD holds N renderer views; the
/// `TabStripView` switches the visible one. Single-panel HUDs hide
/// the tab strip entirely.
@MainActor
final class HUDWindow: NSWindow {
    static let defaultSize = NSSize(width: 480, height: 360)
    /// Per-HUD size cap, captured at construction from `Settings.shared`
    /// so live HUDs aren't affected by mid-session pref changes.
    private let maxInitialSize: NSSize

    private let contentHost = NSView()
    private let titleBar = TitleBarOverlay()
    private let tabStrip = TabStripView()
    let resizeHandle = ResizeHandle()
    /// Markup drawing overlay — sits topmost in `contentHost`,
    /// `isHidden = true` by default so mouse events pass through to
    /// the active renderer view below. Visible while in draw mode.
    let markupOverlay = MarkupOverlayView()

    /// Currently-installed renderer views, keyed by panel name.
    /// At most one is visible at a time; the others are hidden in
    /// place so their state (scroll position, JS context) survives.
    private var rendererViews: [String: NSView] = [:]
    private(set) var activePanelName: String?

    /// Per-HUD draw-mode flag. `true` while the user is annotating;
    /// `false` is the normal mouse-passes-through state. Tear-out
    /// spawns new HUDs with this off.
    private(set) var isInDrawMode: Bool = false

    var onCloseRequested: (() -> Void)?
    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    /// Right-click handlers — supplied by `SessionManager` so the
    /// context menu's actions know which session + tab they apply to.
    var onTabContextMenu: ((String, NSEvent) -> Void)?
    var onHudContextMenu: ((NSEvent) -> Void)?
    /// Title-bar snapshot button (user story #30). Saves a fresh PNG
    /// of the active panel to ~/Downloads.
    var onSnapshotActivePanel: (() -> Void)?
    /// Tab drag-out (PRD user story #27). `TabPillView` fires this
    /// when the drag distance crosses the tear-out threshold.
    var onTearOutTab: ((String, NSEvent) -> Void)?
    /// Title-bar drag: SessionManager hooks these to detect drop
    /// targets for drag-to-reattach (the inverse of tear-out).
    var onTitleBarDragStart: (() -> Void)?
    var onTitleBarDragMove: ((NSPoint) -> Void)?
    var onTitleBarDragEnd: ((NSPoint) -> Void)?
    /// Markup pencil click in the title bar (visible only when the
    /// owning session is armed for markup events). Wired by
    /// SessionManager to call `toggleDrawMode()` on this HUD.
    var onToggleDrawMode: (() -> Void)?
    /// Send check-mark click in the title bar — fires the composite
    /// snapshot + `markup_sent` emission flow on the active panel.
    var onSendActivePanelMarkup: (() -> Void)?
    /// SessionManager owns the per-panel stroke array. The HUD calls
    /// these on tab switch / draw-mode toggle so strokes survive
    /// inactive tabs and tear-out/reattach.
    /// - `onCommitStrokes(panel, strokes)`: persist overlay → panel.
    /// - `onLoadStrokes(panel) -> [Stroke]`: read panel → overlay.
    var onCommitStrokes: ((String, [MarkupOverlayView.Stroke]) -> Void)?
    var onLoadStrokes: ((String) -> [MarkupOverlayView.Stroke])?
    /// Resolves the active panel's current WebView scroll position
    /// (CSS px) so the overlay can re-anchor existing strokes when
    /// the user switches tabs.
    var onResolveActivePanelScroll: ((String) -> NSPoint)?
    /// Reports the session's current `markup_events_armed` flag. Used
    /// by the title bar's flag-change observer to refresh button
    /// visibility without poking through SessionManager directly.
    var onResolveArmedFlag: (() -> Bool)?
    /// Reports draw-mode toggles to SessionManager so it can suspend
    /// or resume panzoom on the active renderer.
    var onDrawModeChanged: ((Bool) -> Void)?

    /// Bound by `SessionManager` so right-click handlers can find
    /// their owning session.
    var sessionId: String?
    /// Unique HUD identity within a session — referenced by menu
    /// payloads so opacity / close-all target the right window when
    /// a session has multiple sibling HUDs (post-Phase-3 tear-out).
    let hudInstanceId: UUID = UUID()

    init(initialPosition: NSPoint? = nil) {
        let settings = Settings.shared
        self.maxInitialSize = NSSize(
            width: CGFloat(settings.initialSizeCapWidth),
            height: CGFloat(settings.initialSizeCapHeight)
        )
        let frame = NSRect(
            origin: initialPosition ?? Self.cascadeTopRight(0),
            size: Self.defaultSize
        )
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Apply user-configured opacity. Captured at construction so
        // live HUDs keep their state; new HUDs reflect current prefs.
        alphaValue = CGFloat(settings.defaultOpacityPercent) / 100.0
        configureWindow()
        configureContentView()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePinToSpaceChanged),
            name: Settings.pinHudsToCurrentSpaceChanged,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func configureWindow() {
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = Self.collectionBehavior(forPinned: Settings.shared.pinHudsToCurrentSpace)
        isMovableByWindowBackground = true
        hasShadow = true
        ignoresMouseEvents = false
        // Borderless NSWindow defaults to isReleasedWhenClosed = true,
        // which would dangle pointers when SessionManager holds the
        // window in `session.huds[idx].window` after a close. Mirror
        // PromotedWindow's pattern: lifetime is managed by the array.
        isReleasedWhenClosed = false
    }

    /// Single source of truth for HUD Space scoping.
    /// `.stationary` is intentionally only set in the cross-Space
    /// variant — it means "don't follow Space switches" and is moot
    /// when the window is already pinned to one Space.
    static func collectionBehavior(forPinned pinned: Bool) -> NSWindow.CollectionBehavior {
        if pinned {
            return [.fullScreenAuxiliary]
        }
        return [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    @objc private func handlePinToSpaceChanged() {
        collectionBehavior = Self.collectionBehavior(forPinned: Settings.shared.pinHudsToCurrentSpace)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Intercept rightMouseDown at the window level — same trick as
    /// PipAnything's OverlayWindow. Routes the click to either the
    /// tab strip's right-click handler (if the cursor is over a pill)
    /// or the HUD's general right-click handler.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown {
            let locInWindow = event.locationInWindow
            // If the cursor is over a tab pill, dispatch the tab menu.
            if let pillName = pillNameAt(windowPoint: locInWindow) {
                onTabContextMenu?(pillName, event)
                return
            }
            onHudContextMenu?(event)
            return
        }
        super.sendEvent(event)
    }

    private func pillNameAt(windowPoint: NSPoint) -> String? {
        let local = tabStrip.convert(windowPoint, from: nil)
        guard tabStrip.bounds.contains(local) else { return nil }
        return tabStrip.pillName(at: local)
    }

    private func configureContentView() {
        guard let root = contentView else { return }
        root.wantsLayer = true
        root.layer?.cornerRadius = 8
        root.layer?.masksToBounds = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentHost)
        NSLayoutConstraint.activate([
            contentHost.topAnchor.constraint(equalTo: root.topAnchor, constant: TitleBarOverlay.height),
            contentHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        titleBar.translatesAutoresizingMaskIntoConstraints = false
        titleBar.onClose = { [weak self] in self?.onCloseRequested?() }
        titleBar.onSnapshot = { [weak self] in self?.onSnapshotActivePanel?() }
        titleBar.onDragStart = { [weak self] in self?.onTitleBarDragStart?() }
        titleBar.onDragMove = { [weak self] loc in self?.onTitleBarDragMove?(loc) }
        titleBar.onDragEnd = { [weak self] loc in self?.onTitleBarDragEnd?(loc) }
        titleBar.onToggleDrawMode = { [weak self] in self?.toggleDrawMode() }
        titleBar.onSend = { [weak self] in self?.onSendActivePanelMarkup?() }
        titleBar.onClearMarkup = { [weak self] in self?.clearActivePanelMarkup() }
        root.addSubview(titleBar)
        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: root.topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: TitleBarOverlay.height),
        ])

        // Tab strip sits below the title bar, above the content.
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        tabStrip.onSelect = { [weak self] name in self?.onSelectTab?(name) }
        tabStrip.onClose = { [weak self] name in self?.onCloseTab?(name) }
        tabStrip.onTearOut = { [weak self] name, event in self?.onTearOutTab?(name, event) }
        root.addSubview(tabStrip)
        NSLayoutConstraint.activate([
            tabStrip.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            tabStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            tabStrip.heightAnchor.constraint(equalToConstant: TabStripView.height),
        ])

        // Markup overlay sits inside `contentHost` as the topmost
        // subview — strictly above every renderer view installed via
        // `installPanel`. Hidden by default so mouse events fall
        // through to the active renderer.
        markupOverlay.translatesAutoresizingMaskIntoConstraints = false
        // Overlay is ALWAYS visible — its draw method paints nothing
        // when there are no strokes, and `isPassthrough = true`
        // routes mouse hit-testing to the renderer below. Draw mode
        // flips `isPassthrough` so the overlay starts capturing
        // input. Keeping it perpetually visible is what lets sent
        // strokes remain on screen as proof the Send action took.
        markupOverlay.isPassthrough = true
        markupOverlay.onStrokesChanged = { [weak self] in
            guard let self = self else { return }
            let strokes = self.markupOverlay.currentStrokes()
            self.titleBar.setHasStrokes(!strokes.isEmpty)
            if let active = self.activePanelName {
                self.onCommitStrokes?(active, strokes)
            }
        }
        markupOverlay.onEscape = { [weak self] in
            guard let self = self, self.isInDrawMode else { return }
            self.toggleDrawMode()
        }
        contentHost.addSubview(markupOverlay)
        NSLayoutConstraint.activate([
            markupOverlay.topAnchor.constraint(equalTo: contentHost.topAnchor),
            markupOverlay.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            markupOverlay.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            markupOverlay.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])

        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(resizeHandle)
        NSLayoutConstraint.activate([
            resizeHandle.widthAnchor.constraint(equalToConstant: ResizeHandle.size),
            resizeHandle.heightAnchor.constraint(equalToConstant: ResizeHandle.size),
            resizeHandle.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    /// Install a renderer's view as a new panel. If the name already
    /// has a view registered, replace it (caller used a different
    /// content_type for the same slot, e.g. user typoed). The newly
    /// installed view becomes active.
    func installPanel(name: String, view: NSView) {
        if let existing = rendererViews[name], existing !== view {
            existing.removeFromSuperview()
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        if view.superview == nil {
            // Insert below the markup overlay so the overlay stays
            // topmost regardless of how many panels we install.
            contentHost.addSubview(view, positioned: .below, relativeTo: markupOverlay)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: contentHost.topAnchor),
                view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            ])
        }
        rendererViews[name] = view
        setActivePanel(name)
    }

    /// Make `name` the visible panel; hide the others in place. The
    /// title bar updates to show the active name. Markup strokes for
    /// the outgoing panel are committed back to its store, and the
    /// new panel's strokes are loaded into the overlay so per-panel
    /// markup state survives tab switches.
    func setActivePanel(_ name: String) {
        guard rendererViews[name] != nil else { return }
        // Commit overlay state to the panel we're leaving before
        // swapping in the new panel's strokes.
        if let outgoing = activePanelName, outgoing != name {
            onCommitStrokes?(outgoing, markupOverlay.currentStrokes())
        }
        activePanelName = name
        for (n, v) in rendererViews {
            v.isHidden = (n != name)
        }
        let incomingStrokes = onLoadStrokes?(name) ?? []
        markupOverlay.loadStrokes(incomingStrokes)
        // Sync the overlay's scroll tracking to the new active
        // panel's WebView so the strokes render at the right
        // viewport positions against its current scroll state.
        let scroll = onResolveActivePanelScroll?(name) ?? .zero
        markupOverlay.setCurrentScroll(scroll)
        titleBar.setHasStrokes(!incomingStrokes.isEmpty)
        titleBar.setTitle(name)
    }

    /// Remove a panel's view from the HUD. If the closed panel was
    /// active, the caller is responsible for choosing the next active
    /// panel and calling `setActivePanel`.
    func removePanel(_ name: String) {
        rendererViews[name]?.removeFromSuperview()
        rendererViews.removeValue(forKey: name)
        if activePanelName == name {
            activePanelName = nil
        }
    }

    /// Number of installed panels.
    var panelCount: Int { rendererViews.count }

    /// Refresh the tab strip from the SessionManager's ordering.
    /// Single panel → hidden strip; multiple → all pills shown with
    /// the active one highlighted.
    func updateTabs(_ ordering: [String]) {
        tabStrip.update(panels: ordering.map {
            (name: $0, isActive: $0 == activePanelName)
        })
    }

    func setPanelName(_ name: String) {
        titleBar.setTitle(name)
    }

    /// Show or hide the "session ended" badge on the title bar.
    /// Called by the SessionManager when a sidecar disconnects past
    /// the reconnect-grace window, or when the same-UUID sidecar
    /// reconnects (cleared).
    func setSessionEnded(_ ended: Bool) {
        titleBar.setSessionEnded(ended)
    }

    /// Forwarder for the title-bar's armed-flag visibility. Called
    /// synchronously from SessionManager right after `sessionId` is
    /// bound, so the buttons reflect the *current* flag state even
    /// when the flag was armed before the HUD existed (the common
    /// case: sidecar calls `enable_markup_events` before its first
    /// `upsert`).
    func setArmed(_ armed: Bool) {
        titleBar.setArmed(armed)
    }

    /// Bind the title bar to its owning session id so its
    /// flag-change notification observer can filter to "our" session.
    func setOwningSessionId(_ id: String) {
        titleBar.setOwningSessionId(id)
    }

    /// Called by the title bar's notification observer when the
    /// `markup_events_armed` flag flips for *this* session. Resolves
    /// the new value through `onResolveArmedFlag` (which goes through
    /// SessionManager) so the source of truth stays one place.
    func syncArmedFromSession() {
        let armed = onResolveArmedFlag?() ?? false
        setArmed(armed)
        // Flipping armed -> false while in draw mode auto-exits so
        // strokes don't get stranded behind an invisible Send button.
        if !armed && isInDrawMode {
            toggleDrawMode()
        }
    }

    /// Test-only accessors mirroring `TitleBarOverlay`'s test hooks
    /// so the QUICKSHOW_TEST_MARKUP_UI smoke can assert visibility
    /// + click Send without poking at private state.
    var isSendButtonVisibleForTest: Bool { titleBar.isSendButtonVisibleForTest }
    var isMarkupButtonVisibleForTest: Bool { titleBar.isMarkupButtonVisibleForTest }
    func performSendForTest() { titleBar.performSendForTest() }

    /// Wipe the active panel's strokes — local UI escape hatch
    /// (no event emission). Triggered by the title-bar ⌫ button.
    /// `MarkupOverlayView.clear()` fires `onStrokesChanged`, which
    /// commits the empty array back to the Panel via SessionManager.
    func clearActivePanelMarkup() {
        markupOverlay.clear()
    }

    /// Flip draw-mode on/off. The overlay stays *visible* either
    /// way — what changes is whether it captures mouse events
    /// (`isPassthrough = false` when drawing, `true` otherwise so
    /// clicks hit the panel content). First-responder status moves
    /// to the overlay during draw mode so Cmd+Z / Esc reach it, and
    /// SessionManager gets notified to suspend/resume panzoom.
    func toggleDrawMode() {
        isInDrawMode.toggle()
        markupOverlay.isPassthrough = !isInDrawMode
        titleBar.setDrawModeActive(isInDrawMode)
        if isInDrawMode {
            makeFirstResponder(markupOverlay)
        } else if firstResponder === markupOverlay {
            makeFirstResponder(nil)
        }
        onDrawModeChanged?(isInDrawMode)
    }

    /// During a drag-to-reattach gesture (the inverse of tear-out),
    /// HUDs that would accept the drop highlight their chrome with
    /// an accent border. Called by `SessionManager.handleHudDragMove`.
    func setReattachHighlight(_ on: Bool) {
        guard let root = contentView else { return }
        root.layer?.borderWidth = on ? 2.5 : 0
        root.layer?.borderColor = on
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
    }

    /// Does the given screen-coord point land on this HUD's
    /// drop-target zone? Drop zone = the tab strip when visible, or
    /// the title bar (always). Used for drag-to-reattach detection.
    func containsDropPoint(_ screenPoint: NSPoint) -> Bool {
        // Title bar in screen coords — always part of the drop zone.
        let titleWindowFrame = titleBar.convert(titleBar.bounds, to: nil)
        let titleScreenFrame = convertToScreen(titleWindowFrame)
        if titleScreenFrame.contains(screenPoint) { return true }
        // Tab strip in screen coords — only when shown (≥2 panels).
        if !tabStrip.isHidden {
            let stripWindowFrame = tabStrip.convert(tabStrip.bounds, to: nil)
            let stripScreenFrame = convertToScreen(stripWindowFrame)
            if stripScreenFrame.contains(screenPoint) { return true }
        }
        return false
    }

    /// Resize the window to fit the rendered content, capped at the
    /// initial-size limits. Keeps the top-right corner anchored so
    /// the cascade position doesn't drift on each update.
    func sizeToContent(width: Double, height: Double) {
        let chrome = TitleBarOverlay.height + (panelCount >= 2 ? TabStripView.height : 0)
        let targetWidth = min(max(CGFloat(width), 280), maxInitialSize.width)
        let targetHeight = min(
            max(CGFloat(height) + chrome, 200),
            maxInitialSize.height
        )
        let current = self.frame
        let newOrigin = NSPoint(
            x: current.maxX - targetWidth,
            y: current.maxY - targetHeight
        )
        setFrame(
            NSRect(origin: newOrigin, size: NSSize(width: targetWidth, height: targetHeight)),
            display: true,
            animate: false
        )
    }

    // MARK: - Cascade positioning

    /// Top-right corner of the main screen, with a 24 pt cascade
    /// offset per HUD index.
    static func cascadeTopRight(_ index: Int) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let offset: CGFloat = CGFloat(index) * 24
        let x = visible.maxX - defaultSize.width - 16 - offset
        let y = visible.maxY - defaultSize.height - 16 - offset
        return NSPoint(x: x, y: y)
    }
}
