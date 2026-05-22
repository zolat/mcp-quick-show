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

    /// Reserved prefix for groups that hold user-initiated HUDs
    /// (menu-bar "Open URL…" / "Open File…" → AppDelegate →
    /// `userUpsert`). Each user share gets its own group named
    /// `user-share-<random>` so the separate-HUD-per-share UX is
    /// preserved (each share is its own HUD with its own Space
    /// placement). HUDs born here migrate into a Claude-specified
    /// group via `claimShare(...)` once the user pastes the share
    /// token into Claude and Claude calls `get_share(<id>, group: ...)`.
    static let userSharesGroupPrefix = "user-share-"

    private let renderers: RendererRegistry
    weak var promoteController: PromoteToWindowController?

    /// One MCP-session's worth of state. After tear-out a session can
    /// host multiple HUDs; `huds[0]` is the "primary" — the one new
    /// `upsert(name)`-with-novel-name calls append to.
    final class GroupState {
        let id: String
        let cascadeIndex: Int
        var huds: [HUDInstance] = []
        var orphanTimerTask: Task<Void, Never>?
        var orphaned: Bool = false
        /// Sidecar's `parent_pid` from `hello`. The root of the
        /// process-tree walk used by `SpaceResolver` to find the
        /// terminal window hosting this Claude session. Optional
        /// because legacy callers and CLI smokes may not provide it.
        /// Refreshed on reconnect — a `claude --resume` against the
        /// same conversation UUID may come from a new terminal.
        var parentPid: pid_t?
        /// Last successfully resolved Space id for this session.
        /// Lets `.claudeSpace` placement degrade gracefully when the
        /// terminal becomes temporarily invisible (minimised, full-
        /// screen sibling app) — we re-use the last known Space
        /// rather than dumping the panel on whichever Space the user
        /// happens to be on.
        var lastResolvedSpaceID: UInt64?
        /// Generic per-group flags. First consumer: `markup_events_armed`.
        var flags: [String: SessionFlagValue] = [:]
        /// The MCP session that most recently wrote into this group.
        /// Used for orphan-grace: when that MCP session disconnects
        /// (DELETE or idle-timeout sweep), groups whose lastWriter
        /// matches trigger the existing orphan timer. Multiple MCP
        /// sessions can write to the same group; only the last writer
        /// is recorded, but the orphan signal is best-effort anyway —
        /// the worst case is a stale badge that clears on the next
        /// write.
        var lastWriterMcpSession: String?
        /// Lazy NDJSON writer for markup events. Created on first
        /// emit; the file lives at `MarkupPaths.eventsLog(group)`.
        lazy var eventWriter: EventLogWriter = EventLogWriter(group: id)

        init(id: String, cascadeIndex: Int) {
            self.id = id
            self.cascadeIndex = cascadeIndex
        }
    }

    /// One HUD window inside a group, with its own ordered panels.
    /// Phase 2: every HUD belongs to exactly one group (= the
    /// GroupState in `groups[hud.group]`). Tear-out spawns a sibling
    /// HUD in the same group; claim_share migrates a HUD across
    /// groups (and flips this field).
    final class HUDInstance {
        let id: UUID
        let window: HUDWindow
        var panels: [Panel]
        /// The group this HUD belongs to. Non-optional in Phase 2:
        /// the map keys onto this. Mutable so `claim_share` can
        /// re-target a HUD across groups.
        var group: String
        /// The HUD-level description paragraph (last-writer-wins
        /// among upserts that route here). `nil` means unset; the
        /// banner's "group line" shows `""` in that case (collapsed).
        var hudDescription: String?

        init(window: HUDWindow, panels: [Panel] = [], group: String) {
            self.id = window.hudInstanceId
            self.window = window
            self.panels = panels
            self.group = group
        }
    }

    final class Panel {
        let name: String
        let contentType: String
        let renderer: any PanelRenderer
        let view: NSView
        /// Markup strokes the user has drawn over this panel. Lives on
        /// Panel (the unit that travels under tear-out/reattach) so
        /// annotations follow the content across HUDs. Mirrored to the
        /// in-WebView `<canvas>` via `setStrokes` on each render so
        /// strokes survive content updates; the JS bridge keeps this
        /// array in sync on every pen-up / Cmd+Z.
        var strokes: [MarkupStroke] = []
        /// True while a `markup_sent` artifact has been recorded for
        /// this panel's current render and the panel hasn't been
        /// re-rendered yet. Suppresses the close → `markup_dismissed`
        /// emission that would otherwise double-fire after Send.
        /// Reset to false on each re-render in `renderPanel`.
        var markupSentPending: Bool = false
        /// Per-tab framing line shown in the HUD's description banner
        /// while this panel is active. `nil` = no banner line for this
        /// panel; `""` is treated the same (cleared).
        var description: String?

        init(name: String, contentType: String, renderer: any PanelRenderer, view: NSView) {
            self.name = name
            self.contentType = contentType
            self.renderer = renderer
            self.view = view
        }
    }

    /// All known groups, keyed by group identifier. Each GroupState
    /// owns the HUDs + flags + events writer for a content namespace.
    /// MCP sessions don't have their own state here — `group` is the
    /// canonical key (defaulting to `mcpSessionId` when callers omit
    /// the wire-level `group` arg).
    private(set) var groups: [String: GroupState] = [:]
    private var groupsRegisteredOrder = 0

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

    func registerGroup(_ sessionId: String, parentPid: pid_t? = nil) {
        if let existing = groups[sessionId] {
            existing.orphanTimerTask?.cancel()
            existing.orphanTimerTask = nil
            if existing.orphaned {
                existing.orphaned = false
                for hud in existing.huds { hud.window.setSessionEnded(false) }
                NSLog("QuickShow: session \(sessionId) reattached (orphan badge cleared)")
            }
            // Refresh parent_pid on reconnect — a `claude --resume`
            // (or a fresh sidecar against the same conversation UUID)
            // can come from a different terminal, so the previous
            // pid is stale. Skip when caller passed nil to preserve
            // whatever we already had.
            if let pid = parentPid { existing.parentPid = pid }
            return
        }
        let idx = groupsRegisteredOrder
        groupsRegisteredOrder += 1
        let state = GroupState(id: sessionId, cascadeIndex: idx)
        state.parentPid = parentPid
        groups[sessionId] = state
    }

    func sidecarDisconnected(sessionId: String) {
        // Legacy entry: the stdio sidecar disconnected. Pre-Phase 2
        // each sidecar mapped 1:1 to a group, so this just starts the
        // orphan timer on the matching GroupState directly. Used by
        // test smokes and ControlServer's TCP path (both gone in 2.5).
        startOrphanTimer(for: sessionId)
    }

    /// Called by the HTTP router when an MCP session is removed —
    /// either via an explicit DELETE or via the cleanup loop's
    /// idle-timeout sweep. Walks groups for any whose
    /// `lastWriterMcpSession` matches and starts the orphan-grace
    /// timer on each. A subsequent write into the group (by a fresh
    /// MCP session, possibly post-`claude --resume`) cancels the
    /// timer via `ensureGroup`'s reattach path.
    func mcpSessionDisconnected(mcpSessionId: String) {
        for (groupKey, state) in groups where state.lastWriterMcpSession == mcpSessionId {
            NSLog("QuickShow: MCP session \(mcpSessionId) dropped — starting orphan grace for group \(groupKey)")
            startOrphanTimer(for: groupKey)
        }
    }

    /// Common orphan-grace timer body. Cancels any prior timer for
    /// the group, schedules a new one to flip the badge after the
    /// grace window. `ensureGroup` clears both the timer and the
    /// flag when a fresh write lands.
    private func startOrphanTimer(for groupKey: String) {
        guard let state = groups[groupKey] else { return }
        guard !state.huds.isEmpty else { return }
        state.orphanTimerTask?.cancel()
        let grace = Self.reconnectGraceSeconds
        state.orphanTimerTask = Task { [weak self, weak state] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self = self, let state = state,
                      self.groups[state.id] === state else { return }
                state.orphaned = true
                for hud in state.huds { hud.window.setSessionEnded(true) }
                NSLog("QuickShow: group \(state.id) orphan grace expired — badge on \(state.huds.count) HUD(s)")
            }
        }
    }

    // MARK: - Panel verbs

    /// Render into a user-initiated HUD. Auto-arms `markup_events_armed`
    /// for the reserved `userWindowsSessionID` session (so the user can
    /// flip into draw mode and annotate just like an agent-armed HUD),
    /// then routes through normal `upsert`. After the first render
    /// lands, the HUD's "always-show Send" flag is flipped on so the
    /// title bar's idle layout exposes a Send button without forcing
    /// draw mode — URL/image panels stay interactive. Draw mode is
    /// still one click away via the markup pencil.
    ///
    /// `autoEnterDrawMode` flips the HUD into draw mode immediately
    /// after the first render. Used by the Sketch Pad flow — the user
    /// opened a blank surface explicitly to draw on, so making them
    /// click the pencil first would be friction. URL / file callers
    /// leave this at `false` so their content stays interactive
    /// (scroll a page, click a link) by default.
    func userUpsert(name: String,
                    contentType: String,
                    form: String,
                    body: String,
                    width: Double? = nil,
                    displayName: String? = nil,
                    autoEnterDrawMode: Bool = false) async throws -> (RenderResult, Data) {
        // Each user-initiated HUD lives in its own group so the
        // separate-HUD-per-share UX is preserved. The shareId carries
        // through claim_share — see recordShareSent + claimShare.
        let group = "\(Self.userSharesGroupPrefix)\(ShareID.mint())"
        setFlag(group: group, key: "markup_events_armed", value: .bool(true))
        let result = try await upsert(
            sessionId: group,
            name: name,
            contentType: contentType,
            form: form,
            body: body,
            width: width,
            group: group,
            description: displayName
        )
        if let groupState = groups[group],
           let (hud, _) = locate(in: groupState, name: name) {
            hud.window.setAlwaysShowSend(true)
            if autoEnterDrawMode && !hud.window.isInDrawMode {
                hud.window.toggleDrawMode()
            }
        }
        return result
    }

    func upsert(sessionId: String,
                name: String,
                contentType: String,
                form: String,
                body: String,
                width: Double? = nil,
                group: String? = nil,
                description: String? = nil,
                hudDescription: String? = nil) async throws -> (RenderResult, Data) {
        // `group` is the canonical key (Phase 2). When callers omit it
        // (legacy AppDelegate test smokes; pre-flip MCP handlers),
        // default to the sessionId so behaviour matches the per-MCP-
        // session storage that existed before the group flip.
        let groupKey = group ?? sessionId
        let session = ensureGroup(groupKey)
        // Record this MCP session as the lastWriter — used by
        // orphan-grace when the router signals the MCP session has
        // dropped (DELETE or idle-timeout). Multiple MCP sessions
        // writing to the same group rotate this; the live one always
        // wins.
        session.lastWriterMcpSession = sessionId

        // Locate the panel across all HUDs first (in-place update path).
        if let (hud, panel) = locate(in: session, name: name) {
            // `group` on update calls is intentionally ignored — panels
            // are sticky to the HUD where they were first created.
            // `description` / `hud_description` may still apply.
            applyDescriptionFields(
                hud: hud, panel: panel,
                description: description, hudDescription: hudDescription
            )
            if panel.contentType == contentType {
                return try await renderPanel(panel: panel, hud: hud,
                                             name: name, contentType: contentType,
                                             form: form, body: body, width: width)
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
            newPanel.description = panel.description
            wireStrokePersistence(renderer: renderer, sessionId: groupKey, panelName: name)
            wirePanelEvents(renderer: renderer, sessionId: groupKey, panelName: name)
            let idx = hud.panels.firstIndex(where: { $0.name == name })!
            hud.panels[idx] = newPanel
            hud.window.installPanel(name: name, view: view, description: newPanel.description ?? "")
            return try await renderPanel(panel: newPanel, hud: hud,
                                         name: name, contentType: contentType,
                                         form: form, body: body, width: width)
        }

        // Novel name → the group's primary HUD. Phase 2: HUD discovery
        // within a group is now trivial (one HUD per group, born on
        // first upsert; tear-out spawns sibling HUDs that route to the
        // same group). Subsequent `group` distinctions happen via the
        // groups map key, not within a session's HUD list.
        let hud = ensureHud(in: session, group: groupKey)
        guard let renderer = renderers.make(forContentType: contentType) else {
            throw RenderFailure(
                message: "no renderer registered for content_type '\(contentType)'",
                line: nil
            )
        }
        let view = renderer.makeView()
        let panel = Panel(name: name, contentType: contentType, renderer: renderer, view: view)
        if let d = description { panel.description = d }
        wireStrokePersistence(renderer: renderer, sessionId: groupKey, panelName: name)
        wirePanelEvents(renderer: renderer, sessionId: groupKey, panelName: name)
        hud.panels.append(panel)
        hud.window.installPanel(name: name, view: view, description: panel.description ?? "")
        if let h = hudDescription {
            hud.hudDescription = h.isEmpty ? nil : h
            hud.window.setHudDescription(h)
        } else if let existing = hud.hudDescription {
            // Re-apply existing HUD description in case the banner was
            // just spawned (covers first-render-after-create paths).
            hud.window.setHudDescription(existing)
        }
        return try await renderPanel(panel: panel, hud: hud,
                                     name: name, contentType: contentType,
                                     form: form, body: body, width: width)
    }

    /// Apply optional per-panel + HUD-level description fields. `nil`
    /// means "leave alone"; `""` means "clear"; any other string sets.
    /// Used by the same-name (in-place update) branch of `upsert` —
    /// the novel-name branch threads these through `installPanel` and
    /// `setHudDescription` directly so the banner reflects the new
    /// values immediately on first render.
    private func applyDescriptionFields(
        hud: HUDInstance, panel: Panel,
        description: String?, hudDescription: String?
    ) {
        if let d = description {
            panel.description = d.isEmpty ? nil : d
            hud.window.setPanelDescription(d, for: panel.name)
        }
        if let h = hudDescription {
            hud.hudDescription = h.isEmpty ? nil : h
            hud.window.setHudDescription(h)
        }
    }

    /// Hook a renderer's markup-canvas bridge so strokes captured in
    /// the JS-side `<canvas>` mirror into `Panel.strokes` on every
    /// change. Image + HTML + template renderers all subclass
    /// `WebViewPanelRenderer`, so this works uniformly.
    ///
    /// The closures look up `(hud, panel)` via `locate(in:name:)` at
    /// call time so they follow the panel across tear-out / reattach.
    private func wireStrokePersistence(renderer: any PanelRenderer, sessionId: String, panelName: String) {
        guard let web = renderer as? WebViewPanelRenderer else { return }
        web.onStrokesChanged = { [weak self] strokes in
            guard let self = self,
                  let session = self.groups[sessionId],
                  let (hud, p) = self.locate(in: session, name: panelName) else { return }
            p.strokes = strokes
            // Only refresh title-bar UI if THIS panel is the active
            // one in its HUD — strokes added on a hidden tab still
            // mirror into Panel.strokes (for when the user switches
            // back) but don't change the visible button state.
            if hud.window.activePanelName == panelName {
                hud.window.setActivePanelHasStrokes(!strokes.isEmpty)
            }
        }
        web.onMarkupEscape = { [weak self] in
            guard let self = self,
                  let session = self.groups[sessionId],
                  let (hud, _) = self.locate(in: session, name: panelName) else { return }
            if hud.window.isInDrawMode {
                hud.window.toggleDrawMode()
            }
        }
    }

    /// Hook a renderer's `panelEvent` bridge so payloads emitted by
    /// `window.quickshow.emit(...)` land in the session's events log
    /// as `panel_event` NDJSON lines.
    ///
    /// Two filters before persistence:
    /// 1. Arming flag — `session.flags["panel_events_armed"]?.asBool`
    ///    must be true. Symmetric with how `markup_events_armed` gates
    ///    the Send button; lets the sidecar opt in per-session.
    /// 2. Token bucket — `PanelEventThrottle` caps emission at
    ///    `~20/s/panel` and emits a 1Hz `panel_event_dropped` summary
    ///    line when drops occur. Protects Monitor (which auto-stops on
    ///    high event volume) from a misbehaving page.
    private func wirePanelEvents(renderer: any PanelRenderer, sessionId: String, panelName: String) {
        guard let web = renderer as? WebViewPanelRenderer else { return }
        let throttle = PanelEventThrottle(panel: panelName)
        web.onPanelEvent = { [weak self] payload in
            guard let self = self,
                  let session = self.groups[sessionId] else { return }
            guard session.flags["panel_events_armed"]?.asBool == true else { return }
            throttle.admit(payload: payload, writer: session.eventWriter)
        }
    }

    private func renderPanel(panel: Panel,
                             hud: HUDInstance,
                             name: String,
                             contentType: String,
                             form: String,
                             body: String,
                             width: Double? = nil) async throws -> (RenderResult, Data) {
        hud.window.setActivePanel(name)
        hud.window.updateTabs(hud.panels.map(\.name))
        // A re-render resets the "send → close" guard: after Send the
        // panel held `markupSentPending = true` so a follow-on close
        // wouldn't emit a phantom `markup_dismissed`. A re-render is a
        // fresh round of content, so the next close on it IS a real
        // dismissal.
        panel.markupSentPending = false
        // Strokes survive re-render under the new in-DOM canvas
        // architecture — the user uses the ⌫ button to clear them.
        let payload = PanelPayload(
            name: name,
            contentType: contentType,
            form: form,
            body: body,
            width: width
        )
        do {
            let result = try await panel.renderer.update(payload: payload)
            // Replay persisted strokes into the WebView's in-DOM
            // canvas. Required because:
            //  - HTMLRenderer / ImageRenderer reload the document on
            //    each update — JS state (including __qsMarkup's
            //    `strokes` array) is wiped.
            //  - Template renderers (markdown/svg/mermaid) keep JS
            //    state across __quickshow_render calls, so the replay
            //    is a redundant but cheap no-op.
            // The HUD window stays at whatever size the user has it.
            // Canvas dimensions live inside the renderer's scroll
            // view now — pan/zoom changes how much of the canvas is
            // visible, never reflows content.
            if let web = panel.renderer as? WebViewPanelRenderer,
               !panel.strokes.isEmpty {
                await web.setStrokes(panel.strokes)
            }
            if hud.window.activePanelName == name {
                hud.window.setActivePanelHasStrokes(!panel.strokes.isEmpty)
            }
            let snapshot = try await panel.renderer.snapshot()
            return (result, snapshot)
        } catch let renderFailure as RenderFailure {
            let errorSnapshot = (try? await panel.renderer.snapshot()) ?? Data()
            throw RenderFailureWithSnapshot(failure: renderFailure, snapshot: errorSnapshot)
        }
    }

    func close(sessionId: String, name: String) {
        guard let session = groups[sessionId] else { return }
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
        guard let session = groups[sessionId],
              let (hud, _) = locate(in: session, name: name) else { return }
        hud.window.setActivePanel(name)
        hud.window.updateTabs(hud.panels.map(\.name))
    }

    /// Close every HUD belonging to the session.
    func closeAllPanels(in sessionId: String) {
        guard let session = groups[sessionId] else { return }
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
        guard let session = groups[sessionId],
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
        guard let session = groups[sessionId],
              let (hud, panel) = locate(in: session, name: name) else {
            return nil
        }
        let snapshot = try await panel.renderer.snapshot()
        let size = hud.window.frame.size
        return (RenderResult(width: Double(size.width), height: Double(size.height)), snapshot)
    }

    // MARK: - Flags

    /// Set a generic per-group flag. The group is auto-created if not
    /// yet known; this matches `upsert`'s behaviour so callers can arm
    /// flags before the first render call lands.
    func setFlag(group: String, key: String, value: SessionFlagValue) {
        let groupState = ensureGroup(group)
        groupState.flags[key] = value
        NSLog("QuickShow: group \(group) flag \(key) = \(value)")
        NotificationCenter.default.post(
            name: .quickShowSessionFlagChanged,
            object: nil,
            userInfo: ["group": group, "key": key]
        )
    }

    /// Read a per-group flag. Returns `nil` if unset or group unknown.
    func flag(group: String, key: String) -> SessionFlagValue? {
        groups[group]?.flags[key]
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
        let session = ensureGroup(sessionId)
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

    /// Snapshot the active panel's WebView — which already includes
    /// the in-DOM markup canvas pixels — and emit `markup_sent` with
    /// the resulting PNG. No separate composite step: the strokes are
    /// part of the rendered document. Wired to the title-bar Send
    /// button in `wireHudCallbacks`.
    ///
    /// Two flavours:
    ///   - Agent-panel session: writes `<artifact-id>.png` into the
    ///     session's artifacts dir + appends a `markup_sent` line to
    ///     `events.ndjson` so the agent's tail picks it up.
    ///   - User-share group (`user-share-<random>`): no agent is
    ///     listening, so we instead write a share PNG + JSON to
    ///     `MarkupPaths.sharesBaseDir`, put `[quickshow-share:<id>]`
    ///     on the clipboard, and pop an in-bar confirmation. The HUD
    ///     lives on; a future `get_share(<id>, group: …)` migrates it
    ///     into a Claude-specified group.
    func sendActivePanelMarkup(sessionId: String, hudId: UUID) {
        guard let session = groups[sessionId],
              let hud = session.huds.first(where: { $0.id == hudId }),
              let activeName = hud.window.activePanelName,
              let panel = hud.panels.first(where: { $0.name == activeName }),
              let web = panel.renderer as? WebViewPanelRenderer else {
            return
        }
        _ = session  // used only for the locate-by-id chain above
        let isUserShare = sessionId.hasPrefix(Self.userSharesGroupPrefix)
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                // Exit draw mode first so the JS canvas hides its
                // crosshair cursor before we snapshot. The strokes
                // themselves remain visible (we only flip pointer-
                // events; the canvas content stays painted).
                await web.exitDrawMode()
                let png = try await SnapshotService.snapshotWebViewFullDoc(web.webView)
                if isUserShare {
                    self.recordShareSent(
                        hud: hud,
                        panel: panel,
                        contentType: panel.contentType,
                        pngBytes: png
                    )
                } else {
                    _ = self.recordMarkupSent(
                        sessionId: sessionId,
                        panel: activeName,
                        pngBytes: png
                    )
                }
                // Strokes stay on screen as visible proof the Send
                // took. The user can clear with ⌫ or keep iterating;
                // they survive re-render now (see renderPanel).
                //
                // User-share branch: skip the auto-toggle out of
                // draw mode. The title bar is now in
                // `.shareConfirmation` mode (set by recordShareSent
                // → hud.window.showShareConfirmation); toggleDrawMode
                // would clobber that. The strip itself restores the
                // prior mode when it auto-dismisses or the user hits
                // ✕, so draw mode resumes naturally for follow-on
                // strokes.
                if !isUserShare && hud.window.isInDrawMode {
                    hud.window.toggleDrawMode()
                }
            } catch {
                NSLog("QuickShow: sendActivePanelMarkup snapshot failed: \(error)")
            }
        }
    }

    /// Persist a user-windows share — flattened PNG + JSON metadata
    /// next to it under `MarkupPaths.sharesBaseDir`. Copies the
    /// `[quickshow-share:<id>]` token to the clipboard and surfaces a
    /// brief NSAlert. The HUD itself stays on screen; a future
    /// `claim_share` (called from Claude's `get_share`) is what
    /// actually migrates it into the Claude session.
    private func recordShareSent(
        hud: HUDInstance,
        panel: Panel,
        contentType: String,
        pngBytes: Data
    ) {
        let shareId = ShareID.mint()
        let meta = ShareMetadata(
            sourcePanelName: panel.name,
            sourceHudId: hud.id.uuidString,
            contentType: contentType,
            displayName: panel.description,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        do {
            try MarkupPaths.ensureShareDirs()
            try pngBytes.write(to: MarkupPaths.sharePNG(id: shareId))
            let metaData = try JSONEncoder().encode(meta)
            try metaData.write(to: MarkupPaths.shareMeta(id: shareId))
        } catch {
            NSLog("QuickShow: recordShareSent failed to write share: \(error)")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't save share"
            alert.informativeText = String(describing: error)
            alert.addButton(withTitle: "OK")
            _ = alert.runModal()
            return
        }
        let token = "[quickshow-share:\(shareId)]"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        NSLog("QuickShow: share \(shareId) → clipboard (\(token))")
        // Non-modal in-bar confirmation: selectable token, Copy
        // button, ✕ dismiss, 6 s auto-fade. Replaces the prior modal
        // NSAlert so the user can switch to Claude without first
        // dismissing a popup.
        hud.window.showShareConfirmation(token: token)
    }

    // MARK: - Share claim (user-windows → Claude session migration)

    /// Outcome surfaced back to the sidecar's `get_share` MCP tool.
    struct ClaimedShare {
        let panelName: String
        let contentType: String
    }

    /// First-come-first-served claim of a user-initiated share.
    ///
    /// The user opened a HUD via the menu bar (lives in its own
    /// `user-share-<random>` group), optionally marked it up, and hit
    /// Send — which wrote a flattened PNG + JSON sidecar under
    /// `MarkupPaths.sharesBaseDir` and put a `[quickshow-share:<id>]`
    /// token on the clipboard. Claude reads the token from the user's
    /// pasted message and calls `get_share(<id>, group: ...)`, which
    /// forwards here with `targetGroup` = where Claude wants the
    /// migrated HUD to live.
    ///
    /// Side effects:
    ///   1. The matching HUDInstance is detached from its user-share
    ///      group and re-parented to `targetGroup` — all callbacks
    ///      rewired so future Send / draw-mode / panel-event traffic
    ///      lands in the target group's events log + flags.
    ///   2. The share PNG moves from `shares/<id>.png` into the
    ///      target group's artifacts dir at `<id>.png`. `get_share`
    ///      then reads it through `MarkupPaths.artifact(targetGroup,
    ///      id: <id>)` — same discipline as `get_markup` — and moves
    ///      it to `.consumed/` after returning the image to the model.
    ///   3. The share JSON moves to `shares/.consumed/<id>.json` so a
    ///      second `claim_share(<same-id>)` from another group
    ///      cleanly returns "already claimed."
    ///   4. The HUD's `alwaysShowSend` flips off — the window is in a
    ///      Claude group now, so Send follows normal `armed && drawing`
    ///      gating (Claude arms via `enable_markup_events(group:)`).
    ///
    /// The atomic point is step (3) — we move the JSON early, so a
    /// concurrent claim from another group sees it gone and fails
    /// the same way a second claim of an already-consumed share does.
    func claimShare(shareID: String, targetGroup: String) throws -> ClaimedShare {
        guard ShareID.isValid(shareID) else {
            throw ControlError.invalidPayload("share_id is malformed (expected \(ShareID.length) lowercase-hex chars)")
        }
        let fm = FileManager.default
        let metaURL = MarkupPaths.shareMeta(id: shareID)
        let pngURL = MarkupPaths.sharePNG(id: shareID)
        guard fm.fileExists(atPath: metaURL.path) else {
            throw ControlError.invalidPayload("share '\(shareID)' not found (already claimed or never existed)")
        }
        let metaData: Data
        do {
            metaData = try Data(contentsOf: metaURL)
        } catch {
            throw ControlError.invalidPayload("failed to read share metadata: \(error.localizedDescription)")
        }
        let meta: ShareMetadata
        do {
            meta = try JSONDecoder().decode(ShareMetadata.self, from: metaData)
        } catch {
            throw ControlError.invalidPayload("share metadata malformed: \(error.localizedDescription)")
        }
        // Walk all user-share groups for the source HUD. Each user
        // share is its own group keyed by `user-share-<random>`, so
        // we scan only the prefixed entries — should be a handful at
        // most.
        var sourceGroupKey: String?
        var sourceGroupState: GroupState?
        var sourceHud: HUDInstance?
        for (key, state) in groups where key.hasPrefix(Self.userSharesGroupPrefix) {
            if let hud = state.huds.first(where: { $0.id.uuidString == meta.sourceHudId }) {
                sourceGroupKey = key
                sourceGroupState = state
                sourceHud = hud
                break
            }
        }
        guard let sourceGroupKey,
              let sourceGroupState,
              let sourceHud,
              sourceHud.panels.contains(where: { $0.name == meta.sourcePanelName }) else {
            throw ControlError.invalidPayload("source HUD for share '\(shareID)' is gone (user closed it before the claim landed)")
        }

        // Atomic claim — move the metadata to .consumed/ before any
        // migration. If this fails, another claim got there first.
        do {
            try MarkupPaths.ensureShareDirs()
            try fm.moveItem(at: metaURL, to: MarkupPaths.consumedShareMeta(id: shareID))
        } catch {
            throw ControlError.invalidPayload("share '\(shareID)' already claimed")
        }

        // Migrate the HUDInstance: detach from the user-share group,
        // attach to the target group. Rewire callbacks against the
        // target group so future Send / draw-mode / panel-event
        // traffic lands in the right events log + flags.
        let targetGroupState = ensureGroup(targetGroup)
        sourceGroupState.huds.removeAll(where: { $0.id == sourceHud.id })
        targetGroupState.huds.append(sourceHud)
        sourceHud.window.sessionId = targetGroup
        wireHudCallbacks(sourceHud, sessionId: targetGroup)
        // Re-wire each panel's renderer-level closures (strokes +
        // panel events) for the new group; the previous wiring
        // captured the user-share group as the owner.
        for panel in sourceHud.panels {
            wireStrokePersistence(renderer: panel.renderer,
                                  sessionId: targetGroup,
                                  panelName: panel.name)
            wirePanelEvents(renderer: panel.renderer,
                            sessionId: targetGroup,
                            panelName: panel.name)
        }
        // Reflect the new owning group on the HUDInstance itself.
        sourceHud.group = targetGroup
        // The HUD is in a Claude-owned group now; Send follows normal
        // armed-AND-drawing gating.
        sourceHud.window.setAlwaysShowSend(false)
        // If the source group is now empty, drop it from the map so
        // we don't accumulate stale user-share-* entries.
        if sourceGroupState.huds.isEmpty {
            sourceGroupState.orphanTimerTask?.cancel()
            groups.removeValue(forKey: sourceGroupKey)
        }

        // Move the PNG into the target group's artifacts dir so
        // `get_share` can read it through MarkupPaths.artifact(
        // targetGroup, id:) — same path get_markup uses for the
        // standard markup loop. Best-effort: failure here leaves the
        // HUD migrated but the image unavailable, surfaced to Claude.
        do {
            try MarkupPaths.ensureDirs(targetGroup)
            try fm.moveItem(at: pngURL,
                            to: MarkupPaths.artifact(targetGroup, id: shareID))
        } catch {
            NSLog("QuickShow: claimShare PNG move failed: \(error) — HUD migrated but image unavailable")
        }
        NSLog("QuickShow: claimed share \(shareID) → group \(targetGroup) panel '\(meta.sourcePanelName)'")
        return ClaimedShare(panelName: meta.sourcePanelName, contentType: meta.contentType)
    }

    /// Emit a `markup_dismissed` line for a panel that was closed
    /// without sending. No artifact is written.
    func recordMarkupDismissed(sessionId: String, panel: String) {
        let session = ensureGroup(sessionId)
        session.eventWriter.emitMarkupDismissed(panel: panel)
        NSLog("QuickShow: markup_dismissed session=\(sessionId) panel=\(panel)")
    }

    func list(sessionId: String) -> [PanelDescriptor] {
        guard let session = groups[sessionId] else { return [] }
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
        guard let session = groups[sessionId],
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
        // Torn-out HUD inherits the source HUD's group (Phase 2: each
        // GroupState holds only HUDs of its group). The panel's own
        // description survives the move (it lives on the Panel
        // object). HUD-level description doesn't carry over — a single
        // torn tab is its own framing.
        let newHud = HUDInstance(window: newWindow, panels: [panel], group: source.group)
        session.huds.append(newHud)
        wireHudCallbacks(newHud, sessionId: sessionId)
        newWindow.installPanel(name: name, view: panel.view, description: panel.description ?? "")
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
        // Markup wiring. Strokes live in each WebView's in-DOM
        // canvas (`window.__qsMarkup`), mirrored to `Panel.strokes`
        // via the renderer's `onStrokesChanged` callback. The HUD
        // routes title-bar button clicks back here:
        window.onSendActivePanelMarkup = { [weak self] in
            self?.sendActivePanelMarkup(sessionId: sessionId, hudId: hudId)
        }
        window.onClearActivePanelMarkup = { [weak self] in
            self?.clearActivePanelMarkup(sessionId: sessionId, hudId: hudId)
        }
        window.onDrawModeChanged = { [weak self] enter in
            self?.applyDrawMode(sessionId: sessionId, hudId: hudId, enter: enter)
        }
        window.onPickMarkupColor = { [weak self] hex in
            self?.applyMarkupColor(sessionId: sessionId, hudId: hudId, hex: hex)
        }
        window.onPickMarkupWeight = { [weak self] pts in
            self?.applyMarkupWidth(sessionId: sessionId, hudId: hudId, pts: pts)
        }
        window.onUndoMarkup = { [weak self] in
            self?.applyUndoMarkup(sessionId: sessionId, hudId: hudId)
        }
        window.onToggleEraser = { [weak self] erasing in
            self?.applyEraserMode(sessionId: sessionId, hudId: hudId, erasing: erasing)
        }
        window.onResolveActiveStrokesEmpty = { [weak self] in
            guard let self = self,
                  let session = self.groups[sessionId],
                  let hud = session.huds.first(where: { $0.id == hudId }),
                  let activeName = hud.window.activePanelName,
                  let panel = hud.panels.first(where: { $0.name == activeName }) else {
                return true
            }
            return panel.strokes.isEmpty
        }
        window.onResolveArmedFlag = { [weak self] in
            return self?.flag(group: sessionId, key: "markup_events_armed")?.asBool == true
        }
        // Bind the title bar to its owning session and pull the
        // current armed-flag state SYNCHRONOUSLY. This covers the
        // common race: sidecar calls `enable_markup_events` (which
        // sets the flag) BEFORE its first `upsert`, so the flag is
        // already true by the time this HUD is born — the
        // notification observer alone would miss it.
        window.setOwningGroup(sessionId)
        let armed = flag(group: sessionId, key: "markup_events_armed")?.asBool == true
        window.setArmed(armed)
    }

    /// Enter / exit draw mode on the active panel's renderer. Sent
    /// from the title-bar pencil click via HUDWindow's
    /// `onDrawModeChanged` callback.
    private func applyDrawMode(sessionId: String, hudId: UUID, enter: Bool) {
        guard let session = groups[sessionId],
              let hud = session.huds.first(where: { $0.id == hudId }),
              let activeName = hud.window.activePanelName,
              let panel = hud.panels.first(where: { $0.name == activeName }),
              let web = panel.renderer as? WebViewPanelRenderer else { return }
        Task { @MainActor in
            if enter { await web.enterDrawMode() } else { await web.exitDrawMode() }
        }
    }

    /// Forward a color picker selection to the active panel's
    /// renderer. Seeds the JS canvas's `DEFAULT_COLOR` — only new
    /// strokes pick up the change; committed strokes preserve their
    /// captured color.
    private func applyMarkupColor(sessionId: String, hudId: UUID, hex: String) {
        guard let session = groups[sessionId],
              let hud = session.huds.first(where: { $0.id == hudId }),
              let activeName = hud.window.activePanelName,
              let panel = hud.panels.first(where: { $0.name == activeName }),
              let web = panel.renderer as? WebViewPanelRenderer else { return }
        Task { @MainActor in await web.setMarkupColor(hex) }
    }

    /// Symmetric counterpart for stroke width.
    private func applyMarkupWidth(sessionId: String, hudId: UUID, pts: CGFloat) {
        guard let session = groups[sessionId],
              let hud = session.huds.first(where: { $0.id == hudId }),
              let activeName = hud.window.activePanelName,
              let panel = hud.panels.first(where: { $0.name == activeName }),
              let web = panel.renderer as? WebViewPanelRenderer else { return }
        Task { @MainActor in await web.setMarkupWidth(pts) }
    }

    /// Pop the last stroke off the active panel — the title bar's
    /// undo button. Triggered strokes-changed broadcast updates
    /// `Panel.strokes` mirror + the title bar's enabled-state gate
    /// via the existing `onStrokesChanged` plumbing.
    private func applyUndoMarkup(sessionId: String, hudId: UUID) {
        guard let session = groups[sessionId],
              let hud = session.huds.first(where: { $0.id == hudId }),
              let activeName = hud.window.activePanelName,
              let panel = hud.panels.first(where: { $0.name == activeName }),
              let web = panel.renderer as? WebViewPanelRenderer else { return }
        Task { @MainActor in await web.popLastStroke() }
    }

    /// Toggle eraser tool on the active panel. `setMarkupTool` flips
    /// `currentTool` in `markup-canvas.js` between "draw" and "erase";
    /// the JS side branches pointer-handling accordingly.
    private func applyEraserMode(sessionId: String, hudId: UUID, erasing: Bool) {
        guard let session = groups[sessionId],
              let hud = session.huds.first(where: { $0.id == hudId }),
              let activeName = hud.window.activePanelName,
              let panel = hud.panels.first(where: { $0.name == activeName }),
              let web = panel.renderer as? WebViewPanelRenderer else { return }
        Task { @MainActor in await web.setMarkupTool(erasing ? "erase" : "draw") }
    }

    /// Clear all strokes from the active panel — wipes both the
    /// in-DOM canvas via the JS bridge and the Swift-side mirror in
    /// `Panel.strokes`. Title-bar ⌫ button calls this via the HUD's
    /// `onClearActivePanelMarkup` callback.
    private func clearActivePanelMarkup(sessionId: String, hudId: UUID) {
        guard let session = groups[sessionId],
              let hud = session.huds.first(where: { $0.id == hudId }),
              let activeName = hud.window.activePanelName,
              let panel = hud.panels.first(where: { $0.name == activeName }) else {
            return
        }
        panel.strokes = []
        hud.window.setActivePanelHasStrokes(false)
        if let web = panel.renderer as? WebViewPanelRenderer {
            Task { @MainActor in await web.clearMarkup() }
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
        guard let session = groups[sessionId] else { return }
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
        guard let session = groups[sessionId] else {
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
    /// target (so the user sees what they just dropped). Target's
    /// `group` and `hudDescription` win — symmetric with how target's
    /// chrome dominates (size, position, title bar). Moved panels keep
    /// their own per-tab `description`.
    private func performReattach(source: HUDInstance, target: HUDInstance, in session: GroupState) {
        let movedPanels = source.panels
        source.panels.removeAll()
        for panel in movedPanels {
            source.window.removePanel(panel.name)
            target.window.installPanel(
                name: panel.name, view: panel.view,
                description: panel.description ?? ""
            )
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
              let session = groups[payload.sessionId],
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
              let session = groups[payload.sessionId],
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
              let session = groups[payload.sessionId],
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
    private func locate(in session: GroupState, name: String) -> (HUDInstance, Panel)? {
        for hud in session.huds {
            if let p = hud.panels.first(where: { $0.name == name }) {
                return (hud, p)
            }
        }
        return nil
    }

    /// Get or create the primary HUD for a group. Phase 2: each
    /// GroupState holds one primary HUD plus any tear-out siblings —
    /// all share the same group key. Called only from `upsert`'s
    /// novel-name branch.
    private func ensureHud(in session: GroupState, group: String) -> HUDInstance {
        if let existing = session.huds.first(where: { $0.group == group }) {
            return existing
        }
        // Cascade origin per-HUD-rank so multiple groups don't pile up
        // on top of each other. session.cascadeIndex anchors the first
        // HUD; subsequent HUDs in this session shift by their position.
        let rank = session.cascadeIndex + session.huds.count
        let window = HUDWindow(initialPosition: HUDWindow.cascadeTopRight(rank))
        window.sessionId = session.id
        let hud = HUDInstance(window: window, group: group)
        session.huds.append(hud)
        wireHudCallbacks(hud, sessionId: session.id)
        window.setSessionEnded(session.orphaned)
        // For `.claudeSpace`: we move the window THREE times. (1)
        // Before `orderFront`, so the window's first visible frame
        // is on the target Space — no flash on the user's Space.
        // (2) Immediately after `orderFront`, because AppKit's
        // `makeKeyAndOrderFront` resets the Space on visible
        // windows. (3) Once more from the next main-queue tick, in
        // case AppKit's window-lifecycle does another reset after
        // ordering completes. Empirically required: a single move
        // (either before or after orderFront) gets reverted by
        // AppKit's window-server interaction.
        applyClaudeSpacePlacement(window: window, session: session)
        window.makeKeyAndOrderFront(nil)
        applyClaudeSpacePlacement(window: window, session: session)
        DispatchQueue.main.async { [weak self] in
            self?.applyClaudeSpacePlacement(window: window, session: session)
        }
        return hud
    }

    /// Per the "first create only" rule from the feasibility plan,
    /// nudges `window` onto the Space containing the terminal that
    /// hosts the Claude session — but only when the current policy
    /// is `.claudeSpace`. Updates `session.lastResolvedSpaceID` on
    /// success so subsequent placements can fall back to it when the
    /// terminal becomes temporarily invisible.
    private func applyClaudeSpacePlacement(window: HUDWindow, session: GroupState) {
        guard Settings.shared.hudSpacePolicy == .claudeSpace else { return }
        let resolved = SpaceResolver.placeOnClaudeSpace(
            window: window,
            parentPid: session.parentPid,
            cachedSpace: session.lastResolvedSpaceID
        )
        if let resolved = resolved {
            session.lastResolvedSpaceID = resolved
        }
    }

    /// Close a HUD: tear down its window and remove from `session.huds`.
    /// `isReleasedWhenClosed = false` on HUDWindow means this order is
    /// safe — the window won't dangle even if removed before close.
    private func closeHudInstance(_ hud: HUDInstance, in session: GroupState) {
        hud.window.close()
        session.huds.removeAll(where: { $0.id == hud.id })
    }

    private func ensureGroup(_ sessionId: String) -> GroupState {
        if let s = groups[sessionId] {
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
        let idx = groupsRegisteredOrder
        groupsRegisteredOrder += 1
        let s = GroupState(id: sessionId, cascadeIndex: idx)
        groups[sessionId] = s
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

    /// Posted whenever a markup-related NDJSON event lands in a
    /// session's events.ndjson. userInfo:
    ///   - "sessionId":  String
    ///   - "type":       "markup_sent" | "markup_dismissed"
    ///   - "panel":      String
    ///   - "artifact":   String? (only present for markup_sent)
    ///   - "ts_ms":      Double (milliseconds since epoch)
    ///
    /// The HTTP MCP layer's MCPSessionRouter listens to this and fans
    /// the event out via SDK `server.notify(LogMessageNotification)`
    /// so the MCP SSE channel carries the same payload that lands in
    /// the file. The file channel remains the source of truth for
    /// resume + forensic semantics; SSE is the live-consumer channel.
    static let quickShowMarkupEvent = Notification.Name("QuickShowMarkupEvent")
}
