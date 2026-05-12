// HTML content handler.
//
// Tool: `show_html`
// Args:
//   - name: string                       — panel slot identifier
//   - content: string                    — complete, self-contained HTML
//   - return_screenshot?: boolean = true
//
// `show_html` exists for the design-demo skill: render arbitrary HTML
// in a floating HUD panel and (optionally) pair with the markup-events
// feedback loop so the user can annotate and send back the result.
// Unlike the markdown / svg / mermaid renderers (which all use
// `innerHTML` injection — which the DOM spec defines as silently
// dropping `<script>` tags), the `show_html` path loads the agent's
// HTML via `WKWebView.loadHTMLString` so embedded scripts execute.
//
// Security posture (v0.1): the agent's HTML is accepted at face value.
// The renderer keeps `WKWebsiteDataStore.nonPersistent()` so each
// panel is isolated, and external link clicks open via NSWorkspace
// instead of navigating in-place. A stricter posture (allowlisted
// CDNs, font-src carve-outs) is deferred to v0.2 — the description
// below steers agents toward self-contained output as the discipline.

import { registerHandler, type ContentTypeHandler, type ValidationResult } from "./registry.ts";

const INLINE_MAX_BYTES = 10 * 1024 * 1024;

const handler: ContentTypeHandler = {
  toolName: "show_html",
  description:
    "Render a complete, self-contained HTML document in a floating HUD panel on the user's " +
    "screen, and return a PNG screenshot of the rendered output. Use this for interactive " +
    "design demos, dashboards, and other rich UI that needs CSS + JS. Calling again with " +
    "the same `name` updates the existing panel in place; a different `name` opens a new " +
    "tab. " +
    "REQUIREMENTS: provide a full <html>...</html> document. Inline ALL styles (<style> " +
    "blocks) and scripts (<script> blocks). Do NOT reference external CDNs — network " +
    "requests are restricted by the rendering environment. For custom fonts, embed via " +
    "`@font-face src: url('data:font/woff2;base64,...')`. For images, embed via " +
    "`data:image/png;base64,...` URIs or omit them. Pair with `enable_markup_events` to " +
    "let the user mark up the result and send annotated feedback.",
  inputSchema: {
    type: "object",
    properties: {
      name: {
        type: "string",
        description:
          "Stable, human-readable slot name (e.g. 'design', 'hero-v2'). Same name updates the existing panel; different name opens a new tab.",
      },
      content: {
        type: "string",
        description:
          "Complete, self-contained HTML document (up to 10 MB). Must be a full <html>...</html> with all CSS/JS/fonts/images inlined.",
      },
      return_screenshot: {
        type: "boolean",
        description:
          "If true (default), the tool response includes a PNG screenshot of the rendered panel. Set to false to save tokens when you don't need to verify the output.",
        default: true,
      },
    },
    required: ["name", "content"],
  },

  async validate(args: Record<string, unknown>): Promise<ValidationResult> {
    const name = args.name;
    if (typeof name !== "string" || !name.trim()) {
      return { ok: false, error: "`name` must be a non-empty string" };
    }
    const content = args.content;
    if (typeof content !== "string" || content.length === 0) {
      return { ok: false, error: "`content` must be a non-empty HTML string" };
    }
    const bytes = Buffer.byteLength(content, "utf8");
    if (bytes > INLINE_MAX_BYTES) {
      return {
        ok: false,
        error: `inline content too large: ${bytes} bytes > 10 MB cap`,
      };
    }
    const returnScreenshot = args.return_screenshot !== false;
    return {
      ok: true,
      payload: {
        contentType: "html",
        name,
        form: "inline",
        body: content,
        returnScreenshot,
      },
    };
  },
};

registerHandler(handler);
