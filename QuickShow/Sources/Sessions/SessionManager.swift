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
        primary.panels.append(panel)
        primary.window.installPanel(name: name, view: view)
        return try await renderPanel(panel: panel, hud: primary,
                                     name: name, contentType: contentType,
                                     form: form, body: body)
    }

    private func renderPanel(panel: Panel,
                             hud: HUDInstance,
                             name: String,
                             contentType: String,
                             form: String,
                             body: String) async throws -> (RenderResult, Data) {
        hud.window.setActivePanel(name)
        hud.window.updateTabs(hud.panels.map(\.name))
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

        // 3. Drag-follow until mouseUp.
        beginDragFollow(window: newWindow, mouseDownPoint: mouseLoc)
    }

    private func beginDragFollow(window: HUDWindow, mouseDownPoint: NSPoint) {
        // Stop any prior drag-follow defensively (shouldn't happen
        // because mouseUp removes the monitor, but be paranoid).
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
                // Window vanished mid-drag — clean up and let events through.
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
                return nil
            }
            if event.type == .leftMouseUp {
                if let mon = self.dragMonitor {
                    NSEvent.removeMonitor(mon)
                    self.dragMonitor = nil
                }
                // Let the mouseUp through so Cocoa's tracking
                // bookkeeping for the source pill's mouseDown gets
                // cleaned up properly (the pill captured the event
                // stream when its mouseDown fired).
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
