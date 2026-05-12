// Image content handler.
//
// Tool: `show_image`
// Args:
//   - name: string
//   - path: string                       — filesystem path
//   - return_screenshot?: boolean = true
//
// Path-only in v0.1 (no inline base64). Per the PRD, the response
// returns the *image itself*, not a screenshot of the rendered panel.
// Size cap: 1 GB on disk; downscaling beyond 32k² pixels happens
// app-side.

import { registerHandler, type ContentTypeHandler, type ValidationResult } from "./registry.ts";
import { resolvePath } from "../pathResolver.ts";

const PATH_MAX_BYTES = 1024 * 1024 * 1024; // 1 GB

const handler: ContentTypeHandler = {
  toolName: "show_image",
  description:
    "Display an existing image file (PNG, JPEG, GIF, WebP) in a floating HUD panel on " +
    "the user's screen. Path can be absolute, relative to cwd, or use `~`. The response " +
    "includes the image bytes (not a screenshot of the panel). Same `name` updates the " +
    "existing panel in place.",
  inputSchema: {
    type: "object",
    properties: {
      name: {
        type: "string",
        description: "Stable slot name. Same name updates in place.",
      },
      path: {
        type: "string",
        description:
          "Filesystem path to an image file (PNG/JPEG/GIF/WebP). Supports ~ and relative paths.",
      },
      return_screenshot: {
        type: "boolean",
        description:
          "If true (default), include the image bytes in the response. Set to false to save tokens when the agent doesn't need to inspect.",
        default: true,
      },
    },
    required: ["name", "path"],
  },

  async validate(args: Record<string, unknown>): Promise<ValidationResult> {
    const name = args.name;
    if (typeof name !== "string" || !name.trim()) {
      return { ok: false, error: "`name` must be a non-empty string" };
    }
    const pathArg = args.path;
    if (typeof pathArg !== "string" || !pathArg.trim()) {
      return { ok: false, error: "`path` must be a non-empty string" };
    }
    try {
      const resolved = await resolvePath(pathArg, {
        maxBytes: PATH_MAX_BYTES,
        allowedMimes: ["image/png", "image/jpeg", "image/gif", "image/webp"],
      });
      return {
        ok: true,
        payload: {
          contentType: "image",
          name,
          form: "path",
          body: resolved.absolutePath,
          returnScreenshot: args.return_screenshot !== false,
        },
      };
    } catch (err) {
      return {
        ok: false,
        error: err instanceof Error ? err.message : String(err),
      };
    }
  },
};

registerHandler(handler);
