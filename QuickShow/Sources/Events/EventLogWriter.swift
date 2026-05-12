import Darwin
import Foundation

/// Appends NDJSON events to the per-session log that Claude tails via
/// the `Monitor` tool. Two event types are emitted, no more:
///   `markup_sent`      — user pressed Send on a markup-capable panel
///   `markup_dismissed` — user closed the panel without sending
///
/// Volume discipline matters: Monitor auto-stops on too many events, so
/// internal HUD chatter (clicks, drags, tab switches) must never reach
/// this file.
///
/// Concurrency model: one writer per session, serialized through a
/// dedicated queue. The underlying file is opened `O_APPEND` so even
/// cross-process writes (e.g. a second app instance) stay line-atomic
/// for short payloads.
final class EventLogWriter: @unchecked Sendable {
    private let sessionId: String
    private let queue: DispatchQueue
    private var fd: Int32 = -1

    init(sessionId: String) {
        self.sessionId = sessionId
        self.queue = DispatchQueue(label: "QuickShow.EventLogWriter.\(sessionId)")
    }

    deinit {
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    /// Emit a `markup_sent` line. `artifact` is the UUID of the PNG
    /// already written into the session's artifacts dir.
    func emitMarkupSent(panel: String, artifact: String) {
        emit([
            "type": .string("markup_sent"),
            "panel": .string(panel),
            "artifact": .string(artifact),
            "ts": .number(Date().timeIntervalSince1970 * 1000),
        ])
    }

    /// Emit a `markup_dismissed` line. No artifact — user closed the
    /// panel before sending.
    func emitMarkupDismissed(panel: String) {
        emit([
            "type": .string("markup_dismissed"),
            "panel": .string(panel),
            "ts": .number(Date().timeIntervalSince1970 * 1000),
        ])
    }

    // MARK: - Internals

    private enum JSONValue {
        case string(String)
        case number(Double)
        case bool(Bool)
    }

    private func emit(_ fields: [String: JSONValue]) {
        let line = renderLine(fields)
        queue.async { [weak self] in
            self?.writeLine(line)
        }
    }

    private func writeLine(_ line: String) {
        if fd < 0 {
            do {
                try MarkupPaths.ensureDirs(sessionId)
            } catch {
                NSLog("QuickShow: EventLogWriter ensureDirs failed for \(sessionId): \(error)")
                return
            }
            let path = MarkupPaths.eventsLog(sessionId).path
            fd = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            if fd < 0 {
                NSLog("QuickShow: EventLogWriter open failed for \(path): errno=\(errno)")
                return
            }
        }
        var data = Array(line.utf8)
        data.append(0x0A) // newline
        let n = data.withUnsafeBufferPointer { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            return Darwin.write(fd, base, buf.count)
        }
        if n < 0 {
            NSLog("QuickShow: EventLogWriter write failed (errno=\(errno))")
        }
    }

    /// Tiny JSON serializer for the fixed shape of our events. Keeps
    /// the file dependency-free and lets us guarantee single-line
    /// output without coaxing JSONEncoder. Field order is preserved by
    /// the call site (Swift dictionaries don't preserve insertion order,
    /// so we sort keys with a small bias toward `type` first for grep
    /// readability).
    private func renderLine(_ fields: [String: JSONValue]) -> String {
        let keys = fields.keys.sorted { (a, b) in
            if a == "type" { return true }
            if b == "type" { return false }
            return a < b
        }
        var parts: [String] = []
        for k in keys {
            guard let v = fields[k] else { continue }
            parts.append("\(jsonString(k)):\(encode(v))")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    private func encode(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): return jsonString(s)
        case .number(let n):
            // Integer-valued doubles render without a trailing `.0`
            // so timestamps stay compact and JSON-numeric.
            if n.truncatingRemainder(dividingBy: 1) == 0 && abs(n) < 1e15 {
                return String(Int64(n))
            }
            return String(n)
        case .bool(let b): return b ? "true" : "false"
        }
    }

    private func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out += String(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
