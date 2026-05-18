// URL content handler.
//
// Tool: `show_url`
// Args:
//   - name: string                       — panel slot identifier
//   - url: string                        — absolute http(s) URL
//   - width?: number                     — viewport hint (100–4096pt)
//   - return_screenshot?: boolean = true
//
// `show_url` loads a live URL in a HUD panel. Sibling of `show_html`,
// but the agent isn't supplying the content — the network is. Useful
// for pointing the user at an online doc or surfacing a running site
// during end-to-end verification.
//
// Security posture: peer-of `show_html`. The agent's URL is accepted at
// face value; the loaded page brings its own origin CSP. The renderer
// keeps `WKWebsiteDataStore.nonPersistent()` (per-panel isolation). The
// nav policy in URLRenderer permits same-origin navigation in-place
// and routes cross-origin links through NSWorkspace.
//
// `javascript:` / `data:` / `file:` URLs are rejected at validation —
// they'd bypass the "show me an online thing" contract.

import { registerHandler, type ContentTypeHandler, type ValidationResult } from "./registry.ts";
import { groupingSchemaProps, parseGroupingFields } from "./_groupingFields.ts";

const handler: ContentTypeHandler = {
  toolName: "show_url",
  description:
    "Load a live URL in a floating HUD panel on the user's screen, and return " +
    "a PNG screenshot of the rendered page. Use this to point the user at an " +
    "online document, spec, or article you want them to read, or to show them " +
    "a running site (local dev server, staging URL) during end-to-end " +
    "verification. Calling again with the same `name` reloads the panel with " +
    "the new URL; a different `name` opens a new tab. Same-origin navigation " +
    "works in-place (the user can click around); cross-origin links open in " +
    "the default browser. Only http(s) URLs are accepted. " +
    "Pair with `enable_markup_events` to let the user circle what's wrong on " +
    "a real page.",
  inputSchema: {
    type: "object",
    properties: {
      name: {
        type: "string",
        description:
          "Stable, human-readable slot name (e.g. 'spec', 'staging'). Same name reloads the existing panel; different name opens a new tab.",
      },
      url: {
        type: "string",
        description:
          "Absolute http(s) URL to load. `file:`, `javascript:`, and `data:` URLs are rejected — use `show_html` for inline content or `show_image` for local files.",
      },
      width: {
        type: "number",
        description:
          "Optional canvas width in points (100–4096). Sizes the WebView's CSS viewport before navigation, so responsive sites render at this width. If omitted, the default ~400pt viewport is used.",
      },
      return_screenshot: {
        type: "boolean",
        description:
          "If true (default), the tool response includes a PNG screenshot of the loaded page. Set to false to save tokens when you don't need to verify.",
        default: true,
      },
      ...groupingSchemaProps,
    },
    required: ["name", "url"],
  },

  async validate(args: Record<string, unknown>): Promise<ValidationResult> {
    const name = args.name;
    if (typeof name !== "string" || !name.trim()) {
      return { ok: false, error: "`name` must be a non-empty string" };
    }
    const url = args.url;
    if (typeof url !== "string" || !url.trim()) {
      return { ok: false, error: "`url` must be a non-empty string" };
    }
    let parsed: URL;
    try {
      parsed = new URL(url);
    } catch {
      return { ok: false, error: `\`url\` is not a valid URL: ${url}` };
    }
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
      return {
        ok: false,
        error: `\`url\` must use http: or https: (got '${parsed.protocol}')`,
      };
    }
    const returnScreenshot = args.return_screenshot !== false;
    let width: number | undefined;
    if (args.width !== undefined) {
      if (typeof args.width !== "number" || !Number.isFinite(args.width)
          || args.width < 100 || args.width > 4096) {
        return {
          ok: false,
          error: "`width` must be a finite number between 100 and 4096 points",
        };
      }
      width = Math.round(args.width);
    }
    const grouping = parseGroupingFields(args);
    if (!grouping.ok) return { ok: false, error: grouping.error };
    return {
      ok: true,
      payload: {
        contentType: "url",
        name,
        form: "url",
        body: parsed.toString(),
        returnScreenshot,
        width,
        ...grouping.fields,
      },
    };
  },
};

registerHandler(handler);
