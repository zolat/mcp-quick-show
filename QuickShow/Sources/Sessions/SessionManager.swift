import Cocoa

/// Tracks panels per session. Phase 1: each session has a single
/// HUDWindow holding a single named panel (no multi-tab yet — that
/// lands in Phase 3, when this class grows a tab list per session).
///
/// State transitions:
/// - `handshake(sessionId)`: registers an empty session entry.
/// - `upsert(sessionId, name, content)`: returns or creates the HUD,
///   either reusing the renderer (same name + content_type) or
///   swapping in a fresh renderer (different content_type or first
///   upsert).
/// - `close(sessionId, name)`: tears down the HUD if the named slot
///   is currently active. (Phase 3: closes just the tab.)
@MainActor
final class SessionManager {
    private let renderers: RendererRegistry

    /// Per-session HUD state. Phase 1 = at most one panel per session;
    /// the field grows to a tab list in Phase 3.
    final class SessionState {
        let id: String
        var hud: HUDWindow?
        var panel: Panel?

        init(id: String) {
            self.id = id
        }
    }

    /// One rendered panel inside a HUD. Phase 1 = one per HUD.
    final class Panel {
        let name: String
        let contentType: String
        let renderer: any PanelRenderer

        init(name: String, contentType: String, renderer: any PanelRenderer) {
            self.name = name
            self.contentType = contentType
            self.renderer = renderer
        }
    }

    private(set) var sessions: [String: SessionState] = [:]

    init(renderers: RendererRegistry) {
        self.renderers = renderers
    }

    /// Register a session on hello. Called even before any panels are
    /// opened so we can index into `sessions` by ID later.
    func registerSession(_ sessionId: String) {
        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionState(id: sessionId)
        }
    }

    /// Render content into the named slot. Returns the render result
    /// + a PNG snapshot. Errors propagate as `RenderFailure` (with the
    /// styled error UI rendered into the panel before the throw).
    func upsert(sessionId: String,
                name: String,
                contentType: String,
                form: String,
                body: String) async throws -> (RenderResult, Data) {
        let session = sessions[sessionId] ?? {
            let s = SessionState(id: sessionId)
            sessions[sessionId] = s
            return s
        }()

        // Ensure HUD exists.
        let hud: HUDWindow
        if let existing = session.hud {
            hud = existing
        } else {
            let cascadeIndex = sessions.values.count - 1
            let h = HUDWindow(initialPosition: HUDWindow.cascadeTopRight(cascadeIndex))
            h.onCloseRequested = { [weak self, weak h] in
                guard let self = self, let h = h else { return }
                self.tearDownHUD(matching: h)
            }
            h.makeKeyAndOrderFront(nil)
            session.hud = h
            hud = h
        }

        // Ensure renderer for the right content_type.
        let renderer: any PanelRenderer
        if let panel = session.panel,
           panel.contentType == contentType {
            renderer = panel.renderer
            if panel.name != name {
                hud.setPanelName(name)
                session.panel = Panel(name: name, contentType: contentType, renderer: renderer)
            }
        } else {
            guard let r = renderers.make(forContentType: contentType) else {
                throw RenderFailure(
                    message: "no renderer registered for content_type '\(contentType)'",
                    line: nil
                )
            }
            renderer = r
            let view = r.makeView()
            hud.installRendererView(view, name: name)
            session.panel = Panel(name: name, contentType: contentType, renderer: renderer)
        }

        let payload = PanelPayload(name: name, contentType: contentType, form: form, body: body)
        do {
            let result = try await renderer.update(payload: payload)
            hud.sizeToContent(width: result.width, height: result.height)
            let snapshot = try await renderer.snapshot()
            return (result, snapshot)
        } catch let renderFailure as RenderFailure {
            // Renderer painted the error UI into its view; capture
            // that so the caller can ship a snapshot alongside the
            // structured error.
            let errorSnapshot = (try? await renderer.snapshot()) ?? Data()
            throw RenderFailureWithSnapshot(failure: renderFailure, snapshot: errorSnapshot)
        }
    }

    /// Close the named slot. Phase 1: tears down the whole HUD if it
    /// currently shows that slot.
    func close(sessionId: String, name: String) {
        guard let session = sessions[sessionId] else { return }
        if session.panel?.name == name {
            session.hud?.close()
            session.hud = nil
            session.panel = nil
        }
    }

    /// Re-snapshot the named slot without re-rendering. Returns nil
    /// if the slot isn't open.
    func inspect(sessionId: String, name: String) async throws -> (RenderResult, Data)? {
        guard let session = sessions[sessionId],
              let panel = session.panel,
              panel.name == name else {
            return nil
        }
        let snapshot = try await panel.renderer.snapshot()
        // We don't have a fresh size measurement, but we can report the
        // hud's content frame as the panel dimensions.
        let frame = session.hud?.frame.size ?? .zero
        return (RenderResult(width: Double(frame.width), height: Double(frame.height)), snapshot)
    }

    /// List panels in a session. Phase 1: 0 or 1 panel.
    func list(sessionId: String) -> [PanelDescriptor] {
        guard let session = sessions[sessionId],
              let panel = session.panel,
              let hud = session.hud else {
            return []
        }
        let size = hud.frame.size
        return [PanelDescriptor(
            name: panel.name,
            contentType: panel.contentType,
            width: Double(size.width),
            height: Double(size.height)
        )]
    }

    private func tearDownHUD(matching hud: HUDWindow) {
        for (id, state) in sessions where state.hud === hud {
            state.hud?.close()
            state.hud = nil
            state.panel = nil
            sessions[id] = state
            return
        }
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
/// snapshot of the error UI. The control handler unpacks both into
/// the `render_error` response envelope.
struct RenderFailureWithSnapshot: Error {
    let failure: RenderFailure
    let snapshot: Data
}
