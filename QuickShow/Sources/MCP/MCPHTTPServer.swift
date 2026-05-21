import Darwin
import Foundation
import MCP

// MCPHTTPServer — Phase 1 PoC.
//
// AF_INET listener on 127.0.0.1:<port> that accepts HTTP/1.1
// connections from local Claude Code processes and routes them
// through the SDK's `StatefulHTTPServerTransport`. Cloned from
// `ControlServer.swift`'s AF_UNIX accept-loop pattern — same
// DispatchSource shape, same per-connection detached task shape.
//
// Gated on the `QUICKSHOW_MCP_HTTP` env var (off by default) so
// the existing stdio sidecar remains the production path. Coexists
// without interference: different transport, different port, no
// shared state.
//
// This commit lands only the accept loop + HTTP/1.1 framing.
// MCP routing (session router + SDK dispatch) lands in the next
// commit; for now we log the parsed request line and return a
// placeholder 200 to exercise the framing end-to-end.

@MainActor
final class MCPHTTPServer {
    nonisolated static let defaultPort: UInt16 = 7890

    private let port: UInt16
    private let router: MCPSessionRouter
    private let queue = DispatchQueue(
        label: "com.zolat.QuickShow.mcphttp",
        qos: .userInitiated
    )
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private(set) var actualPort: UInt16 = 0

    init(port: UInt16 = MCPHTTPServer.defaultPort, router: MCPSessionRouter) {
        self.port = port
        self.router = router
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.systemError("socket", errno) }

        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")  // localhost-only — never bind to 0.0.0.0
        let addrSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bindRC = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, addrSize)
            }
        }
        guard bindRC == 0 else {
            let e = errno
            Darwin.close(fd)
            throw ServerError.systemError("bind", e)
        }

        // Read back the bound port (port=0 → ephemeral). Stored for
        // logs + the override-via-env workflow.
        var actual = sockaddr_in()
        var actualLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &actualLen)
            }
        }
        actualPort = UInt16(bigEndian: actual.sin_port)

        guard Darwin.listen(fd, 16) == 0 else {
            let e = errno
            Darwin.close(fd)
            throw ServerError.systemError("listen", e)
        }

        listenFD = fd
        let routerRef = router
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler {
            MCPHTTPServer.acceptOne(listenFD: fd, router: routerRef)
        }
        src.resume()
        listenSource = src

        NSLog("QuickShow: mcp http server listening at 127.0.0.1:\(actualPort)")
    }

    func stop() {
        listenSource?.cancel()
        listenSource = nil
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
        NSLog("QuickShow: mcp http server stopped")
    }

    // MARK: - Connection handling (off the main actor)

    private nonisolated static func acceptOne(listenFD: Int32, router: MCPSessionRouter) {
        let connFD = Darwin.accept(listenFD, nil, nil)
        guard connFD >= 0 else { return }
        // SO_NOSIGPIPE: writes to a closed socket return EPIPE (which we
        // already handle in writeAll) without raising SIGPIPE on the
        // whole process. Without this the delayed P3 push reliably
        // crashes the app when the client has already disconnected,
        // because the SDK's SSE pump writes into a dead FD.
        var one: Int32 = 1
        _ = setsockopt(connFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // Resolve the connecting client's PID via libproc while the
        // socket is still alive on both ends — accept→getpeername→walk.
        let claudePid = PeerPidResolver.resolve(fd: connFD, tag: "mcp-http-accept")
        Task.detached {
            await MCPHTTPServer.serveConnection(fd: connFD, claudePid: claudePid, router: router)
        }
    }

    private nonisolated static func serveConnection(
        fd: Int32,
        claudePid: pid_t?,
        router: MCPSessionRouter
    ) async {
        defer { Darwin.close(fd) }
        do {
            let req = try MCPHTTPParser.readRequest(fd: fd)
            let bodyLen = req.body?.count ?? 0
            NSLog("QuickShow: mcp http \(req.method) \(req.path ?? "?") claude_pid=\(claudePid.map(String.init) ?? "nil") body_bytes=\(bodyLen) sess=\(req.header(HTTPHeaderName.sessionID) ?? "-")")

            let response = await router.handle(req, claudePid: claudePid)

            switch response {
            case .stream(let stream, let extraHeaders):
                // Server-Sent-Events stream — SDK already framed each
                // event; we just pump bytes onto the wire until the
                // stream ends or the client drops.
                var headers = extraHeaders
                // Surface the Mcp-Session-Id on SSE responses too —
                // the SDK only sets it on initialize today.
                let sid = req.header(HTTPHeaderName.sessionID)
                if let sid, headers[HTTPHeaderName.sessionID] == nil {
                    headers[HTTPHeaderName.sessionID] = sid
                }
                // Bracket the long-lived standalone GET SSE stream
                // with router liveness hooks so `hasOpenSSEStream`
                // reflects reality. POST-initiated SSE streams (per-
                // request response streams) are typically short-lived
                // and don't carry the standalone-listener semantics
                // we care about, so we restrict the bracket to GETs.
                let isStandaloneSSE = req.method.uppercased() == "GET"
                if isStandaloneSSE, let sid {
                    await router.markSSEOpen(sessionID: sid)
                }
                await MCPHTTPParser.writeStream(stream, extraHeaders: headers, to: fd)
                if isStandaloneSSE, let sid {
                    await router.markSSEClosed(sessionID: sid)
                }
            default:
                MCPHTTPParser.writeResponse(response, to: fd)
            }
        } catch MCPHTTPParser.ReadError.clientClosed {
            return
        } catch {
            NSLog("QuickShow: mcp http read error: \(error)")
            MCPHTTPParser.writeResponse(
                .error(statusCode: 400, .invalidRequest("malformed HTTP/1.1 request")),
                to: fd
            )
        }
    }

    // MARK: - Errors

    enum ServerError: Error, CustomStringConvertible {
        case systemError(String, Int32)
        var description: String {
            switch self {
            case let .systemError(op, err):
                return "\(op) failed: \(String(cString: strerror(err)))"
            }
        }
    }
}
