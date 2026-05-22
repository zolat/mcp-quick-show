import Cocoa

// Bootstrap. Owns the top-level orchestrators. Phase 0: only the
// control server. Phase 1 adds RendererRegistry + first HUDWindow.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controlServer: ControlServer?
    private var mcpHTTPServer: MCPHTTPServer?
    private var statusItem: NSStatusItem?
    private(set) var sessionManager: SessionManager!
    private(set) var rendererRegistry: RendererRegistry!
    private(set) var promoteController: PromoteToWindowController!
    private(set) var userOpenActions: UserOpenActions!
    private var settingsWindow: SettingsWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        rendererRegistry = RendererRegistry.makeDefault()
        sessionManager = SessionManager(renderers: rendererRegistry)
        promoteController = PromoteToWindowController()
        sessionManager.promoteController = promoteController
        userOpenActions = UserOpenActions()
        userOpenActions.sessionManager = sessionManager
        installMenuBarItem()
        startControlServer()
        startMCPHTTPServerIfEnabled()
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
        if ProcessInfo.processInfo.environment["QUICKSHOW_TEST_REATTACH"] == "1" {
            runReattachSmoke()
        }
        if ProcessInfo.processInfo.environment["QUICKSHOW_TEST_FUSED"] == "1" {
            runFusedSmoke()
        }
        if ProcessInfo.processInfo.environment["QUICKSHOW_TEST_PANZOOM"] == "1" {
            runPanZoomSmoke()
        }
        if ProcessInfo.processInfo.environment["QUICKSHOW_TEST_MARKUP"] == "1" {
            runMarkupSmoke()
        }
        if ProcessInfo.processInfo.environment["QUICKSHOW_TEST_MARKUP_UI"] == "1" {
            runMarkupUISmoke()
        }
        if ProcessInfo.processInfo.environment["QUICKSHOW_TEST_HTML"] == "1" {
            runHTMLSmoke()
        }
        if ProcessInfo.processInfo.environment["QUICKSHOW_TEST_PEER_PID"] == "1" {
            runPeerPidSmoke()
        }
    }

    /// Headless P1 proof: stands up a tiny AF_INET listener on
    /// 127.0.0.1, accepts a single connection, hands the FD to
    /// `PeerPidResolver`, and logs the resolved PID. Designed to be
    /// driven by `curl http://127.0.0.1:<port>/` from a shell where
    /// `$$` is known, then asserting the resolved PID matches curl's.
    ///
    /// Logs lines:
    ///   QuickShow: TEST_PEER_PID listening port=<port>
    ///   QuickShow: PeerPidResolver accepted-conn fd=<n> peer_port=<p> resolved_pid=<pid>
    ///   QuickShow: TEST_PEER_PID resolved_pid=<pid>
    ///   QuickShow: TEST_PEER_PID done
    private func runPeerPidSmoke() {
        Task.detached {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                NSLog("QuickShow: TEST_PEER_PID failed: socket() errno=\(errno)")
                return
            }
            defer { Darwin.close(fd) }

            var one: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0  // ephemeral
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let addrSize = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bindRC = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(fd, sa, addrSize)
                }
            }
            guard bindRC == 0 else {
                NSLog("QuickShow: TEST_PEER_PID failed: bind() errno=\(errno)")
                return
            }
            // Read back the actual port.
            var actual = sockaddr_in()
            var actualLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let getRC = withUnsafeMutablePointer(to: &actual) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getsockname(fd, sa, &actualLen)
                }
            }
            guard getRC == 0 else {
                NSLog("QuickShow: TEST_PEER_PID failed: getsockname() errno=\(errno)")
                return
            }
            let port = UInt16(bigEndian: actual.sin_port)
            guard Darwin.listen(fd, 8) == 0 else {
                NSLog("QuickShow: TEST_PEER_PID failed: listen() errno=\(errno)")
                return
            }
            NSLog("QuickShow: TEST_PEER_PID listening port=\(port)")

            // Accept one connection, resolve, write a tiny HTTP response,
            // then loop again so the test rig can drive multiple curls
            // (direct + fork-worker variants).
            while true {
                let connFd = Darwin.accept(fd, nil, nil)
                if connFd < 0 {
                    NSLog("QuickShow: TEST_PEER_PID accept errno=\(errno)")
                    continue
                }
                let pid = PeerPidResolver.resolve(fd: connFd, tag: "accepted-conn")
                NSLog("QuickShow: TEST_PEER_PID resolved_pid=\(pid.map(String.init) ?? "nil")")
                let body = "pid=\(pid.map(String.init) ?? "nil")\n"
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                _ = resp.withCString { p -> Int in
                    Darwin.write(connFd, p, strlen(p))
                }
                Darwin.close(connFd)
            }
        }
    }

    /// Headless `show_html` test. Renders an HTML doc with an inline
    /// `<script>` (which `innerHTML` would silently drop) and asserts
    /// the script ran. Proves the loadHTMLString-bypass path is wired
    /// end-to-end through `SessionManager.upsert` and the renderer
    /// registry.
    private func runHTMLSmoke() {
        Task {
            do {
                let session = "html-smoke"
                let html = """
                <!doctype html><html><head><meta charset="utf-8">
                <style>body{font-family:-apple-system,system-ui;color:#222;margin:24px}</style>
                </head><body>
                <h1 id="hd">show_html smoke</h1>
                <p id="status">initial</p>
                <script>document.getElementById('status').textContent='script-ran';</script>
                </body></html>
                """
                let (result, snapshot) = try await sessionManager.upsert(
                    sessionId: session,
                    name: "design",
                    contentType: "html",
                    form: "inline",
                    body: html
                )
                NSLog("QuickShow: TEST_HTML render width=\(result.width) height=\(result.height) snapshot_bytes=\(snapshot.count)")

                // Drive the WebView to read the post-script DOM state.
                guard let panel = sessionManager.groups[session]?.huds.first?.panels.first,
                      let web = panel.renderer as? WebViewPanelRenderer else {
                    NSLog("QuickShow: TEST_HTML failed: renderer missing")
                    return
                }
                let scriptRan = try await web.webView.evaluateJavaScript(
                    "document.getElementById('status').textContent"
                ) as? String ?? ""
                NSLog("QuickShow: TEST_HTML script_status=\"\(scriptRan)\"")

                sessionManager.closeAllPanels(in: session)
                NSLog("QuickShow: TEST_HTML done")
            } catch {
                NSLog("QuickShow: TEST_HTML failed: \(error)")
            }
        }
    }

    /// Headless markup test. Renders a markdown panel, drives both
    /// the Send and Dismiss paths (via SessionManager, the same paths
    /// the title-bar buttons trigger), and logs the resulting events-
    /// log content + artifact presence so a shell test can grep for
    /// the expected lines + bytes.
    private func runMarkupSmoke() {
        Task {
            do {
                let session = "markup-smoke"
                sessionManager.setFlag(
                    group: session,
                    key: "markup_events_armed",
                    value: .bool(true)
                )
                NSLog("QuickShow: TEST_MARKUP step=armed flag=\(sessionManager.flag(group: session, key: "markup_events_armed").map(String.init(describing:)) ?? "nil")")

                _ = try await sessionManager.upsert(
                    sessionId: session,
                    name: "diagram",
                    contentType: "markdown",
                    form: "inline",
                    body: "# circle the bug\n\n- thing\n- other thing\n"
                )

                guard let s = sessionManager.groups[session],
                      let hud = s.huds.first,
                      let panel = hud.panels.first,
                      let web = panel.renderer as? WebViewPanelRenderer else {
                    NSLog("QuickShow: TEST_MARKUP failed: renderer missing")
                    return
                }

                // Send path: inject a stroke via the in-DOM canvas
                // bridge so the snapshot has something visible, then
                // drive Send the same way the title-bar ✓ button does.
                await web.appendStrokeForTest(MarkupStroke(
                    points: [
                        .init(x: 20, y: 20),
                        .init(x: 80, y: 20),
                        .init(x: 80, y: 80)
                    ],
                    color: MarkupStroke.defaultColor,
                    width: MarkupStroke.defaultWidth
                ))
                sessionManager.sendActivePanelMarkup(sessionId: session, hudId: hud.id)
                try await Task.sleep(nanoseconds: 600_000_000)

                // Dismiss path: a second panel that we close without
                // sending (closing the just-sent one wouldn't fire a
                // dismiss — markupSentPending suppresses it).
                _ = try await sessionManager.upsert(
                    sessionId: session,
                    name: "discardable",
                    contentType: "markdown",
                    form: "inline",
                    body: "# unused panel\n"
                )
                sessionManager.close(sessionId: session, name: "discardable")

                try await Task.sleep(nanoseconds: 200_000_000)

                let log = MarkupPaths.eventsLog(session)
                let content = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                NSLog("QuickShow: TEST_MARKUP events_log_lines=\(content.split(separator: "\n").count)")
                let lines = content.split(separator: "\n").map(String.init)
                for (i, line) in lines.enumerated() {
                    NSLog("QuickShow: TEST_MARKUP line[\(i)]=\(line)")
                }

                let artifactsDir = MarkupPaths.artifactsDir(session)
                let artifacts = (try? FileManager.default.contentsOfDirectory(atPath: artifactsDir.path)) ?? []
                let pngs = artifacts.filter { $0.hasSuffix(".png") }
                NSLog("QuickShow: TEST_MARKUP artifacts_dir=\(artifactsDir.path) png_count=\(pngs.count)")
                if let first = pngs.first {
                    let size = (try? Data(contentsOf: artifactsDir.appendingPathComponent(first)).count) ?? -1
                    NSLog("QuickShow: TEST_MARKUP first_artifact=\(first) bytes=\(size)")
                }

                sessionManager.closeAllPanels(in: session)
                NSLog("QuickShow: TEST_MARKUP done")
            } catch {
                NSLog("QuickShow: TEST_MARKUP failed: \(error)")
            }
        }
    }

    /// Headless markup-UI test. Exercises the visible side of the
    /// feedback loop: title-bar Send button, draw-mode overlay, the
    /// composite snapshot path, plus the no-double-dismiss + reset-
    /// pending-on-rerender invariants.
    ///
    /// Logs grep-anchors of the form `TEST_MARKUP_UI step=<n> kind=<x>`
    /// so a shell test can pull pass/fail signals out of stderr.
    private func runMarkupUISmoke() {
        Task {
            do {
                // ---- 1. Initial-pull race ----------------------------
                //
                // Sidecar would call `enable_markup_events` (which sets
                // the flag) BEFORE its first `show_*` upsert. Simulate
                // that order so the HUD must pull the armed-state
                // synchronously when it's born.
                let s1 = "markup-ui-initial"
                sessionManager.setFlag(
                    group: s1,
                    key: "markup_events_armed",
                    value: .bool(true)
                )
                _ = try await sessionManager.upsert(
                    sessionId: s1, name: "design",
                    contentType: "markdown",
                    form: "inline",
                    body: "# initial pull race\n"
                )
                guard let hud1 = sessionManager.groups[s1]?.huds.first?.window else {
                    NSLog("QuickShow: TEST_MARKUP_UI failed step=1 kind=no-hud")
                    return
                }
                NSLog("QuickShow: TEST_MARKUP_UI step=1 kind=initial-pull sendVisible=\(hud1.isSendButtonVisibleForTest) markupVisible=\(hud1.isMarkupButtonVisibleForTest)")

                // ---- 2. Notification path ---------------------------
                //
                // Reverse order: upsert FIRST, then setFlag. Title bar
                // should pick up the visibility change via the
                // quickShowSessionFlagChanged notification.
                let s2 = "markup-ui-notification"
                _ = try await sessionManager.upsert(
                    sessionId: s2, name: "design",
                    contentType: "markdown",
                    form: "inline",
                    body: "# notification path\n"
                )
                guard let hud2 = sessionManager.groups[s2]?.huds.first?.window else {
                    NSLog("QuickShow: TEST_MARKUP_UI failed step=2 kind=no-hud")
                    return
                }
                let beforeArm = hud2.isSendButtonVisibleForTest
                sessionManager.setFlag(
                    group: s2,
                    key: "markup_events_armed",
                    value: .bool(true)
                )
                // Notification dispatch is synchronous on the main run
                // loop, but the title bar's handler may dispatch async
                // — give it a tick.
                try await Task.sleep(nanoseconds: 100_000_000)
                NSLog("QuickShow: TEST_MARKUP_UI step=2 kind=notification beforeArm=\(beforeArm) afterArm=\(hud2.isSendButtonVisibleForTest)")

                // ---- 3. Send flow -----------------------------------
                //
                // Click Send programmatically; assert NDJSON line +
                // artifact land in the session's events dir.
                let s3 = "markup-ui-send"
                sessionManager.setFlag(
                    group: s3,
                    key: "markup_events_armed",
                    value: .bool(true)
                )
                _ = try await sessionManager.upsert(
                    sessionId: s3, name: "design",
                    contentType: "markdown",
                    form: "inline",
                    body: "# send flow\n\nclick send.\n"
                )
                guard let hud3 = sessionManager.groups[s3]?.huds.first?.window else {
                    NSLog("QuickShow: TEST_MARKUP_UI failed step=3 kind=no-hud")
                    return
                }
                hud3.performSendForTest()
                try await Task.sleep(nanoseconds: 600_000_000)
                let s3Log = (try? String(contentsOf: MarkupPaths.eventsLog(s3), encoding: .utf8)) ?? ""
                let s3Lines = s3Log.split(separator: "\n").map(String.init)
                let s3Artifacts = ((try? FileManager.default.contentsOfDirectory(atPath: MarkupPaths.artifactsDir(s3).path)) ?? []).filter { $0.hasSuffix(".png") }
                NSLog("QuickShow: TEST_MARKUP_UI step=3 kind=send lines=\(s3Lines.count) artifacts=\(s3Artifacts.count)")
                for (i, line) in s3Lines.enumerated() {
                    NSLog("QuickShow: TEST_MARKUP_UI step=3 line[\(i)]=\(line)")
                }

                // ---- 4. Draw + send composite -----------------------
                //
                // Enter draw mode, append a stroke directly into the
                // overlay (skipping mouse synthesis), click Send. The
                // composite PNG must include red pixels — the stroke
                // color — proving the overlay layer made it through
                // the composite into the artifact bytes.
                let s4 = "markup-ui-draw"
                sessionManager.setFlag(
                    group: s4,
                    key: "markup_events_armed",
                    value: .bool(true)
                )
                _ = try await sessionManager.upsert(
                    sessionId: s4, name: "design",
                    contentType: "markdown",
                    form: "inline",
                    body: "# draw + composite\n"
                )
                guard let hud4 = sessionManager.groups[s4]?.huds.first?.window,
                      let hud4Instance = sessionManager.groups[s4]?.huds.first,
                      let panel4 = hud4Instance.panels.first(where: { $0.name == "design" }),
                      let web4 = panel4.renderer as? WebViewPanelRenderer else {
                    NSLog("QuickShow: TEST_MARKUP_UI failed step=4 kind=no-hud")
                    return
                }
                hud4.toggleDrawMode()
                // CSS-pixel coords (Y-down) for the JS canvas. Stroke
                // lands in the TOP-LEFT region of the document since
                // the canvas mirrors the document's coord space.
                await web4.appendStrokeForTest(MarkupStroke(
                    points: [
                        .init(x: 30, y: 30),
                        .init(x: 120, y: 30),
                        .init(x: 120, y: 120)
                    ],
                    color: MarkupStroke.defaultColor,
                    width: 8.0
                ))
                hud4.performSendForTest()
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let s4Artifacts = ((try? FileManager.default.contentsOfDirectory(atPath: MarkupPaths.artifactsDir(s4).path)) ?? []).filter { $0.hasSuffix(".png") }
                var s4UpperLeftRed = false
                var s4LowerRightRed = false
                if let first = s4Artifacts.first,
                   let data = try? Data(contentsOf: MarkupPaths.artifactsDir(s4).appendingPathComponent(first)),
                   let rep = NSBitmapImageRep(data: data) {
                    // JS canvas coords are Y-down (CSS pixels); the
                    // stroke at (30,30)→(120,30)→(120,120) lands in
                    // the TOP-LEFT region of the rendered document.
                    // `colorAt(x:y:)` is also Y-down, so we look in
                    // the upper-left quadrant for red AND the lower-
                    // right for absence — asymmetric expectation
                    // catches any orientation flip in the new
                    // takeSnapshot path.
                    s4UpperLeftRed = detectsRedInRegion(
                        rep,
                        xRange: 0 ..< (rep.pixelsWide / 2),
                        yRange: 0 ..< (rep.pixelsHigh / 2)
                    )
                    s4LowerRightRed = detectsRedInRegion(
                        rep,
                        xRange: (rep.pixelsWide / 2) ..< rep.pixelsWide,
                        yRange: (rep.pixelsHigh / 2) ..< rep.pixelsHigh
                    )
                    NSLog("QuickShow: TEST_MARKUP_UI step=4 kind=draw artifact_bytes=\(data.count) px=\(rep.pixelsWide)x\(rep.pixelsHigh) ulRed=\(s4UpperLeftRed) lrRed=\(s4LowerRightRed)")
                } else {
                    NSLog("QuickShow: TEST_MARKUP_UI step=4 kind=draw artifact_missing")
                }

                // ---- 5. No-double-dismiss ---------------------------
                //
                // Sent already in step 3; close the panel and assert
                // log still has 0 markup_dismissed for it.
                sessionManager.close(sessionId: s3, name: "design")
                try await Task.sleep(nanoseconds: 200_000_000)
                let s3LogAfter = (try? String(contentsOf: MarkupPaths.eventsLog(s3), encoding: .utf8)) ?? ""
                let s3LinesAfter = s3LogAfter.split(separator: "\n").map(String.init)
                let s3Sent = s3LinesAfter.filter { $0.contains("\"markup_sent\"") }.count
                let s3Dismissed = s3LinesAfter.filter { $0.contains("\"markup_dismissed\"") }.count
                NSLog("QuickShow: TEST_MARKUP_UI step=5 kind=no-double-dismiss sent=\(s3Sent) dismissed=\(s3Dismissed) total_lines=\(s3LinesAfter.count)")

                // ---- 6. Re-render resets pending --------------------
                //
                // Send → re-upsert same name → close should produce a
                // fresh dismiss (the re-render cleared the pending
                // flag — see SessionManager.renderPanel).
                let s6 = "markup-ui-rerender"
                sessionManager.setFlag(
                    group: s6,
                    key: "markup_events_armed",
                    value: .bool(true)
                )
                _ = try await sessionManager.upsert(
                    sessionId: s6, name: "design",
                    contentType: "markdown",
                    form: "inline",
                    body: "# rerender baseline\n"
                )
                guard let hud6 = sessionManager.groups[s6]?.huds.first?.window else {
                    NSLog("QuickShow: TEST_MARKUP_UI failed step=6 kind=no-hud")
                    return
                }
                hud6.performSendForTest()
                try await Task.sleep(nanoseconds: 600_000_000)
                _ = try await sessionManager.upsert(
                    sessionId: s6, name: "design",
                    contentType: "markdown",
                    form: "inline",
                    body: "# rerender new content\n"
                )
                sessionManager.close(sessionId: s6, name: "design")
                try await Task.sleep(nanoseconds: 200_000_000)
                let s6Log = (try? String(contentsOf: MarkupPaths.eventsLog(s6), encoding: .utf8)) ?? ""
                let s6Lines = s6Log.split(separator: "\n").map(String.init)
                let s6Sent = s6Lines.filter { $0.contains("\"markup_sent\"") }.count
                let s6Dismissed = s6Lines.filter { $0.contains("\"markup_dismissed\"") }.count
                NSLog("QuickShow: TEST_MARKUP_UI step=6 kind=rerender sent=\(s6Sent) dismissed=\(s6Dismissed)")

                // ---- 7. Strokes survive re-render -------------------
                //
                // The in-DOM canvas architecture preserves strokes
                // across re-renders — Swift mirrors them onto
                // `Panel.strokes` via the JS bridge and replays after
                // each `update()`. Open two panels, draw on b, switch
                // to a, re-render b. Assert Panel.strokes still has
                // the stroke AND that the JS canvas (after switching
                // back to b) reports the same count.
                let s7 = "markup-ui-survives-rerender"
                sessionManager.setFlag(
                    group: s7,
                    key: "markup_events_armed",
                    value: .bool(true)
                )
                _ = try await sessionManager.upsert(
                    sessionId: s7, name: "a",
                    contentType: "markdown",
                    form: "inline",
                    body: "# panel a\n"
                )
                _ = try await sessionManager.upsert(
                    sessionId: s7, name: "b",
                    contentType: "markdown",
                    form: "inline",
                    body: "# panel b\n"
                )
                guard let session7 = sessionManager.groups[s7],
                      let bPanel = session7.huds.first?.panels.first(where: { $0.name == "b" }),
                      let bWeb = bPanel.renderer as? WebViewPanelRenderer else {
                    NSLog("QuickShow: TEST_MARKUP_UI failed step=7 kind=no-panel")
                    return
                }
                // After the second upsert, "b" is active. Inject a
                // stroke via the JS bridge and let the strokesChanged
                // round-trip mirror it into bPanel.strokes... except
                // appendStrokeForTest is the silent path (no message
                // back). So commit explicitly via popLast+set, or
                // just write to Panel.strokes here for the test.
                await bWeb.appendStrokeForTest(MarkupStroke(
                    points: [.init(x: 40, y: 40), .init(x: 100, y: 100)],
                    color: MarkupStroke.defaultColor,
                    width: 5.0
                ))
                bPanel.strokes = await bWeb.getStrokes()
                sessionManager.switchTab(in: s7, to: "a")
                let bStrokesAfterSwitch = bPanel.strokes.count
                // Re-render b while a is active. Under the new
                // policy, bPanel.strokes survives (no auto-wipe) and
                // the JS canvas gets replayed from Panel.strokes.
                _ = try await sessionManager.upsert(
                    sessionId: s7, name: "b",
                    contentType: "markdown",
                    form: "inline",
                    body: "# panel b updated\n"
                )
                let bStrokesAfterReRender = bPanel.strokes.count
                sessionManager.switchTab(in: s7, to: "b")
                let bJsStrokesOnReturn = await bWeb.getStrokes().count
                NSLog("QuickShow: TEST_MARKUP_UI step=7 kind=survives-rerender afterCommit=\(bStrokesAfterSwitch) afterReRender=\(bStrokesAfterReRender) jsOnReturn=\(bJsStrokesOnReturn)")

                // Cleanup.
                for s in [s1, s2, s3, s4, s6, s7] {
                    sessionManager.closeAllPanels(in: s)
                }
                NSLog("QuickShow: TEST_MARKUP_UI done")
            } catch {
                NSLog("QuickShow: TEST_MARKUP_UI failed: \(error)")
            }
        }
    }

    /// Region-scoped red detector. Returns true if any sampled pixel
    /// inside `xRange × yRange` has the red marker color (R dominant
    /// by ≥ 80 over G/B with non-zero alpha). Sampling is sparse for
    /// speed — at 1px stride we'd touch ~640K pixels per region;
    /// stride 8 keeps it under 10K which is plenty for stroke
    /// detection at width 8pt.
    private func detectsRedInRegion(_ rep: NSBitmapImageRep,
                                    xRange: Range<Int>,
                                    yRange: Range<Int>) -> Bool {
        let stride = 8
        var y = yRange.lowerBound
        while y < yRange.upperBound {
            var x = xRange.lowerBound
            while x < xRange.upperBound {
                if let c = rep.colorAt(x: x, y: y) {
                    let r = Int(c.redComponent * 255)
                    let g = Int(c.greenComponent * 255)
                    let b = Int(c.blueComponent * 255)
                    let a = Int(c.alphaComponent * 255)
                    if a > 0 && r > 150 && (r - g) > 80 && (r - b) > 80 {
                        return true
                    }
                }
                x += stride
            }
            y += stride
        }
        return false
    }

    /// Headless pan/zoom test. Renders a mermaid panel + an image
    /// panel; pokes the JS panzoom controller via evaluateJavaScript;
    /// drives the image scroll view's magnification API. Logs the
    /// observed state so a shell test can grep for assertions.
    private func runPanZoomSmoke() {
        Task {
            do {
                // --- Mermaid (WebKit + outer scroll view) ---
                _ = try await sessionManager.upsert(
                    sessionId: "panzoom-smoke",
                    name: "diagram",
                    contentType: "mermaid",
                    form: "inline",
                    body: "flowchart LR\nA-->B-->C-->D"
                )
                try await Task.sleep(nanoseconds: 500_000_000)
                guard let session = sessionManager.groups["panzoom-smoke"],
                      let mermaidPanel = session.huds.first?.panels.first(where: { $0.name == "diagram" }),
                      let mermaidScroll = mermaidPanel.view as? ZoomableCanvasScrollView else {
                    NSLog("QuickShow: TEST_PANZOOM failed: no mermaid scroll view")
                    return
                }
                let mermaidInitial = mermaidScroll.magnification
                mermaidScroll.setMagnification(
                    2.0,
                    centeredAt: NSPoint(x: mermaidScroll.bounds.midX,
                                        y: mermaidScroll.bounds.midY)
                )
                let mermaidZoomed = mermaidScroll.magnification
                mermaidScroll.fitToContainer()
                let mermaidReset = mermaidScroll.magnification
                NSLog("QuickShow: TEST_PANZOOM mermaid initial=\(mermaidInitial) zoomed=\(mermaidZoomed) reset=\(mermaidReset)")

                // --- Image (NSScrollView pipeline) ---
                let fixturePath = "/tmp/qs-phase1-render.png"
                if FileManager.default.fileExists(atPath: fixturePath) {
                    _ = try await sessionManager.upsert(
                        sessionId: "panzoom-smoke",
                        name: "picture",
                        contentType: "image",
                        form: "path",
                        body: fixturePath
                    )
                    try await Task.sleep(nanoseconds: 300_000_000)
                    if let imgPanel = session.huds.first?.panels.first(where: { $0.name == "picture" }),
                       let scroll = imgPanel.view as? ZoomableCanvasScrollView {
                        let before = scroll.magnification
                        scroll.setMagnification(2.0, centeredAt: NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY))
                        let zoomed = scroll.magnification
                        scroll.fitToContainer()
                        let after = scroll.magnification
                        NSLog("QuickShow: TEST_PANZOOM image initial=\(before) zoomed=\(zoomed) reset=\(after)")
                    } else {
                        NSLog("QuickShow: TEST_PANZOOM image_skipped: no scroll view")
                    }
                } else {
                    NSLog("QuickShow: TEST_PANZOOM image_skipped: fixture missing")
                }

                sessionManager.closeAllPanels(in: "panzoom-smoke")
                NSLog("QuickShow: TEST_PANZOOM done")
            } catch {
                NSLog("QuickShow: TEST_PANZOOM failed: \(error)")
            }
        }
    }

    /// Headless test for the fused tear-out + reattach gesture path
    /// — simulates: tear out (creates a sibling HUD under the cursor),
    /// drag-move places cursor inside source's drop zone, drag-end
    /// merges back. Closer to what the user does in one continuous
    /// drag.
    private func runFusedSmoke() {
        Task {
            do {
                for (name, body) in [("A", "# A"), ("B", "# B"), ("C", "# C")] {
                    _ = try await sessionManager.upsert(
                        sessionId: "fused-smoke",
                        name: name,
                        contentType: "markdown",
                        form: "inline",
                        body: body
                    )
                }
                guard let session = sessionManager.groups["fused-smoke"] else { return }
                let primary = session.huds[0]
                let primaryId = primary.id
                let dragEvent = NSEvent.mouseEvent(
                    with: .leftMouseDragged,
                    location: NSEvent.mouseLocation,
                    modifierFlags: [], timestamp: 0,
                    windowNumber: primary.window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 0, pressure: 0
                ) ?? NSEvent()

                // Tear out B. handleTearOut spawns new HUD AND calls
                // handleHudDragStart for the new HUD's id.
                sessionManager.handleTearOut(
                    sessionId: "fused-smoke", hudId: primaryId, name: "B", event: dragEvent
                )
                try await Task.sleep(nanoseconds: 200_000_000)
                guard let torn = session.huds.first(where: { $0.id != primaryId }) else { return }
                NSLog("QuickShow: TEST_FUSED step=after-tearout huds=\(session.huds.count)")

                // Drag the new HUD's cursor toward primary's title bar
                // — simulates the user's continued drag.
                let dropPoint = NSPoint(
                    x: primary.window.frame.midX,
                    y: primary.window.frame.maxY - 8
                )
                sessionManager.handleHudDragMove(sessionId: "fused-smoke", hudId: torn.id, cursor: dropPoint)
                NSLog("QuickShow: TEST_FUSED step=during-drag highlight=\(primary.window.contentView?.layer?.borderWidth ?? 0)")
                sessionManager.handleHudDragEnd(sessionId: "fused-smoke", hudId: torn.id, cursor: dropPoint)
                try await Task.sleep(nanoseconds: 200_000_000)

                NSLog("QuickShow: TEST_FUSED step=after-drop huds=\(session.huds.count) primary_panels=\(session.huds.first?.panels.map(\.name).joined(separator: ",") ?? "?")")
                sessionManager.closeAllPanels(in: "fused-smoke")
                NSLog("QuickShow: TEST_FUSED done")
            } catch {
                NSLog("QuickShow: TEST_FUSED failed: \(error)")
            }
        }
    }

    /// Headless reattach test (separate title-bar drag, post-tear-out).
    /// The fused gesture covers the same surface but this proves the
    /// title-bar drag handlers work standalone.
    private func runReattachSmoke() {
        Task {
            do {
                for (name, body) in [("A", "# A"), ("B", "# B"), ("C", "# C")] {
                    _ = try await sessionManager.upsert(
                        sessionId: "reattach-smoke",
                        name: name,
                        contentType: "markdown",
                        form: "inline",
                        body: body
                    )
                }
                guard let session = sessionManager.groups["reattach-smoke"] else {
                    NSLog("QuickShow: TEST_REATTACH failed: session missing")
                    return
                }
                let primary = session.huds[0]
                let primaryId = primary.id

                // Tear B out into its own sibling HUD.
                let dragEvent = NSEvent.mouseEvent(
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
                    sessionId: "reattach-smoke",
                    hudId: primaryId,
                    name: "B",
                    event: dragEvent
                )
                try await Task.sleep(nanoseconds: 200_000_000)
                NSLog("QuickShow: TEST_REATTACH step=after-tearout huds=\(session.huds.count)")

                // Identify the torn HUD.
                guard let torn = session.huds.first(where: { $0.id != primaryId }) else {
                    NSLog("QuickShow: TEST_REATTACH failed: torn HUD missing")
                    return
                }

                // Pick a target point inside the source HUD's title bar
                // (always present, always in the drop zone).
                let sourceTitleBarRect = primary.window.frame
                let dropPoint = NSPoint(
                    x: sourceTitleBarRect.midX,
                    y: sourceTitleBarRect.maxY - 8  // ~inside title bar
                )
                NSLog("QuickShow: TEST_REATTACH dropPoint=\(dropPoint) sourceFrame=\(sourceTitleBarRect)")

                // Drive the drag handlers as if the user dragged the
                // torn HUD's title bar to the source's drop zone.
                sessionManager.handleHudDragStart(sessionId: "reattach-smoke", hudId: torn.id)
                sessionManager.handleHudDragMove(sessionId: "reattach-smoke", hudId: torn.id, cursor: dropPoint)
                // Verify the target was lit before drop.
                let primaryAfterMove = session.huds.first(where: { $0.id == primaryId })
                NSLog("QuickShow: TEST_REATTACH highlight_set=\(primaryAfterMove?.window.contentView?.layer?.borderWidth ?? 0)")

                sessionManager.handleHudDragEnd(sessionId: "reattach-smoke", hudId: torn.id, cursor: dropPoint)
                try await Task.sleep(nanoseconds: 200_000_000)

                NSLog("QuickShow: TEST_REATTACH step=after-reattach huds=\(session.huds.count) primary_panels=\(session.huds.first(where: { $0.id == primaryId })?.panels.map(\.name).joined(separator: ",") ?? "?")")
                NSLog("QuickShow: TEST_REATTACH torn_still_present=\(session.huds.contains(where: { $0.id == torn.id }))")

                sessionManager.closeAllPanels(in: "reattach-smoke")
                try await Task.sleep(nanoseconds: 100_000_000)
                NSLog("QuickShow: TEST_REATTACH done")
            } catch {
                NSLog("QuickShow: TEST_REATTACH failed: \(error)")
            }
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
                guard let session = sessionManager.groups["tearout-smoke"] else {
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
                sessionManager.registerGroup("tearout-smoke")
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
                if let session = sessionManager.groups["prefs-smoke"],
                   let hud = session.huds.first?.window {
                    NSLog("QuickShow: TEST_PREFS opacity alphaValue=\(hud.alphaValue)")
                    NSLog("QuickShow: TEST_PREFS sizeCap frame=\(hud.frame.size.width)x\(hud.frame.size.height)")
                    let cb = hud.collectionBehavior
                    let policy = Settings.shared.hudSpacePolicy
                    NSLog("QuickShow: TEST_PREFS spacePolicy=\(policy.rawValue) canJoinAllSpaces=\(cb.contains(.canJoinAllSpaces)) rawCB=\(cb.rawValue)")
                    // Verify the live-update observer responds. The env
                    // override dominates `Settings.shared`, so we
                    // exercise the observer code path directly: post the
                    // notification and confirm the HUD's
                    // collectionBehavior still matches the (env-locked)
                    // setting after the observer fires. This proves the
                    // observer is installed and re-applies the helper.
                    NotificationCenter.default.post(name: Settings.hudSpacePolicyChanged, object: nil)
                    try await Task.sleep(nanoseconds: 50_000_000)
                    let cb2 = hud.collectionBehavior
                    let expectedHasJoinAll = policy == .allSpaces
                    let observerOK = cb2.contains(.canJoinAllSpaces) == expectedHasJoinAll
                    NSLog("QuickShow: TEST_PREFS observerFired ok=\(observerOK) rawCB=\(cb2.rawValue)")
                }
                // Exercise the copy bridge: pull the renderer for the
                // panel and invoke its bridge with a {copy: ...} payload.
                if let session = sessionManager.groups["prefs-smoke"],
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
        mcpHTTPServer?.stop()
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

        let openURL = NSMenuItem(title: "Open URL…", action: #selector(UserOpenActions.openURL(_:)), keyEquivalent: "l")
        openURL.keyEquivalentModifierMask = [.command, .shift]
        openURL.target = userOpenActions
        menu.addItem(openURL)

        let openFile = NSMenuItem(title: "Open File…", action: #selector(UserOpenActions.openFile(_:)), keyEquivalent: "o")
        openFile.keyEquivalentModifierMask = [.command, .shift]
        openFile.target = userOpenActions
        menu.addItem(openFile)

        let captureScreen = NSMenuItem(title: "Capture Screen…",
                                       action: #selector(UserOpenActions.captureScreen(_:)),
                                       keyEquivalent: "")
        captureScreen.target = userOpenActions
        menu.addItem(captureScreen)

        let sketchPad = NSMenuItem(title: "New Sketch Pad", action: nil, keyEquivalent: "")
        let sketchSubmenu = NSMenu(title: "New Sketch Pad")
        let square = NSMenuItem(title: "Square (1024 × 1024)",
                                action: #selector(UserOpenActions.openSketchPadSquare(_:)),
                                keyEquivalent: "")
        square.target = userOpenActions
        sketchSubmenu.addItem(square)
        let landscape = NSMenuItem(title: "Landscape (1280 × 720)",
                                   action: #selector(UserOpenActions.openSketchPadLandscape(_:)),
                                   keyEquivalent: "")
        landscape.target = userOpenActions
        sketchSubmenu.addItem(landscape)
        let portrait = NSMenuItem(title: "Portrait (768 × 1024)",
                                  action: #selector(UserOpenActions.openSketchPadPortrait(_:)),
                                  keyEquivalent: "")
        portrait.target = userOpenActions
        sketchSubmenu.addItem(portrait)
        sketchSubmenu.addItem(.separator())
        let custom = NSMenuItem(title: "Custom…",
                                action: #selector(UserOpenActions.openSketchPadCustom(_:)),
                                keyEquivalent: "")
        custom.target = userOpenActions
        sketchSubmenu.addItem(custom)
        sketchPad.submenu = sketchSubmenu
        menu.addItem(sketchPad)

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

    /// Phase-1 HTTP MCP server boot. Gated on QUICKSHOW_MCP_HTTP=1
    /// so end users running the stdio sidecar aren't affected. Port
    /// defaults to MCPHTTPServer.defaultPort; override via
    /// QUICKSHOW_MCP_PORT for parallel test instances.
    private func startMCPHTTPServerIfEnabled() {
        guard ProcessInfo.processInfo.environment["QUICKSHOW_MCP_HTTP"] == "1" else { return }
        let env = ProcessInfo.processInfo.environment["QUICKSHOW_MCP_PORT"]
        let port = env.flatMap(UInt16.init) ?? MCPHTTPServer.defaultPort

        // MarkupEventsStream owns the off-MCP /markup-events NDJSON
        // channel — outside the SDK's /mcp routing so it can coexist
        // with Claude Code's MCP client (which claims the SDK's single
        // standalone-SSE slot).
        let markupEvents = MarkupEventsStream()

        // Two-phase wiring: build the router first with a registrar
        // closure that captures the (about-to-exist) router by `var`,
        // then assign the router into the closure's captured slot.
        // This is the only way to give the registrar a back-reference
        // to its own router (so the show_html handler can look up the
        // session's claudePid at call time).
        let sm = sessionManager!
        var routerHolder: MCPSessionRouter? = nil
        let router = MCPSessionRouter(
            toolRegistrar: { @MainActor @Sendable server, mcpSessionID in
                guard let r = routerHolder else { return }
                await MCPToolHandlers.register(
                    on: server,
                    mcpSessionID: mcpSessionID,
                    sessionManager: sm,
                    router: r,
                    markupEvents: markupEvents,
                    endpointPort: port
                )
            }
        )
        routerHolder = router

        let server = MCPHTTPServer(port: port, router: router, markupEvents: markupEvents)
        do {
            try server.start()
            mcpHTTPServer = server
        } catch {
            NSLog("QuickShow: mcp http server failed to start: \(error)")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
