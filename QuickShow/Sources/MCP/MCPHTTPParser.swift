import Darwin
import Foundation
import MCP

// MCPHTTPParser — minimal HTTP/1.1 framing for the embedded MCP
// server. Reads request lines + headers + Content-Length body off a
// raw FD into the SDK's `HTTPRequest` value type. Writes responses
// back, including SSE streams via `HTTPResponse.stream`.
//
// Scope: localhost-only, single-host (`Host: 127.0.0.1`), no
// chunked transfer encoding, no keep-alive, no compression. We
// accept exactly one request per connection then close. That's
// sufficient for what Claude Code's HTTP MCP client sends and keeps
// the parser tiny.

enum MCPHTTPParser {

    enum ReadError: Error {
        case clientClosed
        case malformed(String)
        case oversized(Int)
        case ioError(Int32)  // errno
    }

    /// Hard cap on request size (16 MB). The HTML body sent via
    /// `show_html` is capped at 10 MB in `_groupingFields.ts`, so 16
    /// MB leaves headroom for headers and JSON-RPC envelope.
    static let maxRequestBytes = 16 * 1024 * 1024

    /// Hard cap on the size of the head (request-line + headers).
    /// 64 KB matches what nginx/apache use as a sane upper bound.
    static let maxHeadBytes = 64 * 1024

    // MARK: - Reading

    /// Read one HTTP/1.1 request off the given FD into an `MCP.HTTPRequest`.
    /// Blocks until the request is fully read or the connection drops.
    /// Throws on malformed input, oversize, or I/O error.
    static func readRequest(fd: Int32) throws -> HTTPRequest {
        var pending = Data()
        var headEnd: Int? = nil

        // 1) Read until we see CRLFCRLF (end of headers).
        while headEnd == nil {
            if pending.count > maxHeadBytes {
                throw ReadError.oversized(pending.count)
            }
            try readMore(into: &pending, fd: fd)
            headEnd = findHeadEnd(in: pending)
        }

        let headData = pending.prefix(headEnd!)
        let head = String(decoding: headData, as: UTF8.self)
        let (method, path, rawHeaders) = try parseHead(head)
        // Lowercase all header names up-front so Content-Length, Host,
        // Mcp-Session-Id etc. all key uniformly downstream.
        var headers: [String: String] = [:]
        for (k, v) in rawHeaders {
            headers[k.lowercased()] = v
        }

        // 2) Read body per Content-Length, if any.
        let bodyStart = headEnd! + 4  // skip CRLFCRLF
        var body = Data()
        if let lenStr = headers["content-length"], let len = Int(lenStr), len > 0 {
            if len > maxRequestBytes {
                throw ReadError.oversized(len)
            }
            // Already-buffered tail of `pending` is part of the body.
            let already = pending.suffix(from: pending.startIndex.advanced(by: bodyStart))
            body.append(contentsOf: already)
            while body.count < len {
                try readMore(into: &body, fd: fd, want: len - body.count)
            }
            if body.count > len {
                body = body.prefix(len)
            }
        }

        return HTTPRequest(
            method: method,
            headers: headers,
            body: body.isEmpty ? nil : body,
            path: path
        )
    }

    private static func readMore(into buf: inout Data, fd: Int32, want: Int = 4096) throws {
        var chunk = [UInt8](repeating: 0, count: max(want, 4096))
        let n = chunk.withUnsafeMutableBufferPointer { p -> Int in
            Darwin.read(fd, p.baseAddress, p.count)
        }
        if n == 0 {
            throw ReadError.clientClosed
        }
        if n < 0 {
            throw ReadError.ioError(errno)
        }
        buf.append(chunk, count: n)
    }

    private static func findHeadEnd(in buf: Data) -> Int? {
        // Look for CRLF CRLF (0x0D 0x0A 0x0D 0x0A).
        guard buf.count >= 4 else { return nil }
        let bytes = [UInt8](buf)
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0x0D, bytes[i+1] == 0x0A, bytes[i+2] == 0x0D, bytes[i+3] == 0x0A {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func parseHead(_ head: String) throws -> (String, String, [String: String]) {
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let first = lines.first else {
            throw ReadError.malformed("empty head")
        }
        // Request line: METHOD SP PATH SP HTTP/1.1
        let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3 else {
            throw ReadError.malformed("request line: \(first)")
        }
        let method = parts[0]
        let path = parts[1]
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            guard let colonIdx = line.firstIndex(of: ":") else {
                throw ReadError.malformed("header line: \(line)")
            }
            let name = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return (method, path, headers)
    }

    // MARK: - Writing

    /// Write a non-streaming HTTPResponse (`.accepted`, `.ok`, `.data`,
    /// `.error`) to the FD. Returns when bytes are flushed (best
    /// effort — kernel send buffer permitting). Does NOT close the FD.
    static func writeResponse(_ resp: HTTPResponse, to fd: Int32) {
        let status = resp.statusCode
        let reason = reasonPhrase(for: status)
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        var headers = resp.headers
        let bodyData = resp.bodyData ?? Data()
        // Always-on framing headers.
        if headers["Content-Length"] == nil && headers["Transfer-Encoding"] == nil {
            headers["Content-Length"] = String(bodyData.count)
        }
        if headers["Connection"] == nil {
            headers["Connection"] = "close"
        }
        for (k, v) in headers {
            head.append("\(k): \(v)\r\n")
        }
        head.append("\r\n")
        writeAll(head.data(using: .utf8) ?? Data(), to: fd)
        if !bodyData.isEmpty {
            writeAll(bodyData, to: fd)
        }
    }

    /// Write SSE response headers (200 + text/event-stream + per-stream
    /// extras) then pump events from the SDK's AsyncThrowingStream
    /// onto the wire as `data: <json>\n\n` frames. Returns when the
    /// stream ends, the client closes, or a write fails.
    ///
    /// No application-level heartbeat here: the previous experiment
    /// destabilized Claude Code's MCP client (reconnect-every-10s
    /// cycle that lined up with the heartbeat interval), and since
    /// Phase 1.6.1 the markup channel lives on the off-MCP
    /// /markup-events endpoint — this pump no longer needs to surface
    /// dead-peer signals to any business logic.
    static func writeStream(
        _ stream: AsyncThrowingStream<Data, Swift.Error>,
        extraHeaders: [String: String],
        to fd: Int32
    ) async {
        var head = "HTTP/1.1 200 OK\r\n"
        var headers = extraHeaders
        if headers["Content-Type"] == nil {
            headers["Content-Type"] = "text/event-stream"
        }
        if headers["Cache-Control"] == nil {
            headers["Cache-Control"] = "no-cache"
        }
        if headers["Connection"] == nil {
            headers["Connection"] = "keep-alive"
        }
        for (k, v) in headers {
            head.append("\(k): \(v)\r\n")
        }
        head.append("\r\n")
        writeAll(head.data(using: .utf8) ?? Data(), to: fd)

        // The SDK ships each event already SSE-formatted (`id: <n>\n
        // event: message\ndata: <json>\n\n`), so we just relay bytes.
        do {
            for try await chunk in stream {
                if !writeAll(chunk, to: fd) { return }
            }
        } catch {
            NSLog("QuickShow: MCPHTTPParser stream error: \(error)")
        }
    }

    /// Write all bytes of `data` to `fd`. Returns false if any write
    /// returns ≤ 0 (peer closed, EPIPE — SO_NOSIGPIPE means we get
    /// the errno without a process-level signal). Public so the
    /// off-MCP /markup-events handler can reuse the same blocking-
    /// write helper.
    @discardableResult
    static func writeAllBytes(_ data: Data, to fd: Int32) -> Bool {
        return writeAll(data, to: fd)
    }

    @discardableResult
    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        var written = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while written < data.count {
                let n = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if n <= 0 { return false }
                written += n
            }
            return true
        }
    }

    // MARK: - Helpers

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 415: return "Unsupported Media Type"
        case 500: return "Internal Server Error"
        default:  return "OK"
        }
    }
}
