import Cocoa

/// Borderless floating window. Always-on-top via `.floating` level.
/// Space scoping is driven by `Settings.hudSpacePolicy`:
///   .userSpace / .claudeSpace → `.fullScreenAuxiliary` (Space-bound)
///   .allSpaces                → `.canJoinAllSpaces + .fullScreenAuxiliary + .stationary`
/// `.claudeSpace` differs from `.userSpace` only in *where* the window
/// is first placed — `SessionManager` calls `SpaceResolver` to nudge
/// new HUDs onto the terminal's Space. Both modes use the same
/// `CollectionBehavior` because once a window is on a Space, the same
/// rules govern visibility.
/// The window observes `Settings.hudSpacePolicyChanged` and re-applies
/// `collectionBehavior` live.
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
    /// owning session is armed for markup events). Routes through the
    /// HUD's own `toggleDrawMode()` so the title-bar tint flips in
    /// step with the renderer's draw-mode state.
    var onToggleDrawMode: (() -> Void)?
    /// Send check-mark click — fires the full-doc WebView snapshot
    /// (canvas pixels included) + `markup_sent` emission flow.
    var onSendActivePanelMarkup: (() -> Void)?
    /// Clear ⌫ click — wipes the active panel's strokes both Swift-
    /// side and in the WebView's in-DOM canvas.
    var onClearActivePanelMarkup: (() -> Void)?
    /// Color picker selection in the title bar. Argument is the hex
    /// string (`"#d8392c"` etc.). Forwarded to SessionManager →
    /// `WebViewPanelRenderer.setMarkupColor(_:)` which seeds the
    /// active panel's canvas with the new default stroke color.
    var onPickMarkupColor: ((String) -> Void)?
    /// Stroke-weight picker selection. Argument is the line width in
    /// points; symmetric with `onPickMarkupColor`.
    var onPickMarkupWeight: ((CGFloat) -> Void)?
    /// Undo `↶` click — pops the last stroke from the active panel
    /// via `WebViewPanelRenderer.popLastStroke()`. The button's
    /// enabled state is gated on `hasStrokes` (re-used signal — no
    /// dedicated canUndo channel since we don't have batched undo
    /// history).
    var onUndoMarkup: (() -> Void)?
    /// Eraser button toggle. Argument is the new erasing state.
    /// Forwarded to `WebViewPanelRenderer.setMarkupTool("erase" / "draw")`.
    var onToggleEraser: ((Bool) -> Void)?
    /// Fired by `toggleDrawMode()` with the new state. SessionManager
    /// translates this into `enterDrawMode()` / `exitDrawMode()`
    /// calls on the active panel's renderer.
    var onDrawModeChanged: ((Bool) -> Void)?
    /// Returns `true` if the active panel has no strokes — used by
    /// `setActivePanel` to refresh the ⌫ button visibility on tab
    /// switch.
    var onResolveActiveStrokesEmpty: (() -> Bool)?
    /// Reports the session's current `markup_events_armed` flag. Used
    /// by the title bar's flag-change observer to refresh button
    /// visibility without poking through SessionManager directly.
    var onResolveArmedFlag: (() -> Bool)?

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
            selector: #selector(handleSpacePolicyChanged),
            name: Settings.hudSpacePolicyChanged,
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
        collectionBehavior = Self.collectionBehavior(forPolicy: Settings.shared.hudSpacePolicy)
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
    /// `.userSpace` and `.claudeSpace` use the same behaviour
    /// (`.fullScreenAuxiliary`) — the difference is the placement
    /// step run by `SessionManager` on first create. `.stationary` is
    /// intentionally only set in the cross-Space variant — it means
    /// "don't follow Space switches" and is moot when the window is
    /// already bound to one Space.
    static func collectionBehavior(forPolicy policy: HudSpacePolicy) -> NSWindow.CollectionBehavior {
        switch policy {
        case .userSpace:
            return [.fullScreenAuxiliary]
        case .claudeSpace:
            // No `.fullScreenAuxiliary` here — that flag couples the
            // window to whatever Space hosts the current full-screen
            // presentation, which fights `CGSMoveWindowsToManagedSpace`
            // (AppKit re-asserts the active Space after orderFront).
            // `.managed` default behaviour is exactly what we want:
            // window stays on whichever Space it was last placed on.
            return []
        case .allSpaces:
            return [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        }
    }

    @objc private func handleSpacePolicyChanged() {
        collectionBehavior = Self.collectionBehavior(forPolicy: Settings.shared.hudSpacePolicy)
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

        // Arthur palette: warm dark grey (#1c1c1c) behind the canvas,
        // so the rendered content sits on a deliberate "stage"
        // background instead of the system window color.
        contentHost.wantsLayer = true
        contentHost.layer?.backgroundColor = NSColor(
            red:  28/255.0,
            green: 28/255.0,
            blue: 28/255.0,
            alpha: 1.0
        ).cgColor
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
        titleBar.onClearMarkup = { [weak self] in self?.onClearActivePanelMarkup?() }
        titleBar.onPickMarkupColor = { [weak self] hex in self?.onPickMarkupColor?(hex) }
        titleBar.onPickMarkupWeight = { [weak self] pts in self?.onPickMarkupWeight?(pts) }
        titleBar.onUndoMarkup = { [weak self] in self?.onUndoMarkup?() }
        titleBar.onToggleEraser = { [weak self] erasing in self?.onToggleEraser?(erasing) }
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

        // Markup is now drawn into a transparent <canvas> injected
        // into every WebView by `markup-canvas.js`. The HUD itself
        // doesn't need a Swift-side overlay anymore — strokes are
        // part of the WebView's DOM, scaling/panning with content
        // for free, captured by `takeSnapshot` natively. The HUD
        // just routes title-bar button clicks (✏︎ ⌫ ✓) into the
        // active renderer's JS bridge via SessionManager.

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
            contentHost.addSubview(view)
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
    /// title bar updates to show the active name. Per-panel markup
    /// state survives tab switches automatically — strokes live in
    /// each WebView's in-DOM canvas, which persists across hide/show.
    func setActivePanel(_ name: String) {
        guard rendererViews[name] != nil else { return }
        // If we were in draw mode on the outgoing panel, exit it so
        // the incoming panel doesn't inherit a stale draw-mode state.
        if isInDrawMode, activePanelName != name {
            toggleDrawMode()
        }
        activePanelName = name
        for (n, v) in rendererViews {
            v.isHidden = (n != name)
        }
        let activeEmpty = onResolveActiveStrokesEmpty?() ?? true
        titleBar.setHasStrokes(!activeEmpty)
        titleBar.setTitle(name)
    }

    /// Mirror the active panel's stroke state into the title bar so
    /// the ⌫ button visibility tracks reality. Called by SessionManager
    /// whenever strokes are added (via the JS bridge) or cleared.
    func setActivePanelHasStrokes(_ hasStrokes: Bool) {
        titleBar.setHasStrokes(hasStrokes)
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

    /// Flip draw-mode on/off. The actual capture happens inside the
    /// active panel's in-DOM canvas — SessionManager picks up the
    /// state change via `onDrawModeChanged` and calls the renderer's
    /// `enterDrawMode()` / `exitDrawMode()` JS bridge. The HUD only
    /// owns the visual title-bar tint state here.
    func toggleDrawMode() {
        isInDrawMode.toggle()
        titleBar.setDrawModeActive(isInDrawMode)
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
