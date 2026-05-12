import Cocoa

/// Normalized payload handed to a renderer by the control surface.
/// All path resolution / MIME sniffing / size capping is done by the
/// sidecar before the bytes hit Swift — by the time a renderer sees
/// the payload, `body` is the canonical content to render.
///
/// - For inline forms: `body` is the literal content (markdown text,
///   SVG markup, mermaid spec).
/// - For path forms: `body` is the absolute file path (the renderer
///   reads it lazily — keeps large files out of the wire envelope).
struct PanelPayload: Sendable {
    let name: String
    let contentType: String
    let form: String          // "inline" | "path"
    let body: String
}

/// Result of a successful render.
struct RenderResult: Sendable {
    let width: Double
    let height: Double
}

/// Renderer-thrown failure that includes the styled-error snapshot
/// the renderer has *already painted into its view*. The control layer
/// captures a snapshot of the error UI and bundles both pieces into
/// the `render_error` response.
struct RenderFailure: Error, Sendable {
    let message: String
    let line: Int?
}

/// One instance per panel. Each renderer owns its view; the panel
/// retains both. `makeView()` is called once at creation; `update()`
/// drives subsequent re-renders; `snapshot()` captures the current
/// visual state regardless of how it was produced.
@MainActor
protocol PanelRenderer: AnyObject {
    /// The wire `content_type` discriminator this renderer handles.
    /// Used by `RendererRegistry` to look up the right factory.
    static var typeKey: String { get }

    /// Create the renderer's view. Called exactly once when the panel
    /// is first opened. The view is retained by the panel.
    func makeView() -> NSView

    /// Render the payload. Throws `RenderFailure` if the content is
    /// invalid; the view has already painted the styled error UI.
    func update(payload: PanelPayload) async throws -> RenderResult

    /// Capture a PNG snapshot of the renderer's current visual state.
    /// Includes any error UI if the last update failed.
    func snapshot() async throws -> Data

    /// Suspend interactive transforms (pan, zoom, scroll-magnification)
    /// while the user is drawing markup strokes on top. Keeps the
    /// strokes coherent with the content underneath. Default is a
    /// no-op for renderers that have nothing to suspend.
    func suspendInteraction()

    /// Resume interactive transforms after draw mode exits.
    func resumeInteraction()
}

extension PanelRenderer {
    /// Default no-ops — only renderers with pan/zoom override these.
    func suspendInteraction() {}
    func resumeInteraction() {}
}
