import Foundation

/// Lookup table from wire `content_type` strings to renderer factories.
/// Phase 1: markdown only. Phase 2 layers in svg/mermaid/image —
/// adding a renderer is a single `register()` line here plus the
/// renderer class itself.
@MainActor
final class RendererRegistry {
    private var factories: [String: () -> any PanelRenderer] = [:]

    /// Register the factory for a given `typeKey`. The factory closure
    /// is invoked each time a new panel is created for that type, so
    /// each panel gets a fresh renderer instance with its own view.
    func register<T: PanelRenderer>(_ rendererType: T.Type, factory: @escaping @MainActor () -> T) {
        factories[T.typeKey] = factory
    }

    /// Look up a factory by content_type and call it. Returns nil if
    /// no renderer is registered (caller surfaces that as a
    /// `protocol_error`).
    func make(forContentType contentType: String) -> (any PanelRenderer)? {
        factories[contentType]?()
    }

    /// Register all v0.1 renderers. Add new ones here as phases land.
    static func makeDefault() -> RendererRegistry {
        let registry = RendererRegistry()
        registry.register(MarkdownRenderer.self) { MarkdownRenderer() }
        registry.register(SVGRenderer.self) { SVGRenderer() }
        registry.register(MermaidRenderer.self) { MermaidRenderer() }
        registry.register(ImageRenderer.self) { ImageRenderer() }
        return registry
    }
}
