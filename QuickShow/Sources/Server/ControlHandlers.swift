import Darwin
import Foundation

// Per-kind dispatch. Phase 0: hello + ping. Phase 1: + upsert / close
// (real handlers wired through SessionManager).

@MainActor
enum ControlHandlers {
    /// Dispatch a request to its handler and return the encoded
    /// response bytes. Returns nil on encoding failure (logged).
    static func dispatch(_ req: ControlRequest, delegate: AppDelegate?) async -> Data? {
        do {
            switch req.kind {
            case "ping":
                return try encode(handlePing(req: req))
            case "hello":
                return try encode(try handleHelloWithDelegate(req: req, delegate: delegate))
            case "upsert":
                return try await handleUpsert(req: req, delegate: delegate)
            case "close":
                return try encode(try handleClose(req: req, delegate: delegate))
            case "list":
                return try encode(try handleList(req: req, delegate: delegate))
            case "inspect":
                return try await handleInspect(req: req, delegate: delegate)
            case "set_session_flag":
                return try encode(try handleSetSessionFlag(req: req, delegate: delegate))
            default:
                return try encode(ControlProtocolError(
                    id: req.id,
                    error: "unknown kind: '\(req.kind)'"
                ))
            }
        } catch let error as ControlError {
            return try? encode(ControlProtocolError(id: req.id, error: error.protocolMessage))
        } catch {
            return try? encode(ControlProtocolError(id: req.id, error: error.localizedDescription))
        }
    }

    private static func encode(_ value: some Encodable) throws -> Data {
        try ControlProtocol.encoder.encode(value)
    }

    // MARK: - ping

    private static func handlePing(req: ControlRequest) -> ControlOk {
        ControlOk(id: req.id, result: PingResult(
            version: ControlProtocol.version,
            pid: getpid()
        ))
    }

    // MARK: - hello

    private static func handleHello(req: ControlRequest) throws -> ControlOk {
        return try handleHelloWithDelegate(req: req, delegate: nil)
    }

    /// Variant that registers the session with the delegate's
    /// `SessionManager` so cascade indexes are reserved at hello time
    /// (and any pending orphan timer for the same UUID is cancelled).
    /// Plumbing routes through `dispatch` below.
    private static func handleHelloWithDelegate(req: ControlRequest, delegate: AppDelegate?) throws -> ControlOk {
        let payload = try req.decodePayload(HelloRequest.self)
        NSLog("QuickShow: hello from session=\(payload.sessionId) client=\(payload.client ?? "?")")
        delegate?.sessionManager.registerSession(payload.sessionId)
        return ControlOk(id: req.id, result: HelloResult(
            version: ControlProtocol.version,
            pid: getpid()
        ))
    }

    // MARK: - upsert

    private static func handleUpsert(req: ControlRequest, delegate: AppDelegate?) async throws -> Data {
        let payload = try req.decodePayload(UpsertRequest.self)
        guard let manager = delegate?.sessionManager else {
            return try encode(ControlProtocolError(
                id: req.id,
                error: "session manager unavailable"
            ))
        }
        do {
            let (result, snapshot) = try await manager.upsert(
                sessionId: payload.session,
                name: payload.name,
                contentType: payload.contentType,
                form: payload.form,
                body: payload.body
            )
            let upsertResult = UpsertResult(
                width: result.width,
                height: result.height,
                screenshotB64: snapshot.base64EncodedString()
            )
            return try encode(ControlOk(id: req.id, result: upsertResult))
        } catch let wrapped as RenderFailureWithSnapshot {
            return try encode(ControlRenderError(
                id: req.id,
                error: wrapped.failure.message,
                line: wrapped.failure.line,
                screenshotB64: wrapped.snapshot.base64EncodedString()
            ))
        } catch let failure as RenderFailure {
            return try encode(ControlRenderError(
                id: req.id,
                error: failure.message,
                line: failure.line,
                screenshotB64: nil
            ))
        }
    }

    // MARK: - close

    private static func handleClose(req: ControlRequest, delegate: AppDelegate?) throws -> ControlOk {
        let payload = try req.decodePayload(CloseRequest.self)
        delegate?.sessionManager.close(sessionId: payload.session, name: payload.name)
        return ControlOk(id: req.id, result: EmptyOk())
    }

    // MARK: - list

    private static func handleList(req: ControlRequest, delegate: AppDelegate?) throws -> ControlOk {
        let payload = try req.decodePayload(ListRequest.self)
        let panels = delegate?.sessionManager.list(sessionId: payload.session) ?? []
        let infos = panels.map { panel in
            PanelInfo(name: panel.name,
                      contentType: panel.contentType,
                      width: panel.width,
                      height: panel.height)
        }
        return ControlOk(id: req.id, result: infos)
    }

    // MARK: - set_session_flag

    private static func handleSetSessionFlag(req: ControlRequest, delegate: AppDelegate?) throws -> ControlOk {
        let payload = try req.decodePayload(SetSessionFlagRequest.self)
        delegate?.sessionManager.setFlag(
            sessionId: payload.session,
            key: payload.key,
            value: payload.value
        )
        return ControlOk(id: req.id, result: EmptyOk())
    }

    // MARK: - inspect

    private static func handleInspect(req: ControlRequest, delegate: AppDelegate?) async throws -> Data {
        let payload = try req.decodePayload(InspectRequest.self)
        guard let manager = delegate?.sessionManager else {
            return try encode(ControlProtocolError(
                id: req.id,
                error: "session manager unavailable"
            ))
        }
        guard let (result, snapshot) = try await manager.inspect(
            sessionId: payload.session,
            name: payload.name
        ) else {
            return try encode(ControlProtocolError(
                id: req.id,
                error: "no panel named '\(payload.name)' in session"
            ))
        }
        return try encode(ControlOk(id: req.id, result: UpsertResult(
            width: result.width,
            height: result.height,
            screenshotB64: snapshot.base64EncodedString()
        )))
    }
}

private struct EmptyOk: Encodable {}
