/// Mermaid renderer. The bundled mermaid.js is loaded with
/// `securityLevel: 'strict'` — labels can't contain HTML, clickable
/// elements are disabled.
@MainActor
final class MermaidRenderer: WebViewPanelRenderer {
    override class var typeKey: String { "mermaid" }
    override var templateName: String { "mermaid" }
}
