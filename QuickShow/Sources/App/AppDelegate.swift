import Cocoa

// Bootstrap. Owns the top-level orchestrators. Phase 0: only the
// control server. Phase 1 adds RendererRegistry + first HUDWindow.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controlServer: ControlServer?
    private var statusItem: NSStatusItem?
    private(set) var sessionManager: SessionManager!
    private(set) var rendererRegistry: RendererRegistry!
    private(set) var promoteController: PromoteToWindowController!
    private var settingsWindow: SettingsWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        rendererRegistry = RendererRegistry.makeDefault()
        sessionManager = SessionManager(renderers: rendererRegistry)
        promoteController = PromoteToWindowController()
        sessionManager.promoteController = promoteController
        installMenuBarItem()
        startControlServer()
        if ProcessInfo.processInfo.environment["QUICKSHOW_AUTO_PANEL"] == "1" {
            runAutoPanelSmoke()
        }
        if ProcessInfo.processInfo.environment["QUICKSHOW_TEST_PROMOTE"] == "1" {
            runPromoteSmoke()
        }
        if ProcessInfo.processInfo.environment["QUICKSHOW_TEST_PREFS"] == "1" {
            runPrefsSmoke()
        }
        if ProcessInfo.processInfo.environment["QUICKSHOW_TEST_TEAROUT"] == "1" {
            runTearOutSmoke()
        }
    }

    /// Headless tear-out test. Renders three panels in one session,
    /// programmatically invokes the tear-out path on the middle one,
    /// and asserts the resulting multi-HUD state matches the plan's
    /// 9-check spec.
    private func runTearOutSmoke() {
        Task {
            do {
                for (name, body) in [("A", "# Panel A"), ("B", "# Panel B"), ("C", "# Panel C")] {
                    _ = try await sessionManager.upsert(
                        sessionId: "tearout-smoke",
                        name: name,
                        contentType: "markdown",
                        form: "inline",
                        body: body
                    )
                }
                guard let session = sessionManager.sessions["tearout-smoke"] else {
                    NSLog("QuickShow: TEST_TEAROUT failed: session missing")
                    return
                }
                NSLog("QuickShow: TEST_TEAROUT step=initial huds=\(session.huds.count) panels=\(session.huds.first?.panels.count ?? -1)")

                // Tear out B.
                let primary = session.huds[0]
                let primaryId = primary.id
                let fakeEvent = NSEvent.mouseEvent(
                    with: .leftMouseDragged,
                    location: NSEvent.mouseLocation,
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: primary.window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 0,
                    pressure: 0
                ) ?? NSEvent()
                sessionManager.handleTearOut(
                    sessionId: "tearout-smoke",
                    hudId: primaryId,
                    name: "B",
                    event: fakeEvent
                )
                try await Task.sleep(nanoseconds: 200_000_000)

                let source = session.huds.first(where: { $0.id == primaryId })
                let torn = session.huds.first(where: { $0.id != primaryId })
                NSLog("QuickShow: TEST_TEAROUT step=after huds=\(session.huds.count) source_panels=\(source?.panels.map(\.name).joined(separator: ",") ?? "?") torn_panels=\(torn?.panels.map(\.name).joined(separator: ",") ?? "?")")
                if let s = source {
                    NSLog("QuickShow: TEST_TEAROUT source_active=\(s.window.activePanelName ?? "nil")")
                }

                // Verify orphan badge applies to both HUDs after grace.
                let originalGrace = ProcessInfo.processInfo.environment["QUICKSHOW_RECONNECT_GRACE_SECONDS"] ?? "60"
                NSLog("QuickShow: TEST_TEAROUT grace=\(originalGrace)s — triggering disconnect")
                sessionManager.sidecarDisconnected(sessionId: "tearout-smoke")
                let waitNs = UInt64((Double(originalGrace) ?? 60) * 1_000_000_000) + 200_000_000
                try await Task.sleep(nanoseconds: waitNs)
                NSLog("QuickShow: TEST_TEAROUT step=orphan orphaned=\(session.orphaned) huds=\(session.huds.count)")
                sessionManager.registerSession("tearout-smoke")
                try await Task.sleep(nanoseconds: 100_000_000)
                NSLog("QuickShow: TEST_TEAROUT step=reattach orphaned=\(session.orphaned)")

                // Opacity targeting: dispatch to the torn HUD only.
                if let tornHud = torn {
                    let beforeSource = source?.window.alphaValue ?? -1
                    let item = NSMenuItem(title: "Op", action: nil, keyEquivalent: "")
                    item.representedObject = OpacityPayload(sessionId: "tearout-smoke", hudId: tornHud.id, percent: 50)
                    sessionManager.handleOpacity(item)
                    NSLog("QuickShow: TEST_TEAROUT step=opacity source_alpha=\(source?.window.alphaValue ?? -1) torn_alpha=\(tornHud.window.alphaValue) (source-before=\(beforeSource))")
                }

                // Close torn panel → its HUD should go away.
                sessionManager.close(sessionId: "tearout-smoke", name: "B")
                try await Task.sleep(nanoseconds: 100_000_000)
                NSLog("QuickShow: TEST_TEAROUT step=close-torn huds=\(session.huds.count)")

                // Close all.
                sessionManager.closeAllPanels(in: "tearout-smoke")
                try await Task.sleep(nanoseconds: 100_000_000)
                NSLog("QuickShow: TEST_TEAROUT step=close-all huds=\(session.huds.count)")
                NSLog("QuickShow: TEST_TEAROUT done")
            } catch {
                NSLog("QuickShow: TEST_TEAROUT failed: \(error)")
            }
        }
    }

    /// Headless prefs test: verifies that Settings overrides land on
    /// new HUDs (opacity + size cap) and that the renderer bridge's
    /// `copy` side-channel writes to NSPasteboard.
    private func runPrefsSmoke() {
        Task {
            do {
                _ = try await sessionManager.upsert(
                    sessionId: "prefs-smoke",
                    name: "p",
                    contentType: "markdown",
                    form: "inline",
                    body: """
                    # Big enough content to hit the size cap

                    Lorem ipsum dolor sit amet, consectetur adipiscing elit.
                    Sed do eiusmod tempor incididunt ut labore et dolore
                    magna aliqua. Ut enim ad minim veniam, quis nostrud
                    exercitation ullamco laboris nisi ut aliquip ex ea
                    commodo consequat. Duis aute irure dolor in reprehenderit
                    in voluptate velit esse cillum dolore eu fugiat nulla
                    pariatur. Excepteur sint occaecat cupidatat non proident,
                    sunt in culpa qui officia deserunt mollit anim id est
                    laborum.
                    """
                )
                if let session = sessionManager.sessions["prefs-smoke"],
                   let hud = session.huds.first?.window {
                    NSLog("QuickShow: TEST_PREFS opacity alphaValue=\(hud.alphaValue)")
                    NSLog("QuickShow: TEST_PREFS sizeCap frame=\(hud.frame.size.width)x\(hud.frame.size.height)")
                }
                // Exercise the copy bridge: pull the renderer for the
                // panel and invoke its bridge with a {copy: ...} payload.
                if let session = sessionManager.sessions["prefs-smoke"],
                   let panel = session.huds.first?.panels.first,
                   let webRenderer = panel.renderer as? WebViewPanelRenderer {
                    // The bridge handler is private; route through the
                    // public message-handler relay by simulating what
                    // WK would deliver. Easier: use NSPasteboard
                    // directly to seed a known value, then call the
                    // bridge to verify it overwrites.
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("BEFORE", forType: .string)
                    webRenderer.testInvokeBridge(["copy": "AFTER-clipboard-payload"])
                    try await Task.sleep(nanoseconds: 100_000_000)
                    let got = NSPasteboard.general.string(forType: .string) ?? "(nil)"
                    NSLog("QuickShow: TEST_PREFS copy pasteboard=\(got)")
                }
                NSLog("QuickShow: TEST_PREFS done")
            } catch {
                NSLog("QuickShow: TEST_PREFS failed: \(error)")
            }
        }
    }

    /// Headless promote test (parallel to PipAnything's PIP_TEST_* hooks).
    /// Renders a panel, invokes `handlePromote`, asserts the
    /// activationPolicy transitions to .regular; closes the promoted
    /// window, asserts back to .accessory. Logs each step so a shell
    /// test can grep for the expected transitions.
    private func runPromoteSmoke() {
        Task {
            do {
                _ = try await sessionManager.upsert(
                    sessionId: "promote-smoke",
                    name: "panel",
                    contentType: "markdown",
                    form: "inline",
                    body: "# Promote smoke"
                )
                NSLog("QuickShow: TEST_PROMOTE step=initial activationPolicy=\(activationPolicyName())")
                let payload = MenuPayload(sessionId: "promote-smoke", name: "panel")
                let item = NSMenuItem(title: "Promote", action: nil, keyEquivalent: "")
                item.representedObject = payload
                sessionManager.handlePromote(item)
                // Give the policy change one runloop turn to flush.
                try await Task.sleep(nanoseconds: 200_000_000)
                NSLog("QuickShow: TEST_PROMOTE step=after-promote activationPolicy=\(activationPolicyName())")
                // Close the promoted window via NSApp.windows lookup.
                if let promoted = NSApp.windows.first(where: { $0 is PromotedWindow }) {
                    promoted.close()
                }
                try await Task.sleep(nanoseconds: 300_000_000)
                NSLog("QuickShow: TEST_PROMOTE step=after-close activationPolicy=\(activationPolicyName())")
                NSLog("QuickShow: TEST_PROMOTE done")
            } catch {
                NSLog("QuickShow: TEST_PROMOTE failed: \(error)")
            }
        }
    }

    private func activationPolicyName() -> String {
        switch NSApp.activationPolicy() {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown"
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
        let prefs = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit QuickShow", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    @objc private func openPreferences() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow()
        }
        settingsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
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
