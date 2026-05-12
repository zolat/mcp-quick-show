import Cocoa

/// Manages "promote to standard window" — detaching a panel from its
/// HUD and re-housing it in a regular titled `NSWindow` that
/// participates in Cmd-Tab and respects normal window-management
/// conventions.
///
/// Activation policy is toggled here:
///   - `.accessory` (default, LSUIElement) while only HUDs exist.
///   - `.regular` while ≥1 promoted window exists — so Cmd-Tab can
///     reach our promoted windows.
///   - Back to `.accessory` when the last promoted window closes.
@MainActor
final class PromoteToWindowController: NSObject, NSWindowDelegate {
    private var promotedWindows: [PromotedWindow] = []

    /// Promote a panel: move its renderer view from the HUD into a
    /// new standard window. The HUD loses that tab; if it was the
    /// last tab, the HUD itself closes.
    func promote(name: String,
                 sessionId: String,
                 detachFrom hud: HUDWindow,
                 view: NSView,
                 panelSize: NSSize,
                 onClose: @escaping () -> Void) {
        let promoted = PromotedWindow(
            name: name,
            sessionId: sessionId,
            rendererView: view,
            initialSize: panelSize,
            onClose: { [weak self, weak hud] win in
                self?.dismiss(win)
                onClose()
                _ = hud
            }
        )
        promoted.delegate = self
        promoted.makeKeyAndOrderFront(nil)
        promotedWindows.append(promoted)
        updateActivationPolicy()
    }

    func nonisolatedClose(_ win: NSWindow) {
        // Helper for delegates (the windowWillClose hook).
        promotedWindows.removeAll { $0 === win }
        updateActivationPolicy()
    }

    private func dismiss(_ win: PromotedWindow) {
        promotedWindows.removeAll { $0 === win }
        updateActivationPolicy()
    }

    private func updateActivationPolicy() {
        let want: NSApplication.ActivationPolicy = promotedWindows.isEmpty ? .accessory : .regular
        if NSApp.activationPolicy() != want {
            NSApp.setActivationPolicy(want)
        }
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? PromotedWindow else { return }
        Task { @MainActor in
            self.nonisolatedClose(win)
            win.fireOnClose()
        }
    }
}

/// Standard titled NSWindow that hosts a single renderer view.
/// Created exclusively by `PromoteToWindowController`.
@MainActor
final class PromotedWindow: NSWindow {
    let name: String
    let sessionId: String
    let rendererView: NSView
    var onCloseCallback: ((PromotedWindow) -> Void)?

    init(name: String,
         sessionId: String,
         rendererView: NSView,
         initialSize: NSSize,
         onClose: @escaping (PromotedWindow) -> Void) {
        self.name = name
        self.sessionId = sessionId
        self.rendererView = rendererView
        self.onCloseCallback = onClose
        super.init(
            contentRect: NSRect(
                origin: NSPoint(x: 200, y: 200),
                size: NSSize(
                    width: max(initialSize.width, 400),
                    height: max(initialSize.height, 300)
                )
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = name
        rendererView.translatesAutoresizingMaskIntoConstraints = false
        if let content = contentView {
            rendererView.removeFromSuperview()
            content.addSubview(rendererView)
            NSLayoutConstraint.activate([
                rendererView.topAnchor.constraint(equalTo: content.topAnchor),
                rendererView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                rendererView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                rendererView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        level = .normal       // Promoted windows are standard — not floating.
        isReleasedWhenClosed = false
    }

    func fireOnClose() {
        let cb = onCloseCallback
        onCloseCallback = nil
        cb?(self)
    }
}
