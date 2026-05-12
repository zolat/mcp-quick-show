import Cocoa

/// Tracks panels per session. Phase 3: multi-panel per HUD.
/// Phase 4: orphan-on-disconnect with a 60 s same-UUID reconnect
/// window, then a persistent "session ended" badge.
@MainActor
final class SessionManager {
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
