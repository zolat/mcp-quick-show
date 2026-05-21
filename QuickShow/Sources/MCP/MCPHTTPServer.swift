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
    private let queue = DispatchQueue(
        label: "com.zolat.QuickShow.mcphttp",
        qos: .userInitiated
    )
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private(set) var actualPort: UInt16 = 0

    init(port: UInt16 = MCPHTTPServer.defaultPort) {
        self.port = port
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
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler {
            MCPHTTPServer.acceptOne(listenFD: fd)
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

    private nonisolated static func acceptOne(listenFD: Int32) {
        let connFD = Darwin.accept(listenFD, nil, nil)
        guard connFD >= 0 else { return }
        // Resolve the connecting client's PID via libproc while the
        // socket is still alive on both ends — accept→getpeername→walk.
        let claudePid = PeerPidResolver.resolve(fd: connFD, tag: "mcp-http-accept")
        Task.detached {
            await MCPHTTPServer.serveConnection(fd: connFD, claudePid: claudePid)
        }
    }

    private nonisolated static func serveConnection(fd: Int32, claudePid: pid_t?) async {
        defer { Darwin.close(fd) }
        do {
            let req = try MCPHTTPParser.readRequest(fd: fd)
            let bodyLen = req.body?.count ?? 0
            NSLog("QuickShow: mcp http \(req.method) \(req.path ?? "?") claude_pid=\(claudePid.map(String.init) ?? "nil") body_bytes=\(bodyLen) sess=\(req.header("Mcp-Session-Id") ?? "-")")
            // Scaffold response — next commit replaces with SDK dispatch.
            let placeholder = "ok — mcp http scaffold; claude_pid=\(claudePid.map(String.init) ?? "nil"); request=\(req.method) \(req.path ?? "?")\n"
            let body = Data(placeholder.utf8)
            MCPHTTPParser.writeResponse(
                .data(body, headers: ["Content-Type": "text/plain"]),
                to: fd
            )
        } catch MCPHTTPParser.ReadError.clientClosed {
            // Normal connection close before any data — silent.
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
