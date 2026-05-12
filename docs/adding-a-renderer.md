# Adding a new renderer

QuickShow's renderer abstraction is designed so that adding a new
content type costs **one file in the sidecar**, **one file in the
app** (plus an HTML template if you're using the WebView base), and
**two registration lines**.

This doc walks through a concrete example: adding a hypothetical
`show_dot` tool that renders Graphviz DOT diagrams via [Viz.js].

## The three files

### 1. Sidecar handler — `sidecar/src/handlers/dot.ts`

```ts
import { registerHandler, type ContentTypeHandler, type ValidationResult } from "./registry.ts";

const INLINE_MAX_BYTES = 1 * 1024 * 1024; // 1 MB

const handler: ContentTypeHandler = {
  toolName: "show_dot",
  description:
    "Render a Graphviz DOT diagram in a floating HUD panel. Returns a " +
    "PNG screenshot. Same `name` updates the existing panel in place.",
  inputSchema: {
    type: "object",
    properties: {
      name: { type: "string", description: "Stable slot name." },
      definition: {
        type: "string",
        description: "DOT source, e.g. 'digraph { A -> B; B -> C; }'",
      },
      return_screenshot: {
        type: "boolean",
        description: "If true (default), include a PNG snapshot.",
        default: true,
      },
    },
    required: ["name", "definition"],
  },

  async validate(args: Record<string, unknown>): Promise<ValidationResult> {
    const name = args.name;
    if (typeof name !== "string" || !name.trim()) {
      return { ok: false, error: "`name` must be a non-empty string" };
    }
    const definition = args.definition;
    if (typeof definition !== "string" || !definition.trim()) {
      return { ok: false, error: "`definition` must be a non-empty string" };
    }
    const bytes = Buffer.byteLength(definition, "utf8");
    if (bytes > INLINE_MAX_BYTES) {
      return { ok: false, error: `DOT spec too large: ${bytes} > 1 MB cap` };
    }
    return {
      ok: true,
      payload: {
        contentType: "dot",
        name,
        form: "inline",
        body: definition,
        returnScreenshot: args.return_screenshot !== false,
      },
    };
  },
};

registerHandler(handler);
```

A sidecar handler always:
- Declares a `toolName` (becomes the MCP tool's identifier).
- Carries a `description` written **for the LLM**, not the user — be
  specific about when to use this tool and what it returns.
- Defines a JSON-schema `inputSchema`.
- Implements `validate()`: returns `{ ok: false, error: "..." }` on
  invalid args, or `{ ok: true, payload: NormalizedUpsert }` with a
  `contentType` matching the app-side renderer's `typeKey`.

For path-form arguments, use `pathResolver.resolvePath()` to get
filesystem chokepoint behavior (tilde expansion, MIME sniffing, size
caps) for free.

### 2. App renderer — `QuickShow/Sources/Renderers/DotRenderer.swift`

```swift
/// Graphviz DOT renderer. Inline-form only.
@MainActor
final class DotRenderer: WebViewPanelRenderer {
    override class var typeKey: String { "dot" }
    override var templateName: String { "dot" }
}
```

Yes — that's literally it for a WebView-based renderer. The
`WebViewPanelRenderer` base class handles:

- `WKWebView` lifecycle (creation, navigation, teardown).
- CSP injection + `connect-src 'none'` exfiltration block.
- Bundled-library inlining (template placeholders like
  `<!--QS_VIZ-->` get replaced with `<script>...</script>`).
- The single `renderComplete` JS bridge handler.
- Snapshotting via `WKWebView.takeSnapshot(with:)`.
- 5-second async timeout on each update.
- External link routing through `NSWorkspace`.

If your renderer needs to transform the body before it lands in JS
(say, read from disk when `form == "path"`), override `prepareBody`:

```swift
override func prepareBody(_ body: String, form: String) throws -> String {
    if form == "path" {
        return try String(contentsOfFile: body, encoding: .utf8)
    }
    return body
}
```

**If you need a non-WebView renderer** (e.g. raster images via
`NSImageView`), conform directly to `PanelRenderer` and implement
`makeView()`, `update(payload:)`, `snapshot()` — see
`ImageRenderer.swift` for the canonical example.

### 3. HTML template — `QuickShow/Resources/templates/dot.html`

Skip this file if your renderer doesn't use the WebView base. The
template should:

1. Declare a strict CSP at the top.
2. Mark the spots where bundled libs should be inlined with
   `<!--QS_*-->` placeholder comments.
3. Implement `window.__quickshow_render(body)` that calls
   `window.webkit.messageHandlers.renderComplete.postMessage(...)`
   with `{ ok, width, height }` or `{ ok: false, error, line, width, height }`.
4. Fire `{ ready: true, width: 0, height: 0 }` on `DOMContentLoaded`.

```html
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'self' 'unsafe-inline'; connect-src 'none'; img-src 'self' file: data:; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'">
<!--QS_THEME-->
<style>body { padding: 16px; box-sizing: border-box; }</style>
</head>
<body>
<div id="qs-content"></div>
<div id="qs-error"></div>
<!--QS_VIZ-->
<script>
(function() {
  // ... mirror the boilerplate from markdown.html / svg.html ...
  window.__quickshow_render = async function(body) {
    try {
      const svg = await viz.renderString(body);
      document.getElementById('qs-content').innerHTML = svg;
      const m = { width: document.documentElement.scrollWidth,
                  height: document.documentElement.scrollHeight };
      window.webkit.messageHandlers.renderComplete.postMessage({
        ok: true, width: m.width, height: m.height
      });
    } catch (err) {
      // ... error UI + post {ok: false, error, line} ...
    }
  };
  document.addEventListener('DOMContentLoaded', () => {
    window.webkit.messageHandlers.renderComplete.postMessage({
      ok: true, ready: true, width: 0, height: 0
    });
  });
})();
</script>
</body>
</html>
```

If you're bundling a new JS library, drop it at
`QuickShow/Resources/libs/viz.min.js` and teach
`WebViewPanelRenderer.loadTemplate` to inline it for any template
that has the corresponding `<!--QS_VIZ-->` marker.

## The two registration lines

### Sidecar — `sidecar/src/index.ts`

```ts
import "./handlers/markdown.ts";
import "./handlers/svg.ts";
import "./handlers/mermaid.ts";
import "./handlers/image.ts";
import "./handlers/dot.ts";    // ← add this line
```

The MCP tool list is built by iterating `allHandlers()`, so nothing
else has to change. `tools/list` and `tools/call` start routing the
new tool immediately.

### App — `QuickShow/Sources/Renderers/RendererRegistry.swift`

```swift
static func makeDefault() -> RendererRegistry {
    let registry = RendererRegistry()
    registry.register(MarkdownRenderer.self) { MarkdownRenderer() }
    registry.register(SVGRenderer.self) { SVGRenderer() }
    registry.register(MermaidRenderer.self) { MermaidRenderer() }
    registry.register(ImageRenderer.self) { ImageRenderer() }
    registry.register(DotRenderer.self) { DotRenderer() }   // ← add this line
    return registry
}
```

The factory closure runs once per panel, so each panel gets its own
fresh renderer instance with its own view.

## Wire-protocol mirror discipline

If your new content type needs **new fields** on the wire envelope
beyond `{name, content_type, form, body}` — say, a per-renderer
option — update **both** of these files in the same commit:

- `QuickShow/Sources/Server/ControlProtocol.swift`
- `sidecar/src/protocol.ts`

This pairing is borrowed from PipAnything's `pipanythingctl` /
Swift `ControlProtocol.swift` discipline. CI doesn't enforce it yet,
but drifting them silently is the bug class this rule prevents.

For most new content types you won't need to touch the protocol —
the existing envelope is content-agnostic.

## Verifying your new renderer

1. **Sidecar unit test** — add a `tests/handlers.test.ts` case that
   exercises `validate()` for valid + invalid args.
2. **End-to-end smoke** — extend a `verify-phaseN.ts` script (or
   write a new one) that drives a real upsert through the socket and
   asserts the response is `ok` with a non-empty PNG.
3. **Visual check** — `bun run sidecar/src/cli/demo.ts` with a panel
   of your new type and eyeball the HUD.

## What this pattern intentionally doesn't support

- **Dynamic plugin loading from disk.** No `~/Library/Application
  Support/QuickShow/plugins/`. Adding a content type requires a
  rebuild. This is the v0.1 contract (see PRD § Out of Scope).
- **Per-renderer JS bridge handlers.** There's exactly one bridge
  name: `renderComplete`. If your renderer needs to post messages to
  Swift, encode them as fields on the existing payload — the
  `{copy: <text>}` side-channel in the markdown renderer is the
  canonical example.
- **Renderer-specific wire verbs.** All renderers go through the
  same `upsert/close/list/inspect` surface. If your renderer needs
  per-instance state mutation beyond an `update()` call, you're
  probably reaching for something that should be its own MCP tool
  rather than a renderer.

[Viz.js]: https://github.com/mdaines/viz-js
