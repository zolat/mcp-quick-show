import Cocoa

/// Tracks panels per session. Phase 3: multi-panel per HUD.
/// Phase 4: orphan-on-disconnect with a 60 s same-UUID reconnect
/// window, then a persistent "session ended" badge.
@MainActor
final class SessionManager: NSObject {
    /// Reconnect grace window. A sidecar that drops and reconnects
    /// with the same `session_id` inside this window reattaches
    /// silently; after it expires the badge is visible.
    /// Overridable via `QUICKSHOW_RECONNECT_GRACE_SECONDS` for tests.
    static var reconnectGraceSeconds: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["QUICKSHOW_RECONNECT_GRACE_SECONDS"],
           let v = Double(raw), v > 0 {
            return v
        }
        return 60
    }

    private let renderers: RendererRegistry
    /// Owned by AppDelegate; injected so the SessionManager can
    /// hand panels off for promote-to-window.
    weak var promoteController: PromoteToWindowController?

    /// One MCP-session's worth of state.
    final class SessionState {
        let id: String
        var hud: HUDWindow?
        var panels: [Panel] = []
        let cascadeIndex: Int
        /// `nil` when the sidecar is currently connected; populated
        /// when it disconnects with a Task that fires the "session
        /// ended" badge after `reconnectGraceSeconds`.
        var orphanTimerTask: Task<Void, Never>?
        /// True once the grace window has fully elapsed. The badge is
        /// visible; further upserts from a new sidecar with the same
        /// UUID still work (treated as a reconnect).
        var orphaned: Bool = false

        init(id: String, cascadeIndex: Int) {
            self.id = id
            self.cascadeIndex = cascadeIndex
        }
    }

    /// One rendered panel inside a HUD.
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

    init(renderers: RendererRegistry) {
        self.renderers = renderers
        super.init()
    }

    // MARK: - Session lifecycle

    /// Register a session on `hello`. Reserves a cascade index even
    /// before any panels open. If the session already exists (e.g.
    /// a reconnect), cancels any pending orphan timer and clears the
    /// badge.
    func registerSession(_ sessionId: String) {
        if let existing = sessions[sessionId] {
            // Reconnect path: cancel any pending orphan timer, clear
            // the badge if it was set, keep the HUD + panels in place.
            existing.orphanTimerTask?.cancel()
            existing.orphanTimerTask = nil
            if existing.orphaned {
                existing.orphaned = false
                existing.hud?.setSessionEnded(false)
                NSLog("QuickShow: session \(sessionId) reattached (orphan badge cleared)")
            }
            return
        }
        let idx = sessionsRegisteredOrder
        sessionsRegisteredOrder += 1
        sessions[sessionId] = SessionState(id: sessionId, cascadeIndex: idx)
    }

    /// Called by `ControlServer` when a sidecar connection drops.
    /// Starts the grace-window timer; if `registerSession` arrives
    /// for the same UUID before the timer fires, the timer is
    /// cancelled. Otherwise the HUD gets the badge and stays put.
    func sidecarDisconnected(sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        // If there's no HUD, nothing user-visible to orphan.
        guard session.hud != nil else { return }
        // Replace any in-flight orphan timer (multiple rapid drops).
        session.orphanTimerTask?.cancel()
        let grace = Self.reconnectGraceSeconds
        session.orphanTimerTask = Task { [weak self, weak session] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self = self, let session = session,
                      self.sessions[session.id] === session else { return }
                session.orphaned = true
                session.hud?.setSessionEnded(true)
                NSLog("QuickShow: session \(session.id) orphan grace expired — badge visible")
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

        let hud: HUDWindow
        if let existing = session.hud {
            hud = existing
        } else {
            let h = HUDWindow(initialPosition: HUDWindow.cascadeTopRight(session.cascadeIndex))
            h.onCloseRequested = { [weak self] in
                self?.closeAllPanels(in: sessionId)
            }
            h.onSelectTab = { [weak self] name in
                self?.switchTab(in: sessionId, to: name)
            }
            h.onCloseTab = { [weak self] name in
                self?.close(sessionId: sessionId, name: name)
            }
            h.onTabContextMenu = { [weak self] name, event in
                self?.showTabMenu(sessionId: sessionId, name: name, event: event, on: h)
            }
            h.onHudContextMenu = { [weak self] event in
                self?.showHudMenu(sessionId: sessionId, event: event, on: h)
            }
            h.onSnapshotActivePanel = { [weak self, weak h] in
                guard let self = self, let activeName = h?.activePanelName else { return }
                let item = NSMenuItem(title: "Snapshot", action: nil, keyEquivalent: "")
                item.representedObject = MenuPayload(sessionId: sessionId, name: activeName)
                self.handleSnapshotToDownloads(item)
            }
            h.sessionId = sessionId
            h.makeKeyAndOrderFront(nil)
            session.hud = h
            hud = h
        }

        // Find existing panel for this name in this session.
        var panel: Panel
        if let existing = session.panels.first(where: { $0.name == name }) {
            if existing.contentType == contentType {
                panel = existing
            } else {
                hud.removePanel(name)
                guard let renderer = renderers.make(forContentType: contentType) else {
                    throw RenderFailure(
                        message: "no renderer registered for content_type '\(contentType)'",
                        line: nil
                    )
                }
                let view = renderer.makeView()
                let newPanel = Panel(name: name, contentType: contentType, renderer: renderer, view: view)
                let idx = session.panels.firstIndex(where: { $0.name == name })!
                session.panels[idx] = newPanel
                hud.installPanel(name: name, view: view)
                panel = newPanel
            }
        } else {
            guard let renderer = renderers.make(forContentType: contentType) else {
                throw RenderFailure(
                    message: "no renderer registered for content_type '\(contentType)'",
                    line: nil
                )
            }
            let view = renderer.makeView()
            let newPanel = Panel(name: name, contentType: contentType, renderer: renderer, view: view)
            session.panels.append(newPanel)
            hud.installPanel(name: name, view: view)
            panel = newPanel
        }

        hud.setActivePanel(name)
        hud.updateTabs(session.panels.map(\.name))

        let payload = PanelPayload(name: name, contentType: contentType, form: form, body: body)
        do {
            let result = try await panel.renderer.update(payload: payload)
            hud.sizeToContent(width: result.width, height: result.height)
            let snapshot = try await panel.renderer.snapshot()
            return (result, snapshot)
        } catch let renderFailure as RenderFailure {
            let errorSnapshot = (try? await panel.renderer.snapshot()) ?? Data()
            throw RenderFailureWithSnapshot(failure: renderFailure, snapshot: errorSnapshot)
        }
    }

    func close(sessionId: String, name: String) {
        guard let session = sessions[sessionId] else { return }
        guard let idx = session.panels.firstIndex(where: { $0.name == name }) else { return }
        let wasActive = session.hud?.activePanelName == name
        session.panels.remove(at: idx)
        session.hud?.removePanel(name)
        if session.panels.isEmpty {
            session.hud?.close()
            session.hud = nil
            return
        }
        session.hud?.updateTabs(session.panels.map(\.name))
        if wasActive {
            let nextIdx = min(idx, session.panels.count - 1)
            session.hud?.setActivePanel(session.panels[nextIdx].name)
            session.hud?.updateTabs(session.panels.map(\.name))
        }
    }

    func switchTab(in sessionId: String, to name: String) {
        guard let session = sessions[sessionId],
              session.panels.contains(where: { $0.name == name }) else { return }
        session.hud?.setActivePanel(name)
        session.hud?.updateTabs(session.panels.map(\.name))
    }

    func closeAllPanels(in sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        session.hud?.close()
        session.hud = nil
        session.panels = []
        session.orphanTimerTask?.cancel()
        session.orphanTimerTask = nil
        session.orphaned = false
    }

    func inspect(sessionId: String, name: String) async throws -> (RenderResult, Data)? {
        guard let session = sessions[sessionId],
              let panel = session.panels.first(where: { $0.name == name }) else {
            return nil
        }
        let snapshot = try await panel.renderer.snapshot()
        let size = session.hud?.frame.size ?? .zero
        return (RenderResult(width: Double(size.width), height: Double(size.height)), snapshot)
    }

    func list(sessionId: String) -> [PanelDescriptor] {
        guard let session = sessions[sessionId] else { return [] }
        let size = session.hud?.frame.size ?? .zero
        return session.panels.map { panel in
            PanelDescriptor(
                name: panel.name,
                contentType: panel.contentType,
                width: Double(size.width),
                height: Double(size.height)
            )
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
              let panel = session.panels.first(where: { $0.name == payload.name }),
              let hud = session.hud,
              let promoteController = promoteController else { return }
        let panelSize = hud.frame.size
        promoteController.promote(
            name: payload.name,
            sessionId: payload.sessionId,
            detachFrom: hud,
            view: panel.view,
            panelSize: panelSize
        ) { [weak self] in
            // When the promoted window closes, drop the panel from
            // the session list — it can't be reinstated into the HUD
            // because the view's already been re-housed.
            self?.removePanelAfterPromote(sessionId: payload.sessionId, name: payload.name)
        }
        // The view is now in the promoted window; remove from the HUD
        // and update tab strip.
        hud.removePanel(payload.name)
        if let idx = session.panels.firstIndex(where: { $0.name == payload.name }) {
            session.panels.remove(at: idx)
        }
        if session.panels.isEmpty {
            session.hud?.close()
            session.hud = nil
        } else {
            hud.updateTabs(session.panels.map(\.name))
            if hud.activePanelName == nil, let first = session.panels.first {
                hud.setActivePanel(first.name)
            }
        }
    }

    private func removePanelAfterPromote(sessionId: String, name: String) {
        // No-op for now; the panel is already removed from session.panels
        // in `handlePromote`. The hook exists so future Phase 5 polish
        // can implement "demote back to HUD."
        _ = sessionId
        _ = name
    }

    @objc func handleSnapshotToDownloads(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? MenuPayload,
              let session = sessions[payload.sessionId],
              let panel = session.panels.first(where: { $0.name == payload.name }) else { return }
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
        guard let payload = sender.representedObject as? MenuPayload else { return }
        closeAllPanels(in: payload.sessionId)
    }

    @objc func handleOpacity(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? OpacityPayload,
              let session = sessions[payload.sessionId],
              let hud = session.hud else { return }
        hud.alphaValue = CGFloat(payload.percent) / 100.0
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

    private func showHudMenu(sessionId: String, event: NSEvent, on hud: HUDWindow) {
        let menu = HUDContextMenu.hudMenu(
            sessionId: sessionId,
            target: self,
            closeAll: #selector(handleCloseAll(_:)),
            opacity: #selector(handleOpacity(_:))
        )
        if let contentView = hud.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
        }
    }

    private func ensureSession(_ sessionId: String) -> SessionState {
        if let s = sessions[sessionId] {
            // Treat an upsert as a reconnect signal — if the sidecar
            // was previously marked orphaned and is now sending, the
            // badge should clear.
            if s.orphanTimerTask != nil || s.orphaned {
                s.orphanTimerTask?.cancel()
                s.orphanTimerTask = nil
                if s.orphaned {
                    s.orphaned = false
                    s.hud?.setSessionEnded(false)
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

/// Plain wire-side panel info for `list` responses.
struct PanelDescriptor: Sendable {
    let name: String
    let contentType: String
    let width: Double
    let height: Double
}

/// Internal error wrapper that bundles a `RenderFailure` with the
/// snapshot of the error UI.
struct RenderFailureWithSnapshot: Error {
    let failure: RenderFailure
    let snapshot: Data
}
