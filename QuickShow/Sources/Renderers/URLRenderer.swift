import Cocoa
import WebKit

/// Loads a live URL in a `WKWebView` and snapshots it once the load
/// completes. Sibling of `HTMLRenderer`: same `useTemplate = false`
/// shape, same `pendingLoad` continuation pattern, but driven by
/// `WKWebView.load(URLRequest:)` instead of `loadHTMLString`.
///
/// **Navigation policy:** the page's first commit "anchors" the host;
/// subsequent same-host link activations navigate in-place, while
/// cross-host clicks (and `target=_blank`) route through
/// `NSWorkspace.shared.open(_:)`. An agent-driven `update(payload:)`
/// always loads in-place — the host anchor is reset for each
/// agent-initiated navigation.
///
/// **Security posture:** the loaded page brings its own origin CSP.
/// We keep `WKWebsiteDataStore.nonPersistent()` (per-panel isolation,
/// inherited from `WebViewPanelRenderer`). The bridge scripts
/// (`quickshow-bridge.js`, `markup-canvas.js`) are injected via
/// `WKUserContentController`, which bypasses page CSP by design — so
/// the markup-feedback loop and `quickshow.emit` work on URL panels.
@MainActor
final class URLRenderer: WebViewPanelRenderer {
    override class var typeKey: String { "url" }

    /// Unused — `useTemplate = false` short-circuits the loader — but
    /// the base's `templateName` is non-optional, so we satisfy it.
    override var templateName: String { "__no_template__" }

    /// Opt out of the bundled-template pipeline.
    override var useTemplate: Bool { false }

    /// Continuation for the in-flight `load(URLRequest:)`. Resolved by
    /// `didFinish` (success) / `didFail` (error) / `didFailProvisional`
    /// (error). Latest-wins on overlapping updates.
    private var pendingLoad: CheckedContinuation<RenderResult, Error>?

    /// Host of the currently-committed URL, lowercased. Used to gate
    /// in-place vs external navigation. `nil` until first commit (or
    /// after an agent-driven `update(payload:)`); while nil, all
    /// navigation is permitted in-place since it's the agent's load.
    private var anchoredHost: String?

    override func update(payload: PanelPayload) async throws -> RenderResult {
        guard payload.form == "url" else {
            throw RenderFailure(
                message: "show_url only accepts `form: url`",
                line: nil
            )
        }
        guard let url = URL(string: payload.body),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw RenderFailure(
                message: "show_url: invalid URL '\(payload.body)'",
                line: nil
            )
        }
        // Cancel any in-flight load — the agent gave us new content.
        if let prev = pendingLoad {
            pendingLoad = nil
            prev.resume(throwing: CancellationError())
        }
        // Width hint: size the WebView's CSS viewport BEFORE
        // load(_:) so responsive pages lay out at the agent's
        // intended width rather than the default 400pt. Same
        // pattern as HTMLRenderer.
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
        // Reset the host anchor — this load is agent-initiated, so
        // it shouldn't be subject to the same-origin gate. The
        // anchor re-establishes on the next `didCommit`.
        anchoredHost = nil
        return try await withCheckedThrowingContinuation { cont in
            self.pendingLoad = cont
            self.webView.load(URLRequest(url: url))
        }
    }

    // MARK: - WKNavigationDelegate hooks

    /// First byte committed — anchor the host for subsequent
    /// same-origin gating.
    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            self.anchoredHost = webView.url?.host?.lowercased()
        }
    }

    /// Load finished. Measure the document size for `RenderResult`
    /// and resolve the pending continuation.
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
                    size = (0, 0)
                }
                if let cont = self.pendingLoad {
                    self.pendingLoad = nil
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
                    message: "url load failed: \(error.localizedDescription)",
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
                    message: "url load failed (provisional): \(error.localizedDescription)",
                    line: nil
                ))
            }
        }
    }

    /// Override the base's "first nav allow, everything else
    /// external" policy with a same-origin carve-out: a link click
    /// to the same host navigates in-place; cross-host clicks (and
    /// `target=_blank`) route through `NSWorkspace`.
    override nonisolated func webView(_ webView: WKWebView,
                                      decidePolicyFor navigationAction: WKNavigationAction,
                                      decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            // No anchor yet → this is the agent-driven load (either
            // the very first one for this panel, or a fresh
            // `update(payload:)` that reset the anchor). Allow.
            guard let anchor = self.anchoredHost else {
                decisionHandler(.allow)
                return
            }
            // `target=_blank` (no target frame) → always external.
            if navigationAction.targetFrame == nil {
                if let url = navigationAction.request.url {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            // Same-host navigation → allow in-place.
            if let host = navigationAction.request.url?.host?.lowercased(),
               host == anchor {
                decisionHandler(.allow)
                return
            }
            // Cross-host → external.
            if let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}
