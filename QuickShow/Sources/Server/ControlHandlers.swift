import Darwin
import Foundation

// Per-kind dispatch. Phase 0: hello + ping only. Subsequent phases
// add upsert / close / list / inspect.

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
                return try encode(try handleHello(req: req))
            case "upsert", "close", "list", "inspect":
                // Phase 0 stubs — Phase 1+ wires real handlers.
                return try encode(ControlProtocolError(
                    id: req.id,
                    error: "kind '\(req.kind)' not implemented in Phase 0"
                ))
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
        let payload = try req.decodePayload(HelloRequest.self)
        NSLog("QuickShow: hello from session=\(payload.sessionId) client=\(payload.client ?? "?")")
        return ControlOk(id: req.id, result: HelloResult(
            version: ControlProtocol.version,
            pid: getpid()
        ))
    }
}
