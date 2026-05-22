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
    private let serverInfo: Server.Info
    private let capabilities: Server.Capabilities
    private let toolRegistrar: @MainActor @Sendable (Server, String) async -> Void

    /// - Parameter toolRegistrar: invoked exactly once per session, after
    ///   the Server is created and before `start(transport:)`. Receives
    ///   the fresh Server + that session's id. Lets the show_html handler
    ///   register the right per-session closures (capturing claudePid for
    ///   placement, etc.) without the router knowing tool-level details.
    init(
        serverInfo: Server.Info = Server.Info(name: "QuickShow", version: "0.2.0-poc"),
        capabilities: Server.Capabilities = Server.Capabilities(
            tools: .init(listChanged: false)
        ),
        toolRegistrar: @escaping @MainActor @Sendable (Server, String) async -> Void = { _, _ in }
    ) {
        self.serverInfo = serverInfo
        self.capabilities = capabilities
        self.toolRegistrar = toolRegistrar
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
