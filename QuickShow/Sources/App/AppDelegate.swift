import Cocoa

// Bootstrap. Owns the top-level orchestrators. Phase 0: only the
// control server. Phase 1 adds RendererRegistry + first HUDWindow.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controlServer: ControlServer?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenuBarItem()
        startControlServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controlServer?.stop()
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
