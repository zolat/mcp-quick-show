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
    static let maxInitialSize = NSSize(width: 800, height: 1000)

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

    init(initialPosition: NSPoint? = nil) {
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
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

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

    /// Resize the window to fit the rendered content, capped at the
    /// initial-size limits. Keeps the top-right corner anchored so
    /// the cascade position doesn't drift on each update.
    func sizeToContent(width: Double, height: Double) {
        let chrome = TitleBarOverlay.height + (panelCount >= 2 ? TabStripView.height : 0)
        let targetWidth = min(max(CGFloat(width), 280), Self.maxInitialSize.width)
        let targetHeight = min(
            max(CGFloat(height) + chrome, 200),
            Self.maxInitialSize.height
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
