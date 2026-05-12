/// SVG renderer. Inline-form only in v0.1.
///
/// Inlines the SVG markup into the DOM via DOMPurify with the SVG
/// profile (drops `<script>`, evil event handlers, foreignObject,
/// remote refs, etc.). The PRD's `connect-src 'none'` CSP backstop
/// blocks any remaining exfil attempt.
@MainActor
final class SVGRenderer: WebViewPanelRenderer {
    override class var typeKey: String { "svg" }
    override var templateName: String { "svg" }
}
