import Darwin
import Foundation

// PeerPidResolver — given an accepted TCP socket FD, return the PID of
// the process on the other end of the connection.
//
// Implementation: getpeername(fd) gives the client's ephemeral port.
// Walk every PID on the system, list its open FDs, and for each FD
// that's a TCP socket whose local port matches the ephemeral port,
// return that PID. The match is unambiguous on a single host because
// the kernel guarantees ephemeral-port uniqueness per address family
// for the duration of the connection.
//
// Used by the embedded HTTP MCP server to map a connecting Claude
// process to a parent_pid for HUD Space placement, replacing today's
// hello.parent_pid Unix-socket claim with a server-derived value.
//
// This is the same kernel API path that `lsof -i` walks. No
// entitlements required for same-user processes; libproc respects
// the boundary across users.

enum PeerPidResolver {

    /// Resolve the connecting client's PID for an accepted TCP socket
    /// FD. Returns nil if libproc can't find a matching socket — most
    /// commonly when the client has already closed, or when the
    /// connection isn't TCP. Logged with `QuickShow: PeerPidResolver`
    /// prefix on every call (success or failure) so the proof-point
    /// test rig can grep for them.
    static func resolve(fd: Int32, tag: String = "") -> pid_t? {
        guard let peer = peerEndpoint(of: fd) else {
            NSLog("QuickShow: PeerPidResolver \(tag) fd=\(fd) getpeername failed errno=\(errno)")
            return nil
        }
        let t0 = DispatchTime.now()
        let pid = findPid(matchingLocalEndpoint: peer)
        let dtMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
        NSLog(String(
            format: "QuickShow: PeerPidResolver %@ fd=%d peer_port=%d family=%d resolved_pid=%@ walk_ms=%.2f",
            tag, fd, Int(peer.port), Int(peer.family),
            pid.map(String.init) ?? "nil", dtMs
        ))
        return pid
    }

    // MARK: - Internals

    private struct Endpoint {
        let port: UInt16    // host byte order
        let family: Int32   // AF_INET or AF_INET6
    }

    private static func peerEndpoint(of fd: Int32) -> Endpoint? {
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &storage) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getpeername(fd, sa, &len)
            }
        }
        guard rc == 0 else { return nil }
        switch Int32(storage.ss_family) {
        case AF_INET:
            return withUnsafePointer(to: &storage) { ptr in
                ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    Endpoint(
                        port: UInt16(bigEndian: sin.pointee.sin_port),
                        family: AF_INET
                    )
                }
            }
        case AF_INET6:
            return withUnsafePointer(to: &storage) { ptr in
                ptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                    Endpoint(
                        port: UInt16(bigEndian: sin6.pointee.sin6_port),
                        family: AF_INET6
                    )
                }
            }
        default:
            return nil
        }
    }

    private static func findPid(matchingLocalEndpoint peer: Endpoint) -> pid_t? {
        // Phase 1: enumerate all PIDs on the system.
        let probe = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard probe > 0 else { return nil }
        let slack = 32  // grow a little so a freshly-spawned PID between the two calls doesn't get truncated
        let capacity = Int(probe) / MemoryLayout<pid_t>.size + slack
        var pids = [pid_t](repeating: 0, count: capacity)
        let actualBytes = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                buf.baseAddress,
                Int32(buf.count * MemoryLayout<pid_t>.size)
            )
        }
        guard actualBytes > 0 else { return nil }
        let pidCount = Int(actualBytes) / MemoryLayout<pid_t>.size

        // Phase 2: per PID, list FDs and inspect TCP sockets.
        var fdBuffer = [proc_fdinfo](repeating: proc_fdinfo(), count: 128)
        for i in 0..<pidCount {
            let pid = pids[i]
            if pid == 0 { continue }

            // Probe for FD-list size; grow if needed.
            let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            if needed <= 0 { continue }
            let neededCount = Int(needed) / MemoryLayout<proc_fdinfo>.size
            if neededCount > fdBuffer.count {
                fdBuffer = [proc_fdinfo](repeating: proc_fdinfo(), count: neededCount + 16)
            }

            let got = fdBuffer.withUnsafeMutableBufferPointer { buf -> Int32 in
                proc_pidinfo(
                    pid,
                    PROC_PIDLISTFDS,
                    0,
                    buf.baseAddress,
                    Int32(buf.count * MemoryLayout<proc_fdinfo>.size)
                )
            }
            if got <= 0 { continue }
            let fdCount = Int(got) / MemoryLayout<proc_fdinfo>.size

            for j in 0..<fdCount {
                let info = fdBuffer[j]
                if Int32(info.proc_fdtype) != PROX_FDTYPE_SOCKET { continue }
                var sock = socket_fdinfo()
                let sockSize = Int32(MemoryLayout<socket_fdinfo>.size)
                let n = proc_pidfdinfo(
                    pid,
                    info.proc_fd,
                    PROC_PIDFDSOCKETINFO,
                    &sock,
                    sockSize
                )
                if n != sockSize { continue }

                // Filter: TCP only, matching family.
                if Int32(sock.psi.soi_kind) != SOCKINFO_TCP { continue }
                if Int32(sock.psi.soi_family) != peer.family { continue }

                // Local port stored as `int` in network byte order
                // — the high 16 bits are unused.
                let rawLport = sock.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport
                let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: rawLport))
                if localPort == peer.port {
                    return pid
                }
            }
        }
        return nil
    }
}
