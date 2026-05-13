import Cocoa
import WebKit

/// Renders a raster image into a panel by loading an `<img>` shell
/// document into a WKWebView. This is the same WebView pipeline that
/// HTML / Markdown / SVG / Mermaid use — which means the in-DOM
/// markup canvas (`window.__qsMarkup`, injected via WKUserScript)
/// works on images uniformly with everything else. One markup system,
/// one snapshot path, one pan/zoom model.
///
/// The PRD specifies that `show_image` returns the agent the *image
/// bytes themselves* (not a screenshot of the rendered panel) — so
/// `snapshot()` still returns the cached raw bytes. The WebView is
/// only on the path for Send (full-document snapshot with strokes)
/// and for the visible HUD rendering.
@MainActor
final class ImageRenderer: WebViewPanelRenderer {
    override class var typeKey: String { "image" }

    /// Unused — `useTemplate = false` short-circuits the loader — but
    /// the base's `templateName` is non-optional, so we satisfy it.
    override var templateName: String { "__no_template__" }

    override var useTemplate: Bool { false }

    private var lastImageData: Data?
    private var lastImageSize: CGSize = .zero
    private var pendingLoad: CheckedContinuation<RenderResult, Error>?

    override func update(payload: PanelPayload) async throws -> RenderResult {
        guard payload.form == "path" else {
            throw RenderFailure(
                message: "show_image only supports `form: path` in v0.1",
                line: nil
            )
        }
        let url = URL(fileURLWithPath: payload.body)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RenderFailure(
                message: "failed to read image at '\(payload.body)': \(error.localizedDescription)",
                line: nil
            )
        }
        guard let image = NSImage(data: data) else {
            throw RenderFailure(
                message: "couldn't decode image at '\(payload.body)' (corrupt or unsupported format)",
                line: nil
            )
        }
        lastImageData = data
        lastImageSize = image.size

        let mime = Self.mimeType(forExtension: url.pathExtension, data: data)
        let b64 = data.base64EncodedString()

        // Width/height the shell document at the image's natural pixel
        // dimensions. The canvas pinning in `applyCanvasSize` then
        // makes the WebView frame = image size so the markup canvas
        // overlay aligns 1:1 with the image content.
        let w = Int(image.size.width.rounded())
        let h = Int(image.size.height.rounded())
        let html = """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          html, body { margin: 0; padding: 0; background: transparent; }
          img { display: block; width: \(w)px; height: \(h)px; }
        </style>
        </head>
        <body><img src="data:\(mime);base64,\(b64)"></body>
        </html>
        """

        // Cancel any in-flight load (latest-wins on overlapping updates).
        if let prev = pendingLoad {
            pendingLoad = nil
            prev.resume(throwing: CancellationError())
        }

        // Pre-size the WebView to the image's natural dimensions so the
        // canvas overlay measures correctly on first paint.
        let target = NSRect(origin: .zero, size: NSSize(width: w, height: h))
        webView.frame = target
        canvasHost.frame = target
        canvasHost.layoutSubtreeIfNeeded()

        let result: RenderResult = try await withCheckedThrowingContinuation { cont in
            self.pendingLoad = cont
            self.webView.loadHTMLString(html, baseURL: nil)
        }
        applyCanvasSize(NSSize(width: result.width, height: result.height))
        return result
    }

    /// PRD: `show_image` returns the agent's exact bytes back, not a
    /// rendered screenshot. The WebView-snapshot path is reserved for
    /// Send (composite of image + markup strokes via the full-doc
    /// snapshot in `SnapshotService`).
    override func snapshot() async throws -> Data {
        if let data = lastImageData {
            return data
        }
        return try await super.snapshot()
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            guard self.pendingLoad != nil else { return }
            if let cont = self.pendingLoad {
                self.pendingLoad = nil
                cont.resume(returning: RenderResult(
                    width: Double(self.lastImageSize.width),
                    height: Double(self.lastImageSize.height)
                ))
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
                    message: "image shell load failed: \(error.localizedDescription)",
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
                    message: "image shell load failed (provisional): \(error.localizedDescription)",
                    line: nil
                ))
            }
        }
    }

    // MARK: - MIME

    /// Best-effort MIME type for an `<img src="data:...">` payload.
    /// Falls back to `image/png` if neither the extension nor the
    /// magic bytes match anything known — Safari is generous about
    /// what it'll decode.
    private static func mimeType(forExtension ext: String, data: Data) -> String {
        let lower = ext.lowercased()
        switch lower {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        default: break
        }
        if data.count >= 8 {
            let bytes = [UInt8](data.prefix(8))
            if bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
                return "image/png"
            }
            if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
                return "image/jpeg"
            }
            if bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 {
                return "image/gif"
            }
        }
        return "image/png"
    }
}
