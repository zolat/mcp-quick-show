import Darwin
import Foundation

// AF_UNIX SOCK_STREAM listener that speaks NDJSON. Adapted from
// PipAnything's ControlServer.swift — same accept-loop shape;
// QuickShow-specific verbs are dispatched by ControlHandlers.
//
// Phase 4 addition: track which connection owns each session_id so
// the SessionManager learns about sidecar disconnects (which start
// the 60 s orphan grace window).
//
// Lifetime: started from AppDelegate.applicationDidFinishLaunching;
// stopped from applicationWillTerminate. Stale socket files are
// unlinked on start and stop so a crash doesn't leave the path bound.

@MainActor
final class ControlServer {
    nonisolated static let defaultSocketPath: String = {
        let dir = NSString(string: "~/Library/Application Support/QuickShow")
            .expandingTildeInPath
        return (dir as NSString).appendingPathComponent("control.sock")
    }()

    private let socketPath: String
    private let queue = DispatchQueue(
        label: "com.zolat.QuickShow.control",
        qos: .userInitiated
    )
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?

    /// fd → session_id, populated when a `hello` arrives over that
    /// connection. Used so the per-connection serve loop can tell
    /// the SessionManager which session disconnected.
    private var sessionByFD: [Int32: String] = [:]

    weak var appDelegate: AppDelegate?

    init(socketPath: String = ControlServer.defaultSocketPath) {
        self.socketPath = socketPath
    }

    func start() throws {
        let parentDir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parentDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlServerError.systemError("socket", errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else {
            Darwin.close(fd)
            throw ControlServerError.pathTooLong(socketPath)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dst, src.baseAddress, pathBytes.count)
                }
            }
        }

        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, addrSize)
            }
        }
        guard bindResult == 0 else {
            let e = errno
            Darwin.close(fd)
            throw ControlServerError.systemError("bind", e)
        }
        chmod(socketPath, 0o600)

        guard Darwin.listen(fd, 8) == 0 else {
            let e = errno
            Darwin.close(fd)
            unlink(socketPath)
            throw ControlServerError.systemError("listen", e)
        }

        listenFD = fd

        let weakSelf = WeakRef(self)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler {
            ControlServer.acceptOne(listenFD: fd, server: weakSelf)
        }
        src.resume()
        listenSource = src

        NSLog("QuickShow: control server listening at \(socketPath)")
    }

    func stop() {
        listenSource?.cancel()
        listenSource = nil
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
        sessionByFD.removeAll()
        NSLog("QuickShow: control server stopped")
    }

    // MARK: - Session tracking (called by handlers + serve loop)

    /// Decide the authoritative `session_id` for an incoming `hello`.
    ///
    /// The sidecar's claim is normally the Claude conversation UUID,
    /// discovered from `~/.claude/projects/.../<uuid>.jsonl` (see
    /// `sidecar/src/session.ts:resolveSessionId`). That id is
    /// distinct per parallel Claude and stable across sidecar respawn
    /// / `claude --resume`, so two competing claims from real Claude
    /// processes should never collide. This allocator's live-FD
    /// contest check is belt-and-braces — it catches the
    /// near-impossible case where the same UUID arrives on two FDs
    /// concurrently (UUID collision, env-override misuse) — and we
    /// mint a fresh UUID for the second arrival.
    ///
    /// Always called on `@MainActor` (from `handleLine`'s hello
    /// fast-path); `sessionByFD` is single-writer here so there's no
    /// race between two concurrent hellos checking the same claim.
    func allocateSessionId(claim: String, fd: Int32, parentPid: Int32?) -> String {
        let contested = sessionByFD.values.contains(claim)
        let granted = contested ? UUID().uuidString.lowercased() : claim
        sessionByFD[fd] = granted
        if contested {
            NSLog("QuickShow: session_id claim \(claim) contested " +
                  "(held by another live FD); granted fresh \(granted) " +
                  "to fd=\(fd) ppid=\(parentPid.map(String.init) ?? "?")")
        }
        return granted
    }

    func connectionClosed(fd: Int32) {
        if let sessionId = sessionByFD.removeValue(forKey: fd) {
            appDelegate?.sessionManager.sidecarDisconnected(sessionId: sessionId)
            NSLog("QuickShow: connection closed for session \(sessionId)")
        }
    }

    // MARK: - I/O (nonisolated; runs off the main actor)

    private nonisolated static func acceptOne(
        listenFD: Int32,
        server: WeakRef<ControlServer>
    ) {
        let connFD = Darwin.accept(listenFD, nil, nil)
        guard connFD >= 0 else { return }
        Task.detached {
            await ControlServer.serveConnection(fd: connFD, server: server)
        }
    }

    private nonisolated static func serveConnection(
        fd: Int32,
        server: WeakRef<ControlServer>
    ) async {
        defer {
            Darwin.close(fd)
            // Notify on the main actor that this connection's session
            // (if any) just dropped.
            Task { @MainActor in
                server.value?.connectionClosed(fd: fd)
            }
        }
        var pending = Data()
        var readBuf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = readBuf.withUnsafeMutableBufferPointer { buf -> Int in
                Darwin.read(fd, buf.baseAddress, buf.count)
            }
            if n <= 0 { return }
            pending.append(readBuf, count: n)
            while let nlIdx = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[pending.startIndex..<nlIdx])
                pending.removeSubrange(pending.startIndex...nlIdx)
                if line.isEmpty { continue }
                await ControlServer.handleLine(line, fd: fd, server: server)
            }
        }
    }

    private nonisolated static func handleLine(
        _ line: Data,
        fd: Int32,
        server: WeakRef<ControlServer>
    ) async {
        let responseData: Data
        do {
            let req = try ControlRequest.decode(line: line)
            let encoded = await Task { @MainActor in
                guard let srv = server.value else {
                    return try? encodeProtocolError(id: req.id, error: "server stopped")
                }
                // Hello fast-path: the app — not the sidecar — is the
                // authority on session_id. Decode here so we can call
                // the allocator + registerSession on the *granted*
                // id, then return the response directly. Skipping
                // ControlHandlers.dispatch for "hello" keeps the
                // fd-needing logic out of the handler signature.
                if req.kind == "hello" {
                    return try? handleHelloAllocating(req: req, fd: fd, server: srv)
                }
                return await ControlHandlers.dispatch(req, delegate: srv.appDelegate)
            }.value
            guard let data = encoded else { return }
            responseData = data
        } catch let error as ControlError {
            guard let data = try? encodeProtocolError(id: nil, error: error.protocolMessage) else { return }
            responseData = data
        } catch {
            guard let data = try? encodeProtocolError(id: nil, error: "parse: \(error.localizedDescription)") else { return }
            responseData = data
        }
        var withNewline = responseData
        withNewline.append(0x0A)
        withNewline.withUnsafeBytes { raw in
            ControlServer.writeAll(raw.baseAddress!, raw.count, to: fd)
        }
    }

    /// Hello fast-path body: decode claim, allocate granted id,
    /// register with SessionManager, encode the HelloResult response.
    /// Pulled out for readability; called only from `handleLine`.
    @MainActor
    private static func handleHelloAllocating(
        req: ControlRequest,
        fd: Int32,
        server srv: ControlServer
    ) throws -> Data {
        let payload = try req.decodePayload(HelloRequest.self)
        let granted = srv.allocateSessionId(
            claim: payload.sessionId,
            fd: fd,
            parentPid: payload.parentPid
        )
        NSLog("QuickShow: hello from session=\(granted) client=\(payload.client ?? "?") ppid=\(payload.parentPid.map(String.init) ?? "?") (claim=\(payload.sessionId))")
        srv.appDelegate?.sessionManager.registerSession(granted, parentPid: payload.parentPid)
        return try ControlProtocol.encoder.encode(ControlOk(
            id: req.id,
            result: HelloResult(
                version: ControlProtocol.version,
                pid: getpid(),
                sessionId: granted
            )
        ))
    }

    private nonisolated static func encodeProtocolError(id: String?, error: String) throws -> Data {
        try ControlProtocol.encoder.encode(ControlProtocolError(id: id, error: error))
    }

    private nonisolated static func writeAll(
        _ buf: UnsafeRawPointer,
        _ count: Int,
        to fd: Int32
    ) {
        var written = 0
        while written < count {
            let n = Darwin.write(fd, buf.advanced(by: written), count - written)
            if n <= 0 { return }
            written += n
        }
    }
}

// Sendable weak-reference shim — the per-connection async tasks hold
// it across actor hops, and `weak self` doesn't survive that.
private final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

enum ControlServerError: Error, CustomStringConvertible {
    case systemError(String, Int32)
    case pathTooLong(String)

    var description: String {
        switch self {
        case let .systemError(op, err):
            return "\(op) failed: \(String(cString: strerror(err)))"
        case let .pathTooLong(p):
            return "socket path too long (>\(MemoryLayout<sockaddr_un>.size) bytes): \(p)"
        }
    }
}
