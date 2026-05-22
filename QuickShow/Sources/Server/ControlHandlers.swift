import Darwin
import Foundation

// Per-kind dispatch. Phase 0: hello + ping. Phase 1: + upsert / close
// (real handlers wired through SessionManager).
//
// `hello` is NOT dispatched here — `ControlServer.handleLine` has a
// fast-path for it because the session_id allocator needs the FD,
// and threading FD through the handler signature would be more
// surgery than the saving is worth. Anything that reaches dispatch
// with `kind == "hello"` is a logic bug; we fall through to the
// unknown-kind branch.

@MainActor
enum ControlHandlers {
    /// Dispatch a request to its handler and return the encoded
    /// response bytes. Returns nil on encoding failure (logged).
    static func dispatch(_ req: ControlRequest, delegate: AppDelegate?) async -> Data? {
        do {
            switch req.kind {
            case "ping":
                return try encode(handlePing(req: req))
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
            case "claim_share":
                return try encode(try handleClaimShare(req: req, delegate: delegate))
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
                body: payload.body,
                width: payload.width,
                group: payload.group,
                description: payload.description,
                hudDescription: payload.hudDescription
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
            group: payload.session,
            key: payload.key,
            value: payload.value
        )
        return ControlOk(id: req.id, result: EmptyOk())
    }

    // MARK: - claim_share

    private static func handleClaimShare(req: ControlRequest, delegate: AppDelegate?) throws -> ControlOk {
        let payload = try req.decodePayload(ClaimShareRequest.self)
        guard let manager = delegate?.sessionManager else {
            throw ControlError.protocolError("session manager unavailable")
        }
        let claimed = try manager.claimShare(
            shareID: payload.shareId,
            targetGroup: payload.session
        )
        return ControlOk(id: req.id, result: ClaimShareResult(
            panelName: claimed.panelName,
            contentType: claimed.contentType
        ))
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
