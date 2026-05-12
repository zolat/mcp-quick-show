import Cocoa

/// Borderless floating window. Always-on-top via `.floating` level,
/// cross-Space via `.canJoinAllSpaces + .fullScreenAuxiliary`.
/// Lifted-from-and-simplified from PipAnything's `OverlayWindow`.
@MainActor
final class HUDWindow: NSWindow {
    // Initial size for a fresh HUD before content-aware resize lands.
    static let defaultSize = NSSize(width: 480, height: 360)
    static let maxInitialSize = NSSize(width: 800, height: 1000)

    /// The renderer's view, sized to fill the window's content rect
    /// (minus the resize grip's overlap area at the bottom-right).
    private let contentHost = NSView()
    private let titleBar = TitleBarOverlay()
    let resizeHandle = ResizeHandle()

    /// The currently-installed renderer view. Replaced when the panel's
    /// content_type changes; nil if no renderer attached yet.
    private(set) var rendererView: NSView?

    var onCloseRequested: (() -> Void)?

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
        // Cross-Space + fullscreen-aux: visible from every Space and
        // from inside another app's fullscreen presentation.
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
        ]
        isMovableByWindowBackground = true
        hasShadow = true
        ignoresMouseEvents = false
        // Borderless windows default to `canBecomeKey = false`, which
        // prevents interactive elements (link clicks, code-copy
        // buttons in Phase 1+) from receiving focus. Allowing key
        // status here lets the WKWebView handle events natively.
        // (Subclass override needed because NSWindow's getters can't
        // be set on borderless windows directly.)
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

        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(resizeHandle)
        NSLayoutConstraint.activate([
            resizeHandle.widthAnchor.constraint(equalToConstant: ResizeHandle.size),
            resizeHandle.heightAnchor.constraint(equalToConstant: ResizeHandle.size),
            resizeHandle.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    /// Install a renderer's view as the panel content. If an older
    /// view is present, it's removed first.
    func installRendererView(_ view: NSView, name: String) {
        rendererView?.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentHost.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
        rendererView = view
        titleBar.setTitle(name)
    }

    func setPanelName(_ name: String) {
        titleBar.setTitle(name)
    }

    /// Resize the window to fit the rendered content, capped at the
    /// initial-size limits. Keeps the top-right corner anchored so
    /// the cascade position doesn't drift on each update.
    func sizeToContent(width: Double, height: Double) {
        let targetWidth = min(max(CGFloat(width), 280), Self.maxInitialSize.width)
        // +titleBar height because content height doesn't include the chrome.
        let targetHeight = min(
            max(CGFloat(height) + TitleBarOverlay.height, 200),
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
    /// offset per HUD index. Phase 3 wires the index to the session
    /// count.
    static func cascadeTopRight(_ index: Int) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let offset: CGFloat = CGFloat(index) * 24
        // Place the *initial* top-right of the HUD at the cascaded point.
        // `sizeToContent` later keeps the top-right anchored, so the
        // visual top-right is the cascade anchor.
        let x = visible.maxX - defaultSize.width - 16 - offset
        let y = visible.maxY - defaultSize.height - 16 - offset
        return NSPoint(x: x, y: y)
    }
}
