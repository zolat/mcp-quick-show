import Foundation

/// Per-panel rate limiter for `panel_event` lines.
///
/// A misbehaving page (mousemove handler, scroll handler, animation
/// loop calling `window.quickshow.emit`) could fire thousands of
/// events per second. Monitor auto-stops on high event volume, and a
/// runaway page would blow past that, breaking the Claude-side push
/// channel for the whole session.
///
/// Token bucket: capacity = `capacity` events, refilled at
/// `capacity` events/second (i.e. one token per `1/capacity` seconds).
/// Admitted emits call `writer.emitPanelEvent(...)` directly. Excess
/// emits are dropped; a 1Hz background task emits a single
/// `panel_event_dropped {panel, dropped: N}` summary line per second
/// when N > 0. No drops → no summary line, keeping the events log
/// clean when the panel is well-behaved.
///
/// The throttle is `@MainActor`-isolated because the renderer's
/// `onPanelEvent` callback fires on the main actor. The reporter task
/// is scheduled on the same actor.
@MainActor
final class PanelEventThrottle {
    private let panel: String
    private let capacity: Double
    /// Tokens currently available. Starts full so a panel can emit
    /// `capacity` events instantaneously on render before the bucket
    /// begins to deplete.
    private var tokens: Double
    private var lastRefill: Date
    private var droppedSinceReport: Int = 0
    private var reporterTask: Task<Void, Never>?

    init(panel: String, capacity: Int = 20) {
        self.panel = panel
        self.capacity = Double(capacity)
        self.tokens = Double(capacity)
        self.lastRefill = Date()
    }

    deinit {
        // Note: deinit runs on whichever actor the last reference is
        // released on. Cancelling a Task is thread-safe.
        reporterTask?.cancel()
    }

    /// Try to admit one event. If a token is available, persist via
    /// `writer.emitPanelEvent(...)`; otherwise increment the drop
    /// counter (a 1Hz reporter will flush it).
    func admit(payload: Any, writer: EventLogWriter) {
        refill()
        if tokens >= 1.0 {
            tokens -= 1.0
            writer.emitPanelEvent(panel: panel, payload: payload)
        } else {
            droppedSinceReport &+= 1
            ensureReporter(writer: writer)
        }
    }

    private func refill() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        guard elapsed > 0 else { return }
        // Refill at `capacity` tokens/sec (so a 20-cap bucket regains
        // one token every 50 ms).
        tokens = min(capacity, tokens + elapsed * capacity)
        lastRefill = now
    }

    /// Start the 1Hz drop-summary task on first drop. Tears itself
    /// down once the drop counter has been zero for a full tick — the
    /// next drop will rearm it.
    private func ensureReporter(writer: EventLogWriter) {
        if reporterTask != nil { return }
        let panel = self.panel
        reporterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                let dropped = self.droppedSinceReport
                self.droppedSinceReport = 0
                if dropped > 0 {
                    writer.emitPanelEventDropped(panel: panel, dropped: dropped)
                } else {
                    // No drops this tick — stop the reporter; admit()
                    // will restart it on the next drop.
                    self.reporterTask = nil
                    return
                }
            }
        }
    }
}
