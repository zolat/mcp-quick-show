import Darwin
import Foundation

/// Appends NDJSON events to the per-group log that Claude tails via
/// the `Monitor` tool. Four event types are emitted:
///   `markup_sent`         — user pressed Send on a markup-capable panel
///   `markup_dismissed`    — user closed the panel without sending
///   `panel_event`         — agent HTML called `window.quickshow.emit(payload)`
///   `panel_event_dropped` — throttle summary; emitted at most 1Hz/panel
///                           and only when drops actually occurred.
///
/// Volume discipline matters: Monitor auto-stops on too many events, so
/// internal HUD chatter (clicks, drags, tab switches) must never reach
/// this file. `panel_event` lines are gated by an arming flag + a token
/// bucket — see `SessionManager.wirePanelEvents` for the throttle.
///
/// Concurrency model: one writer per group, serialized through a
/// dedicated queue. The underlying file is opened `O_APPEND` so even
/// cross-process writes (e.g. a second app instance, or two MCP
/// sessions sharing a group) stay line-atomic for short payloads.
final class EventLogWriter: @unchecked Sendable {
    private let group: String
    private let queue: DispatchQueue
    private var fd: Int32 = -1

    init(group: String) {
        self.group = group
        self.queue = DispatchQueue(label: "QuickShow.EventLogWriter.\(group)")
    }

    deinit {
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    /// Emit a `markup_sent` line. `artifact` is the UUID of the PNG
    /// already written into the group's artifacts dir.
    func emitMarkupSent(panel: String, artifact: String) {
        let tsMs = Date().timeIntervalSince1970 * 1000
        emit([
            "type": .string("markup_sent"),
            "panel": .string(panel),
            "artifact": .string(artifact),
            "ts": .number(tsMs),
        ])
        postMarkupNotification(type: "markup_sent", panel: panel, artifact: artifact, tsMs: tsMs)
    }

    /// Emit a `markup_dismissed` line. No artifact — user closed the
    /// panel before sending.
    func emitMarkupDismissed(panel: String) {
        let tsMs = Date().timeIntervalSince1970 * 1000
        emit([
            "type": .string("markup_dismissed"),
            "panel": .string(panel),
            "ts": .number(tsMs),
        ])
        postMarkupNotification(type: "markup_dismissed", panel: panel, artifact: nil, tsMs: tsMs)
    }

    /// Post a `quickShowMarkupEvent` NotificationCenter event alongside
    /// each NDJSON write. The HTTP MCP layer's MCPSessionRouter listens
    /// and fans the event out via `server.notify(LogMessageNotification)`
    /// so MCP SSE consumers receive the same payload. The file channel
    /// remains the source of truth for resume + forensic semantics; SSE
    /// is the live-consumer channel.
    private func postMarkupNotification(type: String, panel: String, artifact: String?, tsMs: Double) {
        var info: [String: Any] = [
            "group": group,
            "type": type,
            "panel": panel,
            "ts_ms": tsMs,
        ]
        if let artifact { info["artifact"] = artifact }
        NotificationCenter.default.post(
            name: .quickShowMarkupEvent,
            object: nil,
            userInfo: info
        )
    }

    /// Emit a `panel_event` line. `payload` is the agent-defined value
    /// passed to `window.quickshow.emit(...)`; we serialize whatever
    /// JSON-shaped value it is (object, array, scalar, null). Anything
    /// not JSON-serializable is dropped at the `JSONValue.from(_:)`
    /// step with an NSLog.
    func emitPanelEvent(panel: String, payload: Any) {
        emit([
            "type": .string("panel_event"),
            "panel": .string(panel),
            "payload": JSONValue.from(payload),
            "ts": .number(Date().timeIntervalSince1970 * 1000),
        ])
    }

    /// Emit a `panel_event_dropped` summary. Fired at most 1Hz/panel
    /// by the throttle, and only when `dropped > 0`.
    func emitPanelEventDropped(panel: String, dropped: Int) {
        emit([
            "type": .string("panel_event_dropped"),
            "panel": .string(panel),
            "dropped": .number(Double(dropped)),
            "ts": .number(Date().timeIntervalSince1970 * 1000),
        ])
    }

    // MARK: - Internals

    enum JSONValue {
        case string(String)
        case number(Double)
        case bool(Bool)
        case null
        case array([JSONValue])
        /// Ordered key/value pairs (insertion order preserved, used so
        /// nested objects round-trip in a predictable order for
        /// grep-readability and tests).
        case object([(String, JSONValue)])

        /// Convert an arbitrary JSON-shaped Swift value (typically what
        /// arrives off `WKScriptMessage.body`) into a `JSONValue`.
        /// Returns `.null` for anything we can't represent and NSLog's
        /// the offending type — keeps the writer side total.
        static func from(_ value: Any) -> JSONValue {
            if value is NSNull { return .null }
            if let s = value as? String { return .string(s) }
            // NSNumber tri-state: bool / int / double. CFNumberGetType
            // is the only reliable way to distinguish bool from
            // 0/1-valued numerics (Swift's `as? Bool` succeeds for
            // NSNumber("1"), giving false positives).
            if let n = value as? NSNumber {
                if CFGetTypeID(n) == CFBooleanGetTypeID() {
                    return .bool(n.boolValue)
                }
                return .number(n.doubleValue)
            }
            if let b = value as? Bool { return .bool(b) }
            if let arr = value as? [Any] {
                return .array(arr.map { JSONValue.from($0) })
            }
            if let dict = value as? [String: Any] {
                // Sort keys for deterministic encoding so tests and
                // diffs are stable. Round-trip order matters less than
                // determinism.
                let pairs = dict.keys.sorted().map { k in (k, JSONValue.from(dict[k] as Any)) }
                return .object(pairs)
            }
            NSLog("QuickShow: EventLogWriter.JSONValue.from received unsupported type \(type(of: value)) — coerced to null")
            return .null
        }
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
                try MarkupPaths.ensureDirs(group)
            } catch {
                NSLog("QuickShow: EventLogWriter ensureDirs failed for \(group): \(error)")
                return
            }
            let path = MarkupPaths.eventsLog(group).path
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
            // so timestamps stay compact and JSON-numeric. Guard
            // against NaN/Inf (not JSON-valid) — emit null instead.
            if n.isNaN || n.isInfinite { return "null" }
            if n.truncatingRemainder(dividingBy: 1) == 0 && abs(n) < 1e15 {
                return String(Int64(n))
            }
            return String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let items):
            return "[" + items.map { encode($0) }.joined(separator: ",") + "]"
        case .object(let pairs):
            let body = pairs.map { (k, v) in "\(jsonString(k)):\(encode(v))" }
                .joined(separator: ",")
            return "{" + body + "}"
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
