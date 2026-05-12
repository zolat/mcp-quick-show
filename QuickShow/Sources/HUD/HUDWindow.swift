import Cocoa

/// Borderless floating window. Always-on-top via `.floating` level,
/// cross-Space via `.canJoinAllSpaces + .fullScreenAuxiliary`.
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
    }

    private func configureWindow() {
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
        ]
        isMovableByWindowBackground = true
        hasShadow = true
        ignoresMouseEvents = false
        // Borderless NSWindow defaults to isReleasedWhenClosed = true,
        // which would dangle pointers when SessionManager holds the
        // window in `session.huds[idx].window` after a close. Mirror
        // PromotedWindow's pattern: lifetime is managed by the array.
        isReleasedWhenClosed = false
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
    /// title bar updates to show the active name.
    func setActivePanel(_ name: String) {
        guard rendererViews[name] != nil else { return }
        activePanelName = name
        for (n, v) in rendererViews {
            v.isHidden = (n != name)
        }
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
