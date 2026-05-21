import Foundation
import MCP

// MCPSessionRouter — per-`Mcp-Session-Id` map of (Server, transport,
// claudePid). Mirror of the SDK's `MCPConformance/Server/HTTPApp.swift`
// session map, minus the NIO bits (we do our own listener) and minus
// session-cleanup (single-Claude lifetime, app exit closes everything).
//
// Flow:
//   - Request has Mcp-Session-Id header → route to that transport.
//   - No header, POST with `initialize` body → create a new session,
//     stash claudePid, dispatch.
//   - No header, otherwise → 400.
//   - Header for a missing session → 404 (per spec).
//
// Server-initiated push (`server.notify(...)`) goes through whatever
// active SSE stream the SDK has for the session. We expose
// `serverFor(sessionID:)` so the show_html handler can schedule a
// delayed notify in Phase 1 P3.

@MainActor
final class MCPSessionRouter {

    struct SessionState {
        let server: Server
        let transport: StatefulHTTPServerTransport
        let claudePid: pid_t?
        let createdAt: Date
    }

    private var sessions: [String: SessionState] = [:]
    /// Per-session counter of open standalone-SSE GET streams. A value
    /// > 0 means at least one live MCP consumer is listening on this
    /// session's SSE channel; pushed events will reach a client in
    /// real time. Zero means events go to the SDK's event store, file
    /// channel only.
    private var openSSEStreams: [String: Int] = [:]
    private let serverInfo: Server.Info
    private let capabilities: Server.Capabilities
    private let toolRegistrar: @MainActor @Sendable (Server, String) async -> Void
    private var markupObserver: NSObjectProtocol?

    /// - Parameter toolRegistrar: invoked exactly once per session, after
    ///   the Server is created and before `start(transport:)`. Receives
    ///   the fresh Server + that session's id. Lets the show_html handler
    ///   register the right per-session closures (capturing claudePid for
    ///   placement, etc.) without the router knowing tool-level details.
    init(
        serverInfo: Server.Info = Server.Info(name: "QuickShow", version: "0.2.0-poc"),
        capabilities: Server.Capabilities = Server.Capabilities(
            logging: Server.Capabilities.Logging(),
            tools: .init(listChanged: false)
        ),
        toolRegistrar: @escaping @MainActor @Sendable (Server, String) async -> Void = { _, _ in }
    ) {
        self.serverInfo = serverInfo
        self.capabilities = capabilities
        self.toolRegistrar = toolRegistrar
        // Subscribe to per-session markup events emitted by
        // EventLogWriter alongside its NDJSON writes. Each one fans
        // out to the matching session's MCP SSE stream as a
        // `notifications/message` (logging) payload — same shape as
        // the file line, so consumers parse one schema.
        markupObserver = NotificationCenter.default.addObserver(
            forName: .quickShowMarkupEvent,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let sid = info["sessionId"] as? String,
                  let type = info["type"] as? String,
                  let panel = info["panel"] as? String
            else { return }
            let artifact = info["artifact"] as? String
            let tsMs = (info["ts_ms"] as? Double) ?? 0
            Task { @MainActor [weak self] in
                await self?.fanOutMarkupEvent(
                    sessionID: sid,
                    type: type,
                    panel: panel,
                    artifact: artifact,
                    tsMs: tsMs
                )
            }
        }
    }

    deinit {
        if let markupObserver {
            NotificationCenter.default.removeObserver(markupObserver)
        }
    }

    /// Look up the Server for a session, if any. Used by the show_html
    /// handler to schedule a delayed notify on the right session's SSE
    /// stream (P3).
    func serverFor(sessionID: String) -> Server? {
        sessions[sessionID]?.server
    }

    func claudePidFor(sessionID: String) -> pid_t? {
        sessions[sessionID]?.claudePid
    }

    // MARK: - SSE liveness

    /// Returns true iff at least one standalone-SSE GET stream is open
    /// for this session right now. Consulted by `enable_markup_events`
    /// so the tool response can warn Claude that markup events will
    /// queue (file-only, no live MCP push) until a Monitor / SSE
    /// consumer connects.
    func hasOpenSSEStream(sessionID: String) -> Bool {
        (openSSEStreams[sessionID] ?? 0) > 0
    }

    /// Called by MCPHTTPServer.serveConnection when a GET /mcp request
    /// receives an `.stream` response and starts pumping bytes onto
    /// the FD. The matching closed-hook fires when writeStream returns.
    func markSSEOpen(sessionID: String) {
        openSSEStreams[sessionID, default: 0] += 1
        NSLog("QuickShow: mcp sse stream opened session=\(sessionID) count=\(openSSEStreams[sessionID] ?? 0)")
    }

    func markSSEClosed(sessionID: String) {
        let current = openSSEStreams[sessionID] ?? 0
        if current <= 1 {
            openSSEStreams.removeValue(forKey: sessionID)
        } else {
            openSSEStreams[sessionID] = current - 1
        }
        NSLog("QuickShow: mcp sse stream closed session=\(sessionID) count=\(openSSEStreams[sessionID] ?? 0)")
    }

    // MARK: - Markup fan-out

    /// Forward a NotificationCenter-delivered markup event to the
    /// matching session's MCP SSE stream as a `notifications/message`.
    /// No-op for sessions we don't own (Claudes driving the stdio
    /// sidecar share the same EventLogWriter notification surface but
    /// have no entry in our router map).
    private func fanOutMarkupEvent(
        sessionID: String,
        type: String,
        panel: String,
        artifact: String?,
        tsMs: Double
    ) async {
        guard let server = sessions[sessionID]?.server else { return }
        var data: [String: Value] = [
            "type": .string(type),
            "panel": .string(panel),
            "session": .string(sessionID),
            "ts_ms": .double(tsMs),
        ]
        if let artifact { data["artifact"] = .string(artifact) }
        let msg = Message<LogMessageNotification>(
            method: LogMessageNotification.name,
            params: LogMessageNotification.Parameters(
                level: .info,
                logger: "quickshow.markup",
                data: .object(data)
            )
        )
        do {
            try await server.notify(msg)
            NSLog("QuickShow: mcp markup_notify SENT session=\(sessionID) type=\(type) panel=\(panel)")
        } catch {
            NSLog("QuickShow: mcp markup_notify FAILED session=\(sessionID) error=\(error)")
        }
    }

    /// Route a request. Returns the HTTPResponse to write back to the
    /// client. The caller owns the FD and bytes; this method is pure
    /// w.r.t. the network — only side effect is session-map mutation.
    func handle(_ request: HTTPRequest, claudePid: pid_t?) async -> HTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        // Existing session: forward to its transport.
        if let sessionID, let state = sessions[sessionID] {
            let response = await state.transport.handleRequest(request)
            // DELETE success → drop the session.
            if request.method.uppercased() == "DELETE", response.statusCode == 200 {
                await dropSession(sessionID)
            }
            return response
        }

        // No session: only an `initialize` POST is allowed.
        if request.method.uppercased() == "POST",
           let body = request.body,
           isInitializeRequest(body)
        {
            return await createSessionAndHandle(request, claudePid: claudePid)
        }

        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired"))
        }
        return .error(statusCode: 400, .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header"))
    }

    private func createSessionAndHandle(_ request: HTTPRequest, claudePid: pid_t?) async -> HTTPResponse {
        let newID = UUID().uuidString
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: newID)
        )
        let server = Server(
            name: serverInfo.name,
            version: serverInfo.version,
            title: serverInfo.title,
            instructions: nil,
            capabilities: capabilities
        )

        do {
            await toolRegistrar(server, newID)
            try await server.start(transport: transport)
            sessions[newID] = SessionState(
                server: server,
                transport: transport,
                claudePid: claudePid,
                createdAt: Date()
            )
            NSLog("QuickShow: mcp http session new id=\(newID) claude_pid=\(claudePid.map(String.init) ?? "nil")")
            let response = await transport.handleRequest(request)
            // If transport rejected the initialize, undo.
            if case .error = response {
                await server.stop()
                sessions.removeValue(forKey: newID)
            }
            return response
        } catch {
            await transport.disconnect()
            return .error(
                statusCode: 500,
                .internalError("Failed to create session: \(error.localizedDescription)")
            )
        }
    }

    private func dropSession(_ id: String) async {
        guard let state = sessions.removeValue(forKey: id) else { return }
        await state.server.stop()
        NSLog("QuickShow: mcp http session dropped id=\(id)")
    }
}

// MARK: - Helpers

/// Cheap JSON peek: is this an `initialize` JSON-RPC request? The SDK's
/// `JSONRPCMessageKind` is `package`-scoped, so we re-implement the
/// 4-line check here instead of trying to import it.
private func isInitializeRequest(_ body: Data) -> Bool {
    guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        return false
    }
    return (json["method"] as? String) == "initialize"
}

/// Mirrors the private FixedSessionIDGenerator inside SDK's HTTPApp.swift:
/// makes the SDK's transport adopt an id we picked instead of minting
/// one itself. This is the pattern the conformance test uses so the
/// HTTP-framework layer (router) owns the id assignment.
private struct FixedSessionIDGenerator: SessionIDGenerator {
    let sessionID: String
    func generateSessionID() -> String { sessionID }
}
