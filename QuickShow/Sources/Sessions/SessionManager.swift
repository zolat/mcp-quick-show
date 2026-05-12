import Cocoa

/// Tracks panels per session. Phase 3 base: multi-panel per HUD.
/// Phase 4: orphan-on-disconnect with a 60 s same-UUID reconnect window.
/// Tear-out (PRD #27): a session can own multiple sibling HUDs after
/// the user drags a tab pill outside its host.
///
/// Invariants:
///  1. `upsert` never creates a new HUD when `session.huds` is non-empty.
///     It locates the named panel across all HUDs (in-place update) or
///     appends to `huds[0]` (the primary).
///  2. New HUDs spawned by tear-out ignore `cascadeIndex` — they land
///     under the cursor at the moment of tear-out.
///  3. `HUDWindow.isReleasedWhenClosed = false` so the order of
///     `window.close()` vs `session.huds.remove(...)` doesn't matter.
@MainActor
final class SessionManager: NSObject {
    static var reconnectGraceSeconds: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["QUICKSHOW_RECONNECT_GRACE_SECONDS"],
           let v = Double(raw), v > 0 {
            return v
        }
        return 60
    }

    private let renderers: RendererRegistry
    weak var promoteController: PromoteToWindowController?

    /// One MCP-session's worth of state. After tear-out a session can
    /// host multiple HUDs; `huds[0]` is the "primary" — the one new
    /// `upsert(name)`-with-novel-name calls append to.
    final class SessionState {
        let id: String
        let cascadeIndex: Int
        var huds: [HUDInstance] = []
        var orphanTimerTask: Task<Void, Never>?
        var orphaned: Bool = false
        /// Generic per-session flags driven by the `set_session_flag`
        /// control verb. First consumer: `markup_events_armed`.
        var flags: [String: SessionFlagValue] = [:]
        /// Lazy NDJSON writer for markup events. Created on first
        /// emit; the file lives at `MarkupPaths.eventsLog(sessionId)`.
        lazy var eventWriter: EventLogWriter = EventLogWriter(sessionId: id)

        init(id: String, cascadeIndex: Int) {
            self.id = id
            self.cascadeIndex = cascadeIndex
        }
    }

    /// One HUD window inside a session, with its own ordered panels.
    final class HUDInstance {
        let id: UUID
        let window: HUDWindow
        var panels: [Panel]

        init(window: HUDWindow, panels: [Panel] = []) {
            self.id = window.hudInstanceId
            self.window = window
            self.panels = panels
        }
    }

    final class Panel {
        let name: String
        let contentType: String
        let renderer: any PanelRenderer
        let view: NSView
        /// Markup strokes the user has drawn over this panel. Lives on
        /// Panel (the unit that travels under tear-out/reattach) so
        /// annotations follow the content across HUDs. Loaded into the
        /// owning HUD's overlay on activation, committed back on
        /// deactivation, and cleared by the Send flow.
        var strokes: [MarkupOverlayView.Stroke] = []
        /// True while a `markup_sent` artifact has been recorded for
        /// this panel's current render and the panel hasn't been
        /// re-rendered yet. Suppresses the close → `markup_dismissed`
        /// emission that would otherwise double-fire after Send.
        /// Reset to false on each re-render in `renderPanel`.
        var markupSentPending: Bool = false

        init(name: String, contentType: String, renderer: any PanelRenderer, view: NSView) {
            self.name = name
            self.contentType = contentType
            self.renderer = renderer
            self.view = view
        }
    }

    private(set) var sessions: [String: SessionState] = [:]
    private var sessionsRegisteredOrder = 0

    /// Held during an active tear-out drag so events keep flowing to
    /// the follow-the-cursor frame translator instead of the source
    /// pill's tracking machinery.
    private var dragMonitor: Any?

    /// Active drag-to-reattach state. Populated on title-bar mouseDown
    /// for the source HUD; cleared on mouseUp.
    private var reattachTarget: (sessionId: String, hudId: UUID)?

    init(renderers: RendererRegistry) {
        self.renderers = renderers
        super.init()
    }

    // MARK: - Session lifecycle

    func registerSession(_ sessionId: String) {
        if let existing = sessions[sessionId] {
            existing.orphanTimerTask?.cancel()
            existing.orphanTimerTask = nil
            if existing.orphaned {
                existing.orphaned = false
                for hud in existing.huds { hud.window.setSessionEnded(false) }
                NSLog("QuickShow: session \(sessionId) reattached (orphan badge cleared)")
            }
            return
        }
        let idx = sessionsRegisteredOrder
        sessionsRegisteredOrder += 1
        sessions[sessionId] = SessionState(id: sessionId, cascadeIndex: idx)
    }

    func sidecarDisconnected(sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        guard !session.huds.isEmpty else { return }
        session.orphanTimerTask?.cancel()
        let grace = Self.reconnectGraceSeconds
        session.orphanTimerTask = Task { [weak self, weak session] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self = self, let session = session,
                      self.sessions[session.id] === session else { return }
                session.orphaned = true
                for hud in session.huds { hud.window.setSessionEnded(true) }
                NSLog("QuickShow: session \(session.id) orphan grace expired — badge on \(session.huds.count) HUD(s)")
            }
        }
    }

    // MARK: - Panel verbs

    func upsert(sessionId: String,
                name: String,
                contentType: String,
                form: String,
                body: String) async throws -> (RenderResult, Data) {
        let session = ensureSession(sessionId)

        // Locate the panel across all HUDs first (in-place update path).
        if let (hud, panel) = locate(in: session, name: name) {
            if panel.contentType == contentType {
                return try await renderPanel(panel: panel, hud: hud,
                                             name: name, contentType: contentType,
                                             form: form, body: body)
            }
            // Same name, different type → swap the renderer in-place.
            hud.window.removePanel(name)
            guard let renderer = renderers.make(forContentType: contentType) else {
                throw RenderFailure(
                    message: "no renderer registered for content_type '\(contentType)'",
                    line: nil
                )
            }
            let view = renderer.makeView()
            let newPanel = Panel(name: name, contentType: contentType, renderer: renderer, view: view)
            wireMarkupCallback(renderer: renderer, sessionId: sessionId, panelName: name)
            let idx = hud.panels.firstIndex(where: { $0.name == name })!
            hud.panels[idx] = newPanel
            hud.window.installPanel(name: name, view: view)
            return try await renderPanel(panel: newPanel, hud: hud,
                                         name: name, contentType: contentType,
                                         form: form, body: body)
        }

        // Novel name → ensure primary HUD exists, append there.
        let primary = ensurePrimaryHud(in: session)
        guard let renderer = renderers.make(forContentType: contentType) else {
            throw RenderFailure(
                message: "no renderer registered for content_type '\(contentType)'",
                line: nil
            )
        }
        let view = renderer.makeView()
        let panel = Panel(name: name, contentType: contentType, renderer: renderer, view: view)
        wireMarkupCallback(renderer: renderer, sessionId: sessionId, panelName: name)
        primary.panels.append(panel)
        primary.window.installPanel(name: name, view: view)
        return try await renderPanel(panel: panel, hud: primary,
                                     name: name, contentType: contentType,
                                     form: form, body: body)
    }

    /// Hook a WebView-based renderer's `markupEvent` bridge so user
    /// actions on the panel turn into NDJSON events + on-disk artifacts.
    /// No-op for image renderers (no markup surface). Also wires the
    /// scroll bridge so the markup overlay can keep strokes anchored
    /// to content when the active panel scrolls.
    private func wireMarkupCallback(renderer: any PanelRenderer, sessionId: String, panelName: String) {
        guard let web = renderer as? WebViewPanelRenderer else { return }
        web.onMarkupEvent = { [weak self] action in
            guard let self = self else { return }
            switch action {
            case .send(let pngBytes):
                _ = self.recordMarkupSent(sessionId: sessionId, panel: panelName, pngBytes: pngBytes)
            case .dismiss:
                self.recordMarkupDismissed(sessionId: sessionId, panel: panelName)
            }
        }
        web.onScrollChanged = { [weak self] scroll in
            self?.forwardScrollToOverlay(
                sessionId: sessionId,
                panelName: panelName,
                scroll: scroll
            )
        }
    }

    /// Forward a panel's scroll-change event to its HUD's markup
    /// overlay — but ONLY when the panel is the active one. Background
    /// panels' scrolls don't repaint anything; their strokes already
    /// carry their own `anchorScroll` and will re-anchor correctly
    /// when activated.
    private func forwardScrollToOverlay(sessionId: String,
                                        panelName: String,
                                        scroll: NSPoint) {
        guard let session = sessions[sessionId] else { return }
        for hud in session.huds {
            if hud.window.activePanelName == panelName,
               hud.panels.contains(where: { $0.name == panelName }) {
                hud.window.markupOverlay.setCurrentScroll(scroll)
                return
            }
        }
    }

    private func renderPanel(panel: Panel,
                             hud: HUDInstance,
                             name: String,
                             contentType: String,
                             form: String,
                             body: String) async throws -> (RenderResult, Data) {
        hud.window.setActivePanel(name)
        hud.window.updateTabs(hud.panels.map(\.name))
        // Re-render means the content has changed underneath any
        // previously-drawn strokes — wipe them so the next close
        // is again a "dismiss without send", and so stale strokes
        // don't fight the new content.
        //
        // The mid-stroke guard applies ONLY when the user is actively
        // drawing on THIS panel right now (active + mid-drag). In that
        // case, dropping their stroke mid-gesture would feel like a
        // glitch — keep their work; their mouseUp will commit and the
        // next re-render will wipe normally. For inactive tabs, the
        // wipe always proceeds — the user isn't watching, so stale
        // strokes would just resurface on next tab switch.
        panel.markupSentPending = false
        let overlay = hud.window.markupOverlay
        let isActiveAndDragging =
            hud.window.activePanelName == name && overlay.isCurrentlyDragging
        if !isActiveAndDragging {
            panel.strokes = []
            if hud.window.activePanelName == name {
                overlay.loadStrokes([])
            }
        }
        let payload = PanelPayload(name: name, contentType: contentType, form: form, body: body)
        do {
            let result = try await panel.renderer.update(payload: payload)
            hud.window.sizeToContent(width: result.width, height: result.height)
            let snapshot = try await panel.renderer.snapshot()
            return (result, snapshot)
        } catch let renderFailure as RenderFailure {
            let errorSnapshot = (try? await panel.renderer.snapshot()) ?? Data()
            throw RenderFailureWithSnapshot(failure: renderFailure, snapshot: errorSnapshot)
        }
    }

    func close(sessionId: String, name: String) {
        guard let session = sessions[sessionId] else { return }
        guard let (hud, _) = locate(in: session, name: name) else { return }
        let wasActive = hud.window.activePanelName == name
        let panelIdx = hud.panels.firstIndex(where: { $0.name == name })!
        let closingPanel = hud.panels[panelIdx]
        // Until per-panel `accept_markup` lands, a close in an armed
        // session = a markup dismissed. Refines once the show_* tools
        // gain the opt-in argument. Skip when a markup_sent is already
        // pending for this panel — that close is the user clearing the
        // window after sending, not a dismissal.
        if session.flags["markup_events_armed"]?.asBool == true,
           !closingPanel.markupSentPending {
            recordMarkupDismissed(sessionId: sessionId, panel: name)
        }
        hud.panels.remove(at: panelIdx)
        hud.window.removePanel(name)
        if hud.panels.isEmpty {
            closeHudInstance(hud, in: session)
            return
        }
        hud.window.updateTabs(hud.panels.map(\.name))
        if wasActive {
            let nextIdx = min(panelIdx, hud.panels.count - 1)
            hud.window.setActivePanel(hud.panels[nextIdx].name)
            hud.window.updateTabs(hud.panels.map(\.name))
        }
    }

    func switchTab(in sessionId: String, to name: String) {
        guard let session = sessions[sessionId],
              let (hud, _) = locate(in: session, name: name) else { return }
        hud.window.setActivePanel(name)
        hud.window.updateTabs(hud.panels.map(\.name))
    }

    /// Close every HUD belonging to the session.
    func closeAllPanels(in sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        for hud in session.huds {
            hud.window.close()
        }
        session.huds.removeAll()
        session.orphanTimerTask?.cancel()
        session.orphanTimerTask = nil
        session.orphaned = false
    }

    /// Close just one HUD's worth of panels — leaves siblings (if any)
    /// intact. Called from a HUD's title-bar × button.
    func closeHud(sessionId: String, hudId: UUID) {
        guard let session = sessions[sessionId],
              let hud = session.huds.first(where: { $0.id == hudId }) else { return }
        // Emit a markup_dismissed for each panel in the HUD when the
        // session is armed — title-bar × counts as "user closed
        // without sending markup" for every panel inside — but skip
        // any panel whose current render has already been sent.
        if session.flags["markup_events_armed"]?.asBool == true {
            for panel in hud.panels where !panel.markupSentPending {
                recordMarkupDismissed(sessionId: sessionId, panel: panel.name)
            }
        }
        closeHudInstance(hud, in: session)
    }

    func inspect(sessionId: String, name: String) async throws -> (RenderResult, Data)? {
        guard let session = sessions[sessionId],
              let (hud, panel) = locate(in: session, name: name) else {
            return nil
        }
        let snapshot = try await panel.renderer.snapshot()
        let size = hud.window.frame.size
        return (RenderResult(width: Double(size.width), height: Double(size.height)), snapshot)
    }

    // MARK: - Flags

    /// Set a generic per-session flag. The session is auto-created if
    /// not yet known; this matches `upsert`'s behaviour so the sidecar
    /// can arm flags before its first render call lands.
    func setFlag(sessionId: String, key: String, value: SessionFlagValue) {
        let session = ensureSession(sessionId)
        session.flags[key] = value
        NSLog("QuickShow: session \(sessionId) flag \(key) = \(value)")
        NotificationCenter.default.post(
            name: .quickShowSessionFlagChanged,
            object: nil,
            userInfo: ["sessionId": sessionId, "key": key]
        )
    }

    /// Read a per-session flag. Returns `nil` if unset or session unknown.
    func flag(sessionId: String, key: String) -> SessionFlagValue? {
        sessions[sessionId]?.flags[key]
    }

    // MARK: - Markup events

    /// Persist a flattened markup PNG into the session's artifacts dir
    /// and append a `markup_sent` line to its events log. Returns the
    /// generated artifact id (which the sidecar later resolves via
    /// `get_markup`). Errors surface as a `nil` return + NSLog so the
    /// renderer can decide how loud to be — the JS bridge already
    /// considers the press "delivered" once it hands off the PNG.
    ///
    /// Side effect: marks the panel's `markupSentPending = true` so
    /// the close-on-armed path doesn't double-emit a `markup_dismissed`
    /// for the same render.
    @discardableResult
    func recordMarkupSent(sessionId: String, panel: String, pngBytes: Data) -> String? {
        let session = ensureSession(sessionId)
        let artifactId = UUID().uuidString.lowercased()
        do {
            try MarkupPaths.ensureDirs(sessionId)
            try pngBytes.write(to: MarkupPaths.artifact(sessionId, id: artifactId))
        } catch {
            NSLog("QuickShow: recordMarkupSent failed to write artifact: \(error)")
            return nil
        }
        session.eventWriter.emitMarkupSent(panel: panel, artifact: artifactId)
        // Mark the panel so a subsequent close in an armed session
        // doesn't double-fire a `markup_dismissed`.
        if let (_, panelObj) = locate(in: session, name: panel) {
            panelObj.markupSentPending = true
        }
        NSLog("QuickShow: markup_sent session=\(sessionId) panel=\(panel) artifact=\(artifactId)")
        return artifactId
    }

    /// Take a snapshot of the active panel inside `hudId`, composite
    /// any overlay strokes on top, emit `markup_sent`, then exit draw
    /// mode and clear the overlay. Wired to the title-bar Send button
    /// in `wireHudCallbacks`.
    func sendActivePanelMarkup(sessionId: String, hudId: UUID) {
        guard let session = sessions[sessionId],
              let hud = session.huds.first(where: { $0.id == hudId }),
              let activeName = hud.window.activePanelName,
              let panel = hud.panels.first(where: { $0.name == activeName }) else {
            return
        }
        let overlay = hud.window.markupOverlay
        let strokesAtSend = overlay.currentStrokes()

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let composite: Data
                // WebView-backed renderers get a full-document snapshot
                // (everything, not just the visible scrolled region)
                // with strokes translated from viewport→document
                // coords. ImageRenderer + anything else falls back to
                // the visible-bounds path.
                if let web = panel.renderer as? WebViewPanelRenderer,
                   let webView = web.webView {
                    let (docPNG, docSize, viewBounds, _) =
                        try await SnapshotService.snapshotFullDocument(webView)
                    composite = SnapshotService.compositeMarkupFullPage(
                        documentPNG: docPNG,
                        strokes: strokesAtSend,
                        viewBoundsPt: viewBounds,
                        docSizePt: docSize
                    ) ?? docPNG
                } else {
                    let underlying = try await panel.renderer.snapshot()
                    composite = SnapshotService.compositeMarkup(
                        underlyingPNG: underlying,
                        strokes: strokesAtSend,
                        viewBoundsPt: panel.view.bounds.size
                    ) ?? underlying
                }
                _ = self.recordMarkupSent(
                    sessionId: sessionId,
                    panel: activeName,
                    pngBytes: composite
                )
                // Leave strokes on screen so the user sees their
                // annotation was captured (otherwise the screen
                // snaps clean and feels like the send didn't take).
                // The next agent re-render of this panel is what
                // wipes them (see renderPanel).
                //
                // Exit draw mode though — the gesture is complete; if
                // the user wants to add more strokes they'll re-enter
                // explicitly. Cmd+Z still pops strokes one at a time
                // for manual cleanup if they want a clean slate
                // without waiting for the agent.
                if hud.window.isInDrawMode {
                    hud.window.toggleDrawMode()
                }
            } catch {
                NSLog("QuickShow: sendActivePanelMarkup snapshot failed: \(error)")
            }
        }
    }

    /// Emit a `markup_dismissed` line for a panel that was closed
    /// without sending. No artifact is written.
    func recordMarkupDismissed(sessionId: String, panel: String) {
        let session = ensureSession(sessionId)
        session.eventWriter.emitMarkupDismissed(panel: panel)
        NSLog("QuickShow: markup_dismissed session=\(sessionId) panel=\(panel)")
    }

    func list(sessionId: String) -> [PanelDescriptor] {
        guard let session = sessions[sessionId] else { return [] }
        var out: [PanelDescriptor] = []
        for hud in session.huds {
            let size = hud.window.frame.size
            for panel in hud.panels {
                out.append(PanelDescriptor(
                    name: panel.name,
                    contentType: panel.contentType,
                    width: Double(size.width),
                    height: Double(size.height)
                ))
            }
        }
        return out
    }

    // MARK: - Tear-out

    /// PRD user story #27. Detach `name` from its current HUD and
    /// spawn a sibling HUD containing just that panel, positioned
    /// under the cursor, with a drag-follow monitor that keeps the
    /// new HUD pinned to the cursor until mouseUp.
    func handleTearOut(sessionId: String, hudId: UUID, name: String, event: NSEvent) {
        guard let session = sessions[sessionId],
              let source = session.huds.first(where: { $0.id == hudId }),
              source.panels.count > 1,
              let panelIdx = source.panels.firstIndex(where: { $0.name == name }) else {
            return
        }
        let panel = source.panels[panelIdx]
        let wasActive = source.window.activePanelName == name

        // 1. Detach from source — mirror close's active-panel reselect.
        source.panels.remove(at: panelIdx)
        source.window.removePanel(name)
        source.window.updateTabs(source.panels.map(\.name))
        if wasActive, !source.panels.isEmpty {
            let nextIdx = min(panelIdx, source.panels.count - 1)
            source.window.setActivePanel(source.panels[nextIdx].name)
            source.window.updateTabs(source.panels.map(\.name))
        }

        // 2. Spawn new HUD with the panel's view re-housed in it.
        //    Position so the title-bar area lands roughly under the
        //    cursor — feels natural for the drag-follow that starts
        //    immediately after.
        let mouseLoc = NSEvent.mouseLocation
        let initialSize = HUDWindow.defaultSize
        let origin = NSPoint(
            x: mouseLoc.x - initialSize.width / 2,
            y: mouseLoc.y - initialSize.height + TitleBarOverlay.height / 2
        )
        let newWindow = HUDWindow(initialPosition: origin)
        newWindow.sessionId = sessionId
        let newHud = HUDInstance(window: newWindow, panels: [panel])
        session.huds.append(newHud)
        wireHudCallbacks(newHud, sessionId: sessionId)
        newWindow.installPanel(name: name, view: panel.view)
        newWindow.updateTabs([name])
        newWindow.setSessionEnded(session.orphaned)
        newWindow.makeKeyAndOrderFront(nil)

        // 3. Drag-follow + simultaneous reattach detection until mouseUp.
        //    Letting reattach run alongside tear-out means the user
        //    can drop a torn pill directly onto a sibling HUD's
        //    strip without releasing first — and dropping back over
        //    the source HUD's strip cancels the tear-out (the just-
        //    spawned new HUD merges right back where it came from).
        handleHudDragStart(sessionId: sessionId, hudId: newWindow.hudInstanceId)
        beginDragFollow(
            window: newWindow,
            mouseDownPoint: mouseLoc,
            sessionId: sessionId,
            hudId: newWindow.hudInstanceId
        )
    }

    private func beginDragFollow(window: HUDWindow,
                                 mouseDownPoint: NSPoint,
                                 sessionId: String,
                                 hudId: UUID) {
        if let prev = dragMonitor {
            NSEvent.removeMonitor(prev)
            dragMonitor = nil
        }
        let originOffset = NSPoint(
            x: window.frame.origin.x - mouseDownPoint.x,
            y: window.frame.origin.y - mouseDownPoint.y
        )
        // Local monitors preempt the responder chain; returning nil
        // swallows the event so the source pill's tracking can't
        // double-fire while we follow the cursor.
        dragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self, weak window] event in
            guard let self = self else { return event }
            guard let window = window else {
                if let mon = self.dragMonitor {
                    NSEvent.removeMonitor(mon)
                    self.dragMonitor = nil
                }
                return event
            }
            let m = NSEvent.mouseLocation
            if event.type == .leftMouseDragged {
                window.setFrameOrigin(NSPoint(x: m.x + originOffset.x,
                                              y: m.y + originOffset.y))
                // Also probe for a sibling drop target on every
                // drag tick. This is what fuses tear-out + reattach
                // into one gesture.
                self.handleHudDragMove(sessionId: sessionId, hudId: hudId, cursor: m)
                return nil
            }
            if event.type == .leftMouseUp {
                if let mon = self.dragMonitor {
                    NSEvent.removeMonitor(mon)
                    self.dragMonitor = nil
                }
                // Trigger reattach if a target was lit. May close
                // the new HUD entirely, which is what we want for a
                // direct pill-to-sibling-strip drop.
                self.handleHudDragEnd(sessionId: sessionId, hudId: hudId, cursor: m)
                return event
            }
            return event
        }
    }

    // MARK: - HUD wiring

    /// Single point for hooking all of a HUD's callbacks. Used by
    /// both `ensurePrimaryHud` (first-upsert in a session) and
    /// `handleTearOut` (sibling HUD creation).
    private func wireHudCallbacks(_ hud: HUDInstance, sessionId: String) {
        let window = hud.window
        let hudId = hud.id
        window.onCloseRequested = { [weak self] in
            self?.closeHud(sessionId: sessionId, hudId: hudId)
        }
        window.onSelectTab = { [weak self] name in
            self?.switchTab(in: sessionId, to: name)
        }
        window.onCloseTab = { [weak self] name in
            self?.close(sessionId: sessionId, name: name)
        }
        window.onTabContextMenu = { [weak self] name, event in
            self?.showTabMenu(sessionId: sessionId, name: name, event: event, on: window)
        }
        window.onHudContextMenu = { [weak self] event in
            self?.showHudMenu(sessionId: sessionId, hudId: hudId, event: event, on: window)
        }
        window.onSnapshotActivePanel = { [weak self, weak window] in
            guard let self = self, let activeName = window?.activePanelName else { return }
            let item = NSMenuItem(title: "Snapshot", action: nil, keyEquivalent: "")
            item.representedObject = MenuPayload(sessionId: sessionId, name: activeName)
            self.handleSnapshotToDownloads(item)
        }
        window.onTearOutTab = { [weak self] name, event in
            self?.handleTearOut(sessionId: sessionId, hudId: hudId, name: name, event: event)
        }
        window.onTitleBarDragStart = { [weak self] in
            self?.handleHudDragStart(sessionId: sessionId, hudId: hudId)
        }
        window.onTitleBarDragMove = { [weak self] cursor in
            self?.handleHudDragMove(sessionId: sessionId, hudId: hudId, cursor: cursor)
        }
        window.onTitleBarDragEnd = { [weak self] cursor in
            self?.handleHudDragEnd(sessionId: sessionId, hudId: hudId, cursor: cursor)
        }
        // Markup: title-bar Send button → composite + emit; draw mode
        // toggle → suspend/resume renderer interaction on the active
        // panel so panning doesn't drift the underlying content while
        // strokes are being drawn.
        window.onSendActivePanelMarkup = { [weak self] in
            self?.sendActivePanelMarkup(sessionId: sessionId, hudId: hudId)
        }
        window.onDrawModeChanged = { [weak self] on in
            self?.handleDrawModeChanged(sessionId: sessionId, hudId: hudId, on: on)
        }
        window.onCommitStrokes = { [weak self] name, strokes in
            self?.commitStrokes(sessionId: sessionId, hudId: hudId,
                                panel: name, strokes: strokes)
        }
        window.onLoadStrokes = { [weak self] name in
            return self?.loadStrokes(sessionId: sessionId, hudId: hudId, panel: name) ?? []
        }
        window.onResolveActivePanelScroll = { [weak self] name in
            return self?.resolveActivePanelScroll(
                sessionId: sessionId,
                hudId: hudId,
                panel: name
            ) ?? .zero
        }
        window.onResolveArmedFlag = { [weak self] in
            return self?.flag(sessionId: sessionId, key: "markup_events_armed")?.asBool == true
        }
        // Bind the title bar to its owning session and pull the
        // current armed-flag state SYNCHRONOUSLY. This covers the
        // common race: sidecar calls `enable_markup_events` (which
        // sets the flag) BEFORE its first `upsert`, so the flag is
        // already true by the time this HUD is born — the
        // notification observer alone would miss it.
        window.setOwningSessionId(sessionId)
        let armed = flag(sessionId: sessionId, key: "markup_events_armed")?.asBool == true
        window.setArmed(armed)
    }

    /// Persist the overlay's strokes back onto the Panel that owns
    /// them. Called on tab switch + every onStrokesChanged event.
    private func commitStrokes(sessionId: String,
                               hudId: UUID,
                               panel: String,
                               strokes: [MarkupOverlayView.Stroke]) {
        guard let session = sessions[sessionId],
              let hud = session.huds.first(where: { $0.id == hudId }),
              let p = hud.panels.first(where: { $0.name == panel }) else {
            return
        }
        p.strokes = strokes
    }

    /// Fetch the strokes currently stored on a panel so the overlay
    /// can re-load them when the panel becomes active again.
    private func loadStrokes(sessionId: String,
                             hudId: UUID,
                             panel: String) -> [MarkupOverlayView.Stroke] {
        guard let session = sessions[sessionId],
              let hud = session.huds.first(where: { $0.id == hudId }),
              let p = hud.panels.first(where: { $0.name == panel }) else {
            return []
        }
        return p.strokes
    }

    /// Read the active panel's current WebView scroll position so the
    /// overlay re-anchors loaded strokes against it. Returns zero for
    /// non-WebView renderers (ImageRenderer) — scroll-following is a
    /// WebView-only feature today.
    private func resolveActivePanelScroll(sessionId: String,
                                          hudId: UUID,
                                          panel: String) -> NSPoint {
        guard let session = sessions[sessionId],
              let hud = session.huds.first(where: { $0.id == hudId }),
              let p = hud.panels.first(where: { $0.name == panel }),
              let web = p.renderer as? WebViewPanelRenderer else {
            return .zero
        }
        return web.currentScroll
    }

    /// Draw mode toggled on/off — fan the signal out to the active
    /// renderer so panzoom + scroll-magnification stop fighting the
    /// user's drawing.
    private func handleDrawModeChanged(sessionId: String,
                                       hudId: UUID,
                                       on: Bool) {
        guard let session = sessions[sessionId],
              let hud = session.huds.first(where: { $0.id == hudId }),
              let activeName = hud.window.activePanelName,
              let panel = hud.panels.first(where: { $0.name == activeName }) else {
            return
        }
        if on {
            panel.renderer.suspendInteraction()
        } else {
            panel.renderer.resumeInteraction()
        }
    }

    // MARK: - Drag-to-reattach

    /// Called when a HUD's title-bar drag gesture starts. Wipes any
    /// stale reattach target so the new drag begins clean.
    func handleHudDragStart(sessionId: String, hudId: UUID) {
        reattachTarget = nil
    }

    /// Called on every drag event with the cursor in screen coords.
    /// Finds a sibling HUD (same session, different id) whose drop
    /// zone contains the cursor; highlights it; un-highlights any
    /// previous candidate.
    func handleHudDragMove(sessionId: String, hudId: UUID, cursor: NSPoint) {
        guard let session = sessions[sessionId] else { return }
        let candidate = session.huds.first(where: { hud in
            hud.id != hudId && hud.window.containsDropPoint(cursor)
        })
        let newTarget: (sessionId: String, hudId: UUID)? = candidate.map {
            (sessionId: sessionId, hudId: $0.id)
        }
        // Detect target change → toggle highlights.
        let prev = reattachTarget
        if prev?.hudId != newTarget?.hudId {
            if let prev = prev,
               let prevHud = session.huds.first(where: { $0.id == prev.hudId }) {
                prevHud.window.setReattachHighlight(false)
            }
            if let cand = candidate {
                cand.window.setReattachHighlight(true)
            }
        }
        reattachTarget = newTarget
    }

    /// Called on mouseUp at the drag's final cursor location. If a
    /// drop target was lit, merges all of the source HUD's panels
    /// into the target and closes the source HUD. Otherwise, the
    /// HUD just stays where it was dropped (the move already happened
    /// during the drag).
    func handleHudDragEnd(sessionId: String, hudId: UUID, cursor: NSPoint) {
        guard let session = sessions[sessionId] else {
            reattachTarget = nil
            return
        }
        // Clear all highlights defensively.
        for hud in session.huds { hud.window.setReattachHighlight(false) }
        defer { reattachTarget = nil }
        guard let target = reattachTarget,
              target.sessionId == sessionId,
              let sourceHud = session.huds.first(where: { $0.id == hudId }),
              let targetHud = session.huds.first(where: { $0.id == target.hudId }),
              sourceHud.id != targetHud.id else {
            return
        }
        performReattach(source: sourceHud, target: targetHud, in: session)
    }

    /// Move all panels from `source` into `target`, then close
    /// `source`. The last-merged panel becomes the active one in the
    /// target (so the user sees what they just dropped).
    private func performReattach(source: HUDInstance, target: HUDInstance, in session: SessionState) {
        let movedPanels = source.panels
        source.panels.removeAll()
        for panel in movedPanels {
            source.window.removePanel(panel.name)
            target.window.installPanel(name: panel.name, view: panel.view)
            target.panels.append(panel)
        }
        target.window.updateTabs(target.panels.map(\.name))
        if let last = movedPanels.last {
            target.window.setActivePanel(last.name)
        }
        closeHudInstance(source, in: session)
        NSLog("QuickShow: reattached \(movedPanels.count) panel(s) into HUD \(target.id)")
    }

    // MARK: - Right-click menu actions

    @objc func handleCloseTab(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? MenuPayload else { return }
        close(sessionId: payload.sessionId, name: payload.name)
    }

    @objc func handlePromote(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? MenuPayload,
              let session = sessions[payload.sessionId],
              let (sourceHud, panel) = locate(in: session, name: payload.name),
              let promoteController = promoteController else { return }
        let panelSize = sourceHud.window.frame.size
        promoteController.promote(
            name: payload.name,
            sessionId: payload.sessionId,
            detachFrom: sourceHud.window,
            view: panel.view,
            panelSize: panelSize
        ) { [weak self] in
            self?.removePanelAfterPromote(sessionId: payload.sessionId, name: payload.name)
        }
        // View is now in the promoted window; remove from the source HUD.
        sourceHud.window.removePanel(payload.name)
        if let idx = sourceHud.panels.firstIndex(where: { $0.name == payload.name }) {
            sourceHud.panels.remove(at: idx)
        }
        if sourceHud.panels.isEmpty {
            closeHudInstance(sourceHud, in: session)
        } else {
            sourceHud.window.updateTabs(sourceHud.panels.map(\.name))
            if sourceHud.window.activePanelName == nil, let first = sourceHud.panels.first {
                sourceHud.window.setActivePanel(first.name)
            }
        }
    }

    private func removePanelAfterPromote(sessionId: String, name: String) {
        // No-op for now. Placeholder for v0.2 "demote back to HUD."
        _ = sessionId; _ = name
    }

    @objc func handleSnapshotToDownloads(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? MenuPayload,
              let session = sessions[payload.sessionId],
              let (_, panel) = locate(in: session, name: payload.name) else { return }
        Task {
            do {
                let data = try await panel.renderer.snapshot()
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd-HHmmss"
                let stamp = formatter.string(from: Date())
                let url = downloads.appendingPathComponent("quickshow-\(payload.name)-\(stamp).png")
                try data.write(to: url)
                NSLog("QuickShow: snapshot saved to \(url.path)")
            } catch {
                NSLog("QuickShow: snapshot to Downloads failed: \(error)")
            }
        }
    }

    @objc func handleCloseAll(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? HudPayload else { return }
        closeHud(sessionId: payload.sessionId, hudId: payload.hudId)
    }

    @objc func handleOpacity(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? OpacityPayload,
              let session = sessions[payload.sessionId],
              let hud = session.huds.first(where: { $0.id == payload.hudId }) else { return }
        hud.window.alphaValue = CGFloat(payload.percent) / 100.0
    }

    private func showTabMenu(sessionId: String, name: String, event: NSEvent, on hud: HUDWindow) {
        let menu = HUDContextMenu.tabMenu(
            sessionId: sessionId,
            name: name,
            target: self,
            close: #selector(handleCloseTab(_:)),
            promote: #selector(handlePromote(_:)),
            snapshotToDownloads: #selector(handleSnapshotToDownloads(_:))
        )
        if let contentView = hud.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
        }
    }

    private func showHudMenu(sessionId: String, hudId: UUID, event: NSEvent, on hud: HUDWindow) {
        let menu = HUDContextMenu.hudMenu(
            sessionId: sessionId,
            hudId: hudId,
            target: self,
            closeAll: #selector(handleCloseAll(_:)),
            opacity: #selector(handleOpacity(_:))
        )
        if let contentView = hud.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
        }
    }

    // MARK: - Helpers

    /// Find the panel and its owning HUD anywhere in a session. Used
    /// by every verb that operates on a named panel.
    private func locate(in session: SessionState, name: String) -> (HUDInstance, Panel)? {
        for hud in session.huds {
            if let p = hud.panels.first(where: { $0.name == name }) {
                return (hud, p)
            }
        }
        return nil
    }

    /// Get or create the primary HUD for a session. Called only from
    /// `upsert` when the named slot doesn't yet exist anywhere.
    private func ensurePrimaryHud(in session: SessionState) -> HUDInstance {
        if let primary = session.huds.first { return primary }
        let window = HUDWindow(initialPosition: HUDWindow.cascadeTopRight(session.cascadeIndex))
        window.sessionId = session.id
        let hud = HUDInstance(window: window)
        session.huds.append(hud)
        wireHudCallbacks(hud, sessionId: session.id)
        window.setSessionEnded(session.orphaned)
        window.makeKeyAndOrderFront(nil)
        return hud
    }

    /// Close a HUD: tear down its window and remove from `session.huds`.
    /// `isReleasedWhenClosed = false` on HUDWindow means this order is
    /// safe — the window won't dangle even if removed before close.
    private func closeHudInstance(_ hud: HUDInstance, in session: SessionState) {
        hud.window.close()
        session.huds.removeAll(where: { $0.id == hud.id })
    }

    private func ensureSession(_ sessionId: String) -> SessionState {
        if let s = sessions[sessionId] {
            if s.orphanTimerTask != nil || s.orphaned {
                s.orphanTimerTask?.cancel()
                s.orphanTimerTask = nil
                if s.orphaned {
                    s.orphaned = false
                    for hud in s.huds { hud.window.setSessionEnded(false) }
                }
            }
            return s
        }
        let idx = sessionsRegisteredOrder
        sessionsRegisteredOrder += 1
        let s = SessionState(id: sessionId, cascadeIndex: idx)
        sessions[sessionId] = s
        return s
    }
}

struct PanelDescriptor: Sendable {
    let name: String
    let contentType: String
    let width: Double
    let height: Double
}

struct RenderFailureWithSnapshot: Error {
    let failure: RenderFailure
    let snapshot: Data
}

extension Notification.Name {
    /// Posted after a per-session flag changes (e.g. via the
    /// `set_session_flag` control verb). userInfo carries `sessionId`
    /// and `key`. HUD UI (Send button gating) subscribes to refresh
    /// when relevant flags flip.
    static let quickShowSessionFlagChanged = Notification.Name("QuickShowSessionFlagChanged")
}
