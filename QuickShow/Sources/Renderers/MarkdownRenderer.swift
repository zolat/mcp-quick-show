import Foundation

/// Markdown renderer. Subclasses `WebViewPanelRenderer`:
/// - Uses the bundled `templates/markdown.html` (loads marked.js
///   + DOMPurify).
/// - For `form: "inline"`, the body string is passed through to the
///   JS bridge directly.
/// - For `form: "path"`, the file is read by the sidecar before the
///   payload arrives — we still re-read here if `form == "path"` to
///   keep the path option future-proofed against very-large-file
///   streaming, but in v0.1 the sidecar already inlines the bytes.
@MainActor
final class MarkdownRenderer: WebViewPanelRenderer {
    override class var typeKey: String { "markdown" }
    override var templateName: String { "markdown" }

    override func prepareBody(_ body: String, form: String) throws -> String {
        if form == "path" {
            // Path → read from disk. Sidecar pre-flighted the path
            // (existence, MIME, size cap) so any failure here is a
            // genuine I/O error worth surfacing.
            do {
                return try String(contentsOfFile: body, encoding: .utf8)
            } catch {
                throw RenderFailure(
                    message: "failed to read markdown file at '\(body)': \(error.localizedDescription)",
                    line: nil
                )
            }
        }
        return body
    }
}
