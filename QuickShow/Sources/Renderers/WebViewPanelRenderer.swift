import Cocoa
import WebKit

/// Base class for renderers that drive a `WKWebView` with a bundled
/// HTML template. Subclasses override `templateName` and `prepareBody`
/// to map the wire payload to the JS bridge call.
///
/// Security posture (per PRD § "Free-tier defenses, baked into Phase 1"):
/// - One `WKProcessPool` per renderer instance (cross-panel state
///   leakage impossible by construction).
/// - CSP enforced via `<meta http-equiv>` in the HTML template:
///   `connect-src 'none'` blocks all exfiltration network calls.
/// - Single `WKScriptMessageHandler` named `renderComplete` — no
///   other JS bridge surface area.
/// - `decidePolicyForNavigationAction` opens external links via
///   `NSWorkspace.shared.open(_:)` instead of navigating in-place.
///
/// Bridge protocol (with the template):
/// - Template fires `{ready: true, width: 0, height: 0}` on
///   `DOMContentLoaded`.
/// - On each `update()`, we call `window.__quickshow_render(body)` —
///   the template fires `{ok, width, height, error?, line?}` on
///   completion.
/// - A 5 s timeout protects the await; if the bridge never fires,
///   `update()` throws `RenderFailure(message: "render timeout")`.
@MainActor
class WebViewPanelRenderer: NSObject, PanelRenderer, WKNavigationDelegate {
    class var typeKey: String { fatalError("subclass must override typeKey") }

    /// Filename (without extension) of the HTML template in
    /// `Resources/templates/`. Subclasses set this to e.g. "markdown".
    var templateName: String { fatalError("subclass must override templateName") }

    /// Whether the renderer mounts a bundled HTML template at view
    /// creation time and drives updates through the
    /// `__quickshow_render(body)` JS bridge.
    ///
    /// Default is `true` (markdown / svg / mermaid). `HTMLRenderer`
    /// returns `false` and overrides `update(payload:)` to drive the
    /// WebView via `loadHTMLString` directly — that's the only way to
    /// execute `<script>` tags in agent-supplied HTML, since
    /// `innerHTML` silently drops them per the DOM spec.
    var useTemplate: Bool { true }

    /// Subclasses can override to escape / transform the body before
    /// it lands in the JS bridge. Default = identity (raw string).
    func prepareBody(_ body: String, form: String) throws -> String { body }

    static func == (lhs: WebViewPanelRenderer, rhs: WebViewPanelRenderer) -> Bool { lhs === rhs }

    private(set) var webView: WKWebView!
    private let messageHandler = ScriptMessageRelay()
    private let strokeRelay = ScriptMessageRelay()

    /// Fired when the in-DOM `<canvas>` posts a stroke-changed event
    /// (pen up / Cmd+Z). The payload is the full strokes array as the
    /// JS side now has it; SessionManager overwrites `Panel.strokes`
    /// directly. Bound by SessionManager at panel-creation time.
    var onStrokesChanged: (([MarkupStroke]) -> Void)?

    /// Fired when the JS canvas receives an Escape keypress in draw
    /// mode. Host (HUDWindow) toggles draw mode off.
    var onMarkupEscape: (() -> Void)?

    /// Host wrapper that bubbles wheel events past WKWebView to the
    /// parent scroll view (WKWebView would otherwise eat them). Public
    /// so HUDWindow can address it as the markup overlay's canvas
    /// reference (alongside its inner `webView`).
    private(set) var canvasHost: WebViewHostView!

    /// Pan-and-zoom container wrapping `canvasHost`. The renderer's
    /// public `makeView()` returns this; tear-out / reattach reparent
    /// this whole subtree.
    private(set) var scrollView: ZoomableCanvasScrollView!

    /// True after the first successful `update()` that knew a real
    /// canvas size — drives `smartFit()` once per panel, since
    /// subsequent re-renders should preserve the user's pan/zoom.
    private var hasFittedOnce = false

    /// `PanelRenderer.canvasView` — strokes anchor to the inner
    /// WebView, not the outer scroll view. The scroll view's pan/
    /// zoom transform is applied automatically by AppKit's
    /// `NSView.convert` when the overlay renders strokes.
    var canvasView: NSView? { webView }

    private var pendingRender: CheckedContinuation<RenderResult, Error>?
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private enum LoadState { case loading, ready, failed(Error) }
    private var loadState: LoadState = .loading

    func makeView() -> NSView {
        let config = WKWebViewConfiguration()
        // Note: WKProcessPool is deprecated in macOS 12+ (process-pool
        // isolation is now automatic per WKWebView). We rely on the
        // platform's default isolation + a fresh `WKWebsiteDataStore`
        // below for per-panel privacy.
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        config.preferences.setValue(false, forKey: "javaScriptCanAccessClipboard")

        let controller = WKUserContentController()
        messageHandler.onMessage = { [weak self] body in
            self?.handleBridgeMessage(body)
        }
        controller.add(messageHandler, name: "renderComplete")
        strokeRelay.onMessage = { [weak self] body in
            self?.handleMarkupStrokeMessage(body)
        }
        controller.add(strokeRelay, name: "markupStroke")

        // Inject the in-DOM markup canvas (`window.__qsMarkup`) into
        // every WebView. Runs at .atDocumentEnd so <body> exists, then
        // appends a transparent <canvas> that receives pointer events
        // when draw mode is on. Lives across content-type re-renders
        // for template-based renderers (which use innerHTML); a fresh
        // document load (HTMLRenderer's loadHTMLString) re-injects.
        if let markupJS = Self.markupCanvasScriptSource() {
            let userScript = WKUserScript(
                source: markupJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            controller.addUserScript(userScript)
        } else {
            NSLog("QuickShow: markup-canvas.js missing from bundle — markup disabled for this WebView")
        }

        config.userContentController = controller

        let initialSize = NSSize(width: 400, height: 300)
        let wv = WKWebView(
            frame: NSRect(origin: .zero, size: initialSize),
            configuration: config
        )
        wv.navigationDelegate = self
        // Disable bounce / overscroll halos on macOS.
        wv.setValue(false, forKey: "drawsBackground")
        // Explicit: we drive zoom via the outer NSScrollView, not via
        // WKWebView's own magnification gesture.
        wv.allowsMagnification = false
        webView = wv

        // Host wraps the WebView and bubbles scroll-wheel events to
        // the parent scroll view. WKWebView would otherwise consume
        // them before the scroll view's clip view sees them, breaking
        // wheel-zoom.
        let host = WebViewHostView(frame: NSRect(origin: .zero, size: initialSize))
        host.addSubview(wv)
        wv.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: host.topAnchor),
            wv.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        canvasHost = host

        // Outer scroll view: pan + zoom on the host. `documentView` is
        // re-sized to match the canvas dimensions reported by each
        // render so the user can pan around the full document.
        let scroll = ZoomableCanvasScrollView(frame: NSRect(origin: .zero, size: initialSize))
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 8.0
        scroll.usesPredominantAxisScrolling = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = host
        scrollView = scroll

        loadTemplate()
        return scroll
    }

    private func loadTemplate() {
        // Renderers that drive the WebView directly (HTMLRenderer for
        // agent-supplied HTML where `<script>` must execute) opt out
        // here. The WebView starts empty; the subclass's
        // `update(payload:)` is responsible for loading content.
        if !useTemplate {
            loadState = .ready
            return
        }
        let bundle = Bundle.main
        guard
            let templateURL = bundle.url(
                forResource: templateName,
                withExtension: "html",
                subdirectory: "templates"
            )
        else {
            let err = RenderFailure(
                message: "template '\(templateName).html' not found in bundle",
                line: nil
            )
            loadState = .failed(err)
            failAllWaiters(err)
            NSLog("QuickShow: \(err.message)")
            return
        }
        do {
            var html = try String(contentsOf: templateURL, encoding: .utf8)

            // Inline bundled libs + theme so we don't depend on
            // WKWebView's file:// cross-origin policy, which by
            // default forbids file:// → file:// subresource loads.
            // Each `<!--QS_*-->` marker in the template is replaced
            // with a <style>/<script> block containing the bundled
            // content.
            let injections: [(String, String, Bool)] = [
                ("<!--QS_THEME-->",
                 try readBundled("theme", ext: "css", dir: "templates"),
                 false /* is style */),
                ("<!--QS_MARKED-->",
                 (try? readBundled("marked.min", ext: "js", dir: "libs")) ?? "",
                 true /* is script */),
                ("<!--QS_PURIFY-->",
                 (try? readBundled("purify.min", ext: "js", dir: "libs")) ?? "",
                 true /* is script */),
                ("<!--QS_MERMAID-->",
                 (try? readBundled("mermaid.min", ext: "js", dir: "libs")) ?? "",
                 true /* is script */),
            ]
            for (marker, content, isScript) in injections {
                let wrapped: String
                if content.isEmpty {
                    wrapped = "<!-- (no payload for \(marker)) -->"
                } else if isScript {
                    wrapped = "<script>\n\(content)\n</script>"
                } else {
                    wrapped = "<style>\n\(content)\n</style>"
                }
                html = html.replacingOccurrences(of: marker, with: wrapped)
            }
            webView.loadHTMLString(html, baseURL: nil)
        } catch {
            loadState = .failed(error)
            failAllWaiters(error)
            NSLog("QuickShow: failed to load template \(templateName): \(error)")
        }
    }

    private func readBundled(_ name: String, ext: String, dir: String) throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: dir) else {
            throw RenderFailure(
                message: "bundled resource not found: \(dir)/\(name).\(ext)",
                line: nil
            )
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Test-only hook: directly invoke the bridge handler with a
    /// synthesized payload. Exists so the QUICKSHOW_TEST_PREFS smoke
    /// can exercise the `copy` side-channel without driving a real
    /// JS-side button click.
    func testInvokeBridge(_ payload: [String: Any]) {
        handleBridgeMessage(payload)
    }

    /// Parse a payload from the `markupStroke` bridge (posted by
    /// `markup-canvas.js`). Two shapes:
    ///   `{type: "strokesChanged", strokes: [{points, color, width}]}`
    ///   `{type: "escape"}`
    /// Anything else is logged + dropped (forward-compat for new
    /// types). Stroke arrays are JSON-deserialized into Swift
    /// `MarkupStroke` values via JSONSerialization → re-encode → decode.
    private func handleMarkupStrokeMessage(_ body: Any) {
        guard let dict = body as? [String: Any],
              let type = dict["type"] as? String else { return }
        switch type {
        case "strokesChanged":
            let raw = dict["strokes"] as? [Any] ?? []
            let strokes = Self.decodeStrokes(raw)
            onStrokesChanged?(strokes)
        case "escape":
            onMarkupEscape?()
        default:
            NSLog("QuickShow: markupStroke unknown type '\(type)'")
        }
    }

    private static func decodeStrokes(_ raw: [Any]) -> [MarkupStroke] {
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: []) else {
            return []
        }
        return (try? JSONDecoder().decode([MarkupStroke].self, from: data)) ?? []
    }

    private static func markupCanvasScriptSource() -> String? {
        guard let url = Bundle.main.url(
            forResource: "markup-canvas",
            withExtension: "js",
            subdirectory: "scripts"
        ) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Markup JS bridge (public)
    //
    // All entry points forward to `window.__qsMarkup.*` via
    // evaluateJavaScript. The HUD calls these in response to title-bar
    // button taps + tab switches. Stroke arrays are JSON-encoded
    // inline; `getStrokes` parses the JS-returned value back to
    // `[MarkupStroke]` via the same JSONSerialization round-trip.

    func enterDrawMode() async {
        await evalIgnoringError("window.__qsMarkup && window.__qsMarkup.enterDrawMode();")
    }

    func exitDrawMode() async {
        await evalIgnoringError("window.__qsMarkup && window.__qsMarkup.exitDrawMode();")
    }

    func clearMarkup() async {
        await evalIgnoringError("window.__qsMarkup && window.__qsMarkup.clear();")
    }

    func setStrokes(_ strokes: [MarkupStroke]) async {
        guard let data = try? JSONEncoder().encode(strokes),
              let json = String(data: data, encoding: .utf8) else {
            await evalIgnoringError("window.__qsMarkup && window.__qsMarkup.setStrokes([]);")
            return
        }
        await evalIgnoringError("window.__qsMarkup && window.__qsMarkup.setStrokes(\(json));")
    }

    func getStrokes() async -> [MarkupStroke] {
        let raw: Any?
        do {
            raw = try await webView.evaluateJavaScript(
                "(window.__qsMarkup && window.__qsMarkup.getStrokes()) || []"
            )
        } catch {
            return []
        }
        if let arr = raw as? [Any] {
            return Self.decodeStrokes(arr)
        }
        return []
    }

    func popLastStroke() async {
        await evalIgnoringError("window.__qsMarkup && window.__qsMarkup.popLastStroke();")
    }

    /// Test-only: synthesize a stroke directly into the JS canvas as
    /// if the user had drawn it. Used by `QUICKSHOW_TEST_MARKUP_UI` to
    /// drive a deterministic stroke without dispatching pointer events.
    func appendStrokeForTest(_ stroke: MarkupStroke) async {
        guard let data = try? JSONEncoder().encode(stroke),
              let json = String(data: data, encoding: .utf8) else { return }
        await evalIgnoringError(
            "window.__qsMarkup && window.__qsMarkup.appendStrokeForTest(\(json));"
        )
    }

    private func evalIgnoringError(_ js: String) async {
        do {
            _ = try await webView.evaluateJavaScript(js)
        } catch {
            // No-op: a script that fails because the page is mid-load
            // or __qsMarkup hasn't installed yet shouldn't propagate.
        }
    }

    private func handleBridgeMessage(_ body: Any) {
        guard let dict = body as? [String: Any] else { return }
        // Side-channel: a `copy` payload from a code-block button or
        // similar UI affordance. Writes to the system pasteboard.
        // No correlation with the render pipeline — this branch
        // returns immediately without touching pendingRender.
        if let copyText = dict["copy"] as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copyText, forType: .string)
            return
        }
        let isReady = dict["ready"] as? Bool ?? false
        if isReady && pendingRender == nil {
            // First post on DOMContentLoaded.
            loadState = .ready
            resumeReadyWaiters()
            return
        }
        // Render result for a pending update.
        guard let cont = pendingRender else { return }
        pendingRender = nil
        let ok = dict["ok"] as? Bool ?? false
        let width = (dict["width"] as? Double) ?? 0
        let height = (dict["height"] as? Double) ?? 0
        if ok {
            cont.resume(returning: RenderResult(width: width, height: height))
        } else {
            let err = (dict["error"] as? String) ?? "unknown render error"
            let line = dict["line"] as? Int
            cont.resume(throwing: RenderFailure(message: err, line: line))
        }
    }

    private func resumeReadyWaiters() {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for w in waiters { w.resume() }
    }

    private func failAllWaiters(_ error: Error) {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for w in waiters { w.resume(throwing: error) }
        if let p = pendingRender {
            pendingRender = nil
            p.resume(throwing: error)
        }
    }

    private func ensureReady() async throws {
        switch loadState {
        case .ready: return
        case .failed(let e): throw e
        case .loading:
            try await withCheckedThrowingContinuation { c in
                readyWaiters.append(c)
            }
        }
    }

    func update(payload: PanelPayload) async throws -> RenderResult {
        try await ensureReady()
        // Latest-wins on overlapping updates.
        if let prev = pendingRender {
            pendingRender = nil
            prev.resume(throwing: CancellationError())
        }
        let prepared = try prepareBody(payload.body, form: payload.form)

        let result = try await withTimeout(seconds: 5) { [weak self] in
            guard let self = self else { throw RenderFailure(message: "renderer deallocated", line: nil) }
            return try await self.runRender(body: prepared)
        }
        applyCanvasSize(NSSize(width: result.width, height: result.height))
        return result
    }

    /// Pin the WebView + host frame to the document's natural size
    /// so the WebView doesn't reflow on window resize. The outer
    /// `ZoomableCanvasScrollView` handles pan / zoom over this
    /// fixed canvas; the user sees more or less of it depending on
    /// window size. On the first canvas size of this panel's life,
    /// fit to container; later re-renders keep the user's pan/zoom.
    func applyCanvasSize(_ size: NSSize) {
        guard size.width > 0, size.height > 0 else { return }
        let frame = NSRect(origin: .zero, size: size)
        canvasHost.frame = frame
        webView.frame = frame
        canvasHost.layoutSubtreeIfNeeded()
        if !hasFittedOnce {
            scrollView.smartFit()
            hasFittedOnce = true
        }
    }

    private func runRender(body: String) async throws -> RenderResult {
        // Encode body as a JSON-quoted string so it can be safely
        // interpolated into a JS expression (handles backticks,
        // dollar signs, backslashes, newlines, unicode).
        let json: String
        do {
            let data = try JSONSerialization.data(withJSONObject: [body], options: [])
            guard let s = String(data: data, encoding: .utf8) else {
                throw RenderFailure(message: "failed to encode body for JS bridge", line: nil)
            }
            // Trim the surrounding []; what's left is the JSON string literal.
            // ["foo"] → "foo"
            json = String(s.dropFirst().dropLast())
        }
        let js = "window.__quickshow_render(\(json));"
        return try await withCheckedThrowingContinuation { cont in
            self.pendingRender = cont
            Task { @MainActor in
                do {
                    _ = try await self.webView.evaluateJavaScript(js)
                } catch {
                    if self.pendingRender != nil {
                        self.pendingRender = nil
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    func snapshot() async throws -> Data {
        try await SnapshotService.snapshotWebView(webView)
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated {
            NSLog("QuickShow: webView didFail navigation: \(error)")
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated {
            NSLog("QuickShow: webView didFailProvisional: \(error)")
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // WKNavigationDelegate is invoked on the main thread; we just
        // need to bridge that fact to the type system.
        MainActor.assumeIsolated {
            // First navigation is loading our own template — allow it.
            // After that, any navigation is a user-initiated link
            // click; open it in the default browser via NSWorkspace
            // instead of navigating away.
            let isInitial = navigationAction.navigationType == .other
            if isInitial {
                decisionHandler(.allow)
                return
            }
            if let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}

// MARK: - WebView host

/// Thin wrapper around a `WKWebView` whose sole job is to bubble
/// scroll-wheel events to its parent `NSScrollView`'s clip view.
/// Without this, WKWebView eats wheel events before the scroll view
/// sees them — making wheel-zoom in `ZoomableCanvasScrollView`
/// silently fail over the WebView.
///
/// The host is the `documentView` of the scroll view; the WebView is
/// the host's sole subview, autolayout-pinned to fill it.
@MainActor
final class WebViewHostView: NSView {
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
    }
}

// MARK: - Bridge message relay

/// Tiny relay so the renderer class doesn't have to inherit NSObject
/// twice (WKScriptMessageHandler requires NSObject; the renderer base
/// already inherits from NSObject, but conforming there means the
/// `userContentController(_:didReceive:)` selector lifetime is tied to
/// the renderer's lifetime which is fine — but isolating the relay
/// keeps the renderer class focused on its real job).
@MainActor
final class ScriptMessageRelay: NSObject, WKScriptMessageHandler {
    var onMessage: ((Any) -> Void)?

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        // WK invokes this on the main thread; bridge that fact to the
        // type system so we can read `message.body` (which is
        // MainActor-isolated on current SDKs) and call our callback.
        MainActor.assumeIsolated {
            self.onMessage?(message.body)
        }
    }
}

// MARK: - Timeout helper

/// Race `operation` against a sleep. If the sleep wins, throw a
/// `RenderFailure(message: "render timeout")` — the renderer view has
/// not painted an error UI for this case, so the snapshot will reflect
/// the pre-timeout state. That's intentional: a stuck WKWebView is
/// usually a JS-side hang, and the user's existing panel content is
/// still on screen.
private func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable @MainActor () async throws -> T
) async throws -> T {
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { @MainActor in
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw RenderFailure(message: "render timeout after \(seconds)s", line: nil)
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
