import Cocoa

/// Tracks panels per session. Phase 3: per-session HUD, multi-panel
/// per HUD (tab-strip switchable). Same-name `upsert` updates in
/// place; different-name `upsert` opens a new tab.
@MainActor
final class SessionManager {
    private let renderers: RendererRegistry

    /// One MCP-session's worth of state: a HUD window + the ordered
    /// list of panels currently in it.
    final class SessionState {
        let id: String
        var hud: HUDWindow?
        var panels: [Panel] = []
        /// Cascade index assigned at creation, stable across panel
        /// adds / removes so the HUD doesn't jump if siblings close.
        let cascadeIndex: Int

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

    /// Register a session on `hello`. Reserves a cascade index even
    /// before any panels open so the first HUD lands in a stable
    /// position regardless of registration / open order.
    func registerSession(_ sessionId: String) {
        if sessions[sessionId] == nil {
            let idx = sessionsRegisteredOrder
            sessionsRegisteredOrder += 1
            sessions[sessionId] = SessionState(id: sessionId, cascadeIndex: idx)
        }
    }

    /// Render content into the named slot. Returns the render result
    /// + a PNG snapshot. Errors propagate as `RenderFailureWithSnapshot`.
    func upsert(sessionId: String,
                name: String,
                contentType: String,
                form: String,
                body: String) async throws -> (RenderResult, Data) {
        let session = ensureSession(sessionId)

        // Ensure HUD exists.
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
                // Same name, different type → swap the renderer.
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
            // New panel.
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

    /// Close the named slot. If it was the last panel, tear down the
    /// HUD; if it was the active panel, switch to the next-most-
    /// recently-added remaining panel.
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
            // Switch to the panel that's now at the same index (or
            // the last one if we removed from the end).
            let nextIdx = min(idx, session.panels.count - 1)
            session.hud?.setActivePanel(session.panels[nextIdx].name)
            session.hud?.updateTabs(session.panels.map(\.name))
        }
    }

    /// Switch the HUD to show a different panel (no content update).
    func switchTab(in sessionId: String, to name: String) {
        guard let session = sessions[sessionId],
              session.panels.contains(where: { $0.name == name }) else { return }
        session.hud?.setActivePanel(name)
        session.hud?.updateTabs(session.panels.map(\.name))
    }

    /// Close every panel in the session and tear down the HUD.
    func closeAllPanels(in sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        session.hud?.close()
        session.hud = nil
        session.panels = []
    }

    /// Re-snapshot the named slot without re-rendering. Returns nil
    /// if the slot isn't open.
    func inspect(sessionId: String, name: String) async throws -> (RenderResult, Data)? {
        guard let session = sessions[sessionId],
              let panel = session.panels.first(where: { $0.name == name }) else {
            return nil
        }
        let snapshot = try await panel.renderer.snapshot()
        let size = session.hud?.frame.size ?? .zero
        return (RenderResult(width: Double(size.width), height: Double(size.height)), snapshot)
    }

    /// All panels in a session, in insertion order.
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
        if let s = sessions[sessionId] { return s }
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
