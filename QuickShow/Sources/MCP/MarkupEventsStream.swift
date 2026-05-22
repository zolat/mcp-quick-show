import Foundation

// MarkupEventsStream — owns per-group subscribers for the
// `GET /markup-events` NDJSON streaming endpoint. The endpoint lives
// outside the SDK's `/mcp` route precisely because the SDK transport
// enforces "one standalone SSE GET per MCP session" and that slot is
// already claimed by Claude Code's MCP client at initialize time. Our
// custom endpoint sidesteps that limit and gives the harness-Monitor
// path an actual consumable channel.
//
// `group` (Phase 2) is the canonical content namespace — multiple MCP
// sessions writing to the same group share an event stream + artifact
// pool. The subscriber map keys by group so each group has at most one
// open NDJSON connection per consumer.
//
// Architecture:
//   - EventLogWriter posts .quickShowMarkupEvent NotificationCenter
//     events alongside each NDJSON file write. userInfo carries the
//     `group` value.
//   - We observe those events here. For each subscriber whose group
//     matches, yield one NDJSON line into their AsyncStream
//     continuation.
//   - The HTTP handler in MCPHTTPServer consumes the AsyncStream and
//     pumps bytes onto the client FD. Heartbeats live in the handler
//     so a dead peer is detected by write-failure (same pattern as
//     the SDK SSE pump). Handler `defer { removeSubscriber }` closes
//     the continuation on disconnect.
//
// File channel is still the source of truth for forensics + `--resume`;
// this is the live-consumer channel.

@MainActor
final class MarkupEventsStream {

    private final class Subscriber {
        let id = UUID().uuidString
        let group: String
        let continuation: AsyncStream<Data>.Continuation
        var heartbeatTask: Task<Void, Never>?
        init(group: String, continuation: AsyncStream<Data>.Continuation) {
            self.group = group
            self.continuation = continuation
        }
    }

    /// Per-group subscriber map. Multiple subscribers per group are
    /// permitted (unlike the SDK's standalone SSE slot) — useful if
    /// the user wants more than one Monitor on the same group, or
    /// for parallel test rigs.
    private var subscribersByGroup: [String: [String: Subscriber]] = [:]
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .quickShowMarkupEvent,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let group = info["group"] as? String,
                  let type = info["type"] as? String,
                  let panel = info["panel"] as? String
            else { return }
            let artifact = info["artifact"] as? String
            let tsMs = info["ts_ms"] as? Double ?? 0
            Task { @MainActor [weak self] in
                self?.dispatch(
                    group: group,
                    type: type,
                    panel: panel,
                    artifact: artifact,
                    tsMs: tsMs
                )
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    /// True iff at least one live subscriber is connected for this
    /// group. Consulted by `enable_markup_events` to decide whether
    /// to warn Claude that no live consumer is listening.
    func hasSubscriber(group: String) -> Bool {
        !(subscribersByGroup[group]?.isEmpty ?? true)
    }

    /// Register a new subscriber. The returned stream yields one
    /// NDJSON-encoded-line `Data` per markup event (already newline-
    /// terminated). Heartbeats are yielded into the same stream on a
    /// 10s timer so the HTTP handler can stay a single-source consumer
    /// (one race-free loop). The caller pumps each yield onto the FD
    /// and unsubscribes on disconnect.
    func addSubscriber(group: String, heartbeatSeconds: UInt64 = 10) -> (id: String, stream: AsyncStream<Data>) {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let sub = Subscriber(group: group, continuation: continuation)
        subscribersByGroup[group, default: [:]][sub.id] = sub
        // Per-subscriber heartbeat task — yields a heartbeat line every
        // `heartbeatSeconds`. Cancelled on removeSubscriber. Same task
        // continues yielding even if the consumer is slow; the
        // AsyncStream's unbounded buffer absorbs the backlog.
        sub.heartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: heartbeatSeconds * 1_000_000_000)
                if Task.isCancelled { return }
                continuation.yield(Self.heartbeatLine())
            }
        }
        let total = subscribersByGroup[group]?.count ?? 0
        NSLog("QuickShow: markup-events subscribed group=\(group) sub=\(sub.id) total=\(total)")
        return (sub.id, stream)
    }

    /// Drop a subscriber. Idempotent — safe to call twice on the same
    /// id (the handler's `defer` and a stream-end-from-disconnect race
    /// each other). Finishes the underlying continuation so any
    /// in-flight `for await` returns nil.
    func removeSubscriber(id: String, group: String) {
        guard let sub = subscribersByGroup[group]?.removeValue(forKey: id) else { return }
        sub.heartbeatTask?.cancel()
        sub.continuation.finish()
        if subscribersByGroup[group]?.isEmpty == true {
            subscribersByGroup.removeValue(forKey: group)
        }
        let total = subscribersByGroup[group]?.count ?? 0
        NSLog("QuickShow: markup-events unsubscribed group=\(group) sub=\(id) total=\(total)")
    }

    /// One newline-terminated heartbeat line. Used by the per-
    /// subscriber timer task above; exposed nonisolated so the timer
    /// can call it without an actor hop.
    nonisolated static func heartbeatLine() -> Data {
        let tsMs = Int(Date().timeIntervalSince1970 * 1000)
        let s = "{\"type\":\"heartbeat\",\"ts\":\(tsMs)}\n"
        return Data(s.utf8)
    }

    // MARK: - Dispatch

    private func dispatch(
        group: String,
        type: String,
        panel: String,
        artifact: String?,
        tsMs: Double
    ) {
        guard let subs = subscribersByGroup[group], !subs.isEmpty else { return }
        let line = makeNDJSONLine(
            group: group,
            type: type,
            panel: panel,
            artifact: artifact,
            tsMs: tsMs
        )
        for (_, sub) in subs {
            sub.continuation.yield(line)
        }
    }

    private func makeNDJSONLine(
        group: String,
        type: String,
        panel: String,
        artifact: String?,
        tsMs: Double
    ) -> Data {
        // Keep field order stable for grep-readability + test stability.
        // Format mirrors EventLogWriter's file lines so consumers parse
        // one schema regardless of channel.
        var fields: [String] = []
        fields.append("\"type\":\"\(type)\"")
        fields.append("\"panel\":\"\(escapeJSONString(panel))\"")
        if let artifact {
            fields.append("\"artifact\":\"\(artifact)\"")
        }
        fields.append("\"group\":\"\(escapeJSONString(group))\"")
        fields.append("\"ts\":\(Int(tsMs))")
        // Note: file line uses fractional ts (Date * 1000). We coerce
        // to Int here for shape uniformity with file consumers; the
        // sub-ms precision was never load-bearing.
        let json = "{" + fields.joined(separator: ",") + "}\n"
        return Data(json.utf8)
    }

    private func escapeJSONString(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        return out
    }
}

