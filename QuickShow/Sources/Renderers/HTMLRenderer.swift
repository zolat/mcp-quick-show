import Cocoa
import WebKit

/// Renders agent-supplied HTML straight into a `WKWebView` — no bundled
/// template, no `__quickshow_render(body)` bridge. The `innerHTML`
/// pattern used by Markdown/SVG/Mermaid templates silently drops
/// `<script>` tags per the DOM spec, which makes it unusable for the
/// flagship use case: interactive design demos that need scripts.
///
/// **Security posture:** for v0.1 the agent's HTML is accepted at face
/// value — same trust posture as agent-authored markdown/svg/mermaid.
/// PRD § show_html deferred the strict-CSP design pass to v0.2.
///
/// Width/height for the `RenderResult` come from a post-load JS read of
/// `document.documentElement.scrollWidth/scrollHeight` since there's no
/// `renderComplete` bridge to ferry them back automatically.
@MainActor
final class HTMLRenderer: WebViewPanelRenderer {
    override class var typeKey: String { "html" }

    /// Unused — `useTemplate = false` short-circuits the loader — but
    /// the base's `templateName` is non-optional, so we satisfy it.
    override var templateName: String { "__no_template__" }

    /// Opt out of the bundled-template pipeline.
    override var useTemplate: Bool { false }

    /// Continuation for the in-flight `loadHTMLString`. Resolved by
    /// `didFinish` (success) / `didFail` (error) / `didFailProvisional`
    /// (error). Latest-wins on overlapping updates.
    private var pendingLoad: CheckedContinuation<RenderResult, Error>?

    override func update(payload: PanelPayload) async throws -> RenderResult {
        guard payload.form == "inline" else {
            throw RenderFailure(
                message: "show_html only supports `form: inline` in v0.1",
                line: nil
            )
        }
        // Cancel any in-flight load — the agent gave us new content.
        if let prev = pendingLoad {
            pendingLoad = nil
            prev.resume(throwing: CancellationError())
        }
        // Width hint: sizes the WebView's CSS viewport *before*
        // `loadHTMLString` so responsive designs lay out at the
        // agent's intended width rather than the default 400pt. We
        // also bump the host so the scroll-view's `documentView`
        // bounds match — without this, smartFit might pick the
        // wrong zoom level on the first measure.
        if let hintWidth = payload.width, hintWidth >= 100 {
            let hintHeight = max(webView.bounds.height, 600)
            let target = NSRect(
                origin: .zero,
                size: NSSize(width: hintWidth, height: hintHeight)
            )
            webView.frame = target
            canvasHost.frame = target
            canvasHost.layoutSubtreeIfNeeded()
        }
        // Each fresh `loadHTMLString` tears down the document — and
        // with it `window.__qsMarkup`. Reset the readiness flag so any
        // markup call queued after this point waits for the user
        // script to re-install the shim on the new doc.
        resetMarkupReady()
        return try await withCheckedThrowingContinuation { cont in
            self.pendingLoad = cont
            self.webView.loadHTMLString(payload.body, baseURL: nil)
        }
    }

    // MARK: - WKNavigationDelegate hooks

    /// `loadHTMLString` finished. Measure the document size for the
    /// `RenderResult` and resolve the pending continuation.
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            guard self.pendingLoad != nil else { return }
            let js = "[document.documentElement.scrollWidth, document.documentElement.scrollHeight]"
            Task { @MainActor in
                let size: (Double, Double)
                do {
                    let result = try await self.webView.evaluateJavaScript(js)
                    if let arr = result as? [Any], arr.count == 2,
                       let w = (arr[0] as? NSNumber)?.doubleValue,
                       let h = (arr[1] as? NSNumber)?.doubleValue {
                        size = (w, h)
                    } else {
                        size = (0, 0)
                    }
                } catch {
                    // Measurement failure isn't fatal — surface zero
                    // size and let the HUD's defaults take over.
                    size = (0, 0)
                }
                if let cont = self.pendingLoad {
                    self.pendingLoad = nil
                    // Same canvas-pinning the base class does in its
                    // template-driven `update`. Keep `applyCanvasSize`
                    // on the success path so the user's pan/zoom is
                    // preserved across re-renders.
                    self.applyCanvasSize(NSSize(width: size.0, height: size.1))
                    cont.resume(returning: RenderResult(width: size.0, height: size.1))
                }
            }
        }
    }

    override nonisolated func webView(_ webView: WKWebView,
                                      didFail navigation: WKNavigation!,
                                      withError error: any Error) {
        super.webView(webView, didFail: navigation, withError: error)
        MainActor.assumeIsolated {
            if let cont = self.pendingLoad {
                self.pendingLoad = nil
                cont.resume(throwing: RenderFailure(
                    message: "html load failed: \(error.localizedDescription)",
                    line: nil
                ))
            }
        }
    }

    override nonisolated func webView(_ webView: WKWebView,
                                      didFailProvisionalNavigation navigation: WKNavigation!,
                                      withError error: any Error) {
        super.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
        MainActor.assumeIsolated {
            if let cont = self.pendingLoad {
                self.pendingLoad = nil
                cont.resume(throwing: RenderFailure(
                    message: "html load failed (provisional): \(error.localizedDescription)",
                    line: nil
                ))
            }
        }
    }
}
