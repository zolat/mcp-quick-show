// QuickShow panel-event bridge — injected into every WebView via
// WKUserScript at .atDocumentStart. Defines `window.quickshow.emit`
// so agent-supplied HTML can post structured events back to Claude
// (see `enable_panel_events` and the `panel_event` line shape in
// events.ndjson).
//
// Surface: window.quickshow.emit(payload)
//   payload: arbitrary JSON-serializable value (typically
//            {type: "...", ...}). Free-form; semantics live in the
//            agent's skill + the rendered page.
//
// Messages posted to webkit.messageHandlers.panelEvent: payload itself.
// Anything non-serializable will be silently dropped by WebKit's
// bridge — keep payloads JSON-clean.
//
// Re-injection: .atDocumentStart re-runs on every full document load
// (HTMLRenderer.loadHTMLString reloads), so the idempotency guard
// below is a belt-and-suspenders against accidental double-injection.
// For template renderers that swap innerHTML inside an unchanged
// document, this script ran once and `window.quickshow` persists.
(function () {
    if (window.quickshow && typeof window.quickshow.emit === "function") {
        return;
    }
    window.quickshow = window.quickshow || {};
    window.quickshow.emit = function (payload) {
        try {
            var mh = window.webkit && window.webkit.messageHandlers;
            if (mh && mh.panelEvent) {
                mh.panelEvent.postMessage(payload);
            }
        } catch (_) {
            // Host not ready or message handler removed — drop the
            // emit silently. Mirrors markup-canvas.js's posture.
        }
    };
})();
