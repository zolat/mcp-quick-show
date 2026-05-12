// SVG content handler.
//
// Tool: `show_svg`
// Args:
//   - name: string
//   - content: string                    — inline SVG markup
//   - return_screenshot?: boolean = true
//
// Inline only in v0.1 (path form is straightforward future work).
// Size cap: 50 MB.

import { registerHandler, type ContentTypeHandler, type ValidationResult } from "./registry.ts";

const INLINE_MAX_BYTES = 50 * 1024 * 1024;

const handler: ContentTypeHandler = {
  toolName: "show_svg",
  description:
    "Render an inline SVG image in a floating HUD panel on the user's screen, and return " +
    "a PNG screenshot of the rendered output. Use this for hand-drawn or generated " +
    "vector visualizations, annotated diagrams, illustrations. The SVG is sanitized " +
    "(scripts, event handlers, foreignObject stripped). Same `name` updates the existing " +
    "panel in place.",
  inputSchema: {
    type: "object",
    properties: {
      name: {
        type: "string",
        description: "Stable, human-readable slot name. Same name updates in place.",
      },
      content: {
        type: "string",
        description: "Inline SVG markup (must contain an <svg> root element). Up to 50 MB.",
      },
      return_screenshot: {
        type: "boolean",
        description: "If true (default), include a PNG snapshot in the response.",
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
    if (typeof content !== "string" || !content.trim()) {
      return { ok: false, error: "`content` must be a non-empty SVG string" };
    }
    const bytes = Buffer.byteLength(content, "utf8");
    if (bytes > INLINE_MAX_BYTES) {
      return { ok: false, error: `SVG too large: ${bytes} bytes > 50 MB cap` };
    }
    // Cheap pre-flight — actual <svg> presence is enforced by the
    // template's DOMPurify pass, but failing early on plainly-wrong
    // input gives a sharper error.
    if (!/<svg[\s>]/i.test(content)) {
      return { ok: false, error: "content does not contain an <svg> element" };
    }
    return {
      ok: true,
      payload: {
        contentType: "svg",
        name,
        form: "inline",
        body: content,
        returnScreenshot: args.return_screenshot !== false,
      },
    };
  },
};

registerHandler(handler);
