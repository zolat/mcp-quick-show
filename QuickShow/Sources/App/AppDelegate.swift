import Cocoa

// Bootstrap. Owns the top-level orchestrators. Phase 0: only the
// control server. Phase 1 adds RendererRegistry + first HUDWindow.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controlServer: ControlServer?
    private var statusItem: NSStatusItem?
    private(set) var sessionManager: SessionManager!
    private(set) var rendererRegistry: RendererRegistry!

    func applicationDidFinishLaunching(_ notification: Notification) {
        rendererRegistry = RendererRegistry.makeDefault()
        sessionManager = SessionManager(renderers: rendererRegistry)
        installMenuBarItem()
        startControlServer()
        if ProcessInfo.processInfo.environment["QUICKSHOW_AUTO_PANEL"] == "1" {
            runAutoPanelSmoke()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controlServer?.stop()
    }

    /// Headless smoke hook: open a fixture markdown panel at launch.
    /// Parallel to PipAnything's `PIP_AUTO_CAPTURE` family.
    private func runAutoPanelSmoke() {
        let fixture = """
        # QuickShow auto-panel smoke

        This is a **markdown** panel rendered on launch via
        `QUICKSHOW_AUTO_PANEL=1`.

        - tables, lists, code blocks all work
        - dark / light theme follows `prefers-color-scheme`

        ```swift
        let app = NSApplication.shared
        app.run()
        ```
        """
        Task {
            do {
                _ = try await sessionManager.upsert(
                    sessionId: "smoke-session",
                    name: "smoke",
                    contentType: "markdown",
                    form: "inline",
                    body: fixture
                )
                NSLog("QuickShow: auto-panel smoke rendered")
            } catch {
                NSLog("QuickShow: auto-panel smoke failed: \(error)")
            }
        }
    }

    private func installMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = "QS"
            button.toolTip = "QuickShow"
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "QuickShow v0.1", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        for sub in menu.items where sub.action == #selector(quit) {
            sub.target = self
        }
        item.menu = menu
        statusItem = item
    }

    private func startControlServer() {
        // Allow tests / parallel instances to override the socket path.
        let override = ProcessInfo.processInfo.environment["QUICKSHOW_SOCKET_PATH"]
        let server = ControlServer(socketPath: override ?? ControlServer.defaultSocketPath)
        server.appDelegate = self
        do {
            try server.start()
            controlServer = server
        } catch {
            NSLog("QuickShow: control server failed to start: \(error)")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
