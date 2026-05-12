// Markdown content handler.
//
// Tool: `show_markdown`
// Args:
//   - name: string                       — panel slot identifier
//   - content?: string                   — inline markdown text
//   - path?: string                      — path to a markdown file
//   - return_screenshot?: boolean = true
//
// Exactly one of `content` xor `path` is required. Inline content
// can be up to 10 MB; path-based files up to 50 MB (per PRD size
// caps).

import * as fs from "node:fs";
import { registerHandler, type ContentTypeHandler, type ValidationResult } from "./registry.ts";
import { resolvePath } from "../pathResolver.ts";

const INLINE_MAX_BYTES = 10 * 1024 * 1024;
const PATH_MAX_BYTES = 50 * 1024 * 1024;

const handler: ContentTypeHandler = {
  toolName: "show_markdown",
  description:
    "Render a markdown string or file in a floating HUD panel on the user's screen, and " +
    "return a PNG screenshot of the rendered output. Use this to surface long-form reports, " +
    "summaries, or rendered docs visually instead of dumping text into the chat. Calling " +
    "again with the same `name` updates the existing panel in place; a different `name` " +
    "opens a new tab. Exactly one of `content` or `path` must be provided.",
  inputSchema: {
    type: "object",
    properties: {
      name: {
        type: "string",
        description:
          "Stable, human-readable slot name (e.g. 'arch', 'plan-v2'). Same name updates the existing panel; different name opens a new one.",
      },
      content: {
        type: "string",
        description: "Inline markdown text (up to 10 MB). Mutually exclusive with `path`.",
      },
      path: {
        type: "string",
        description:
          "Filesystem path to a markdown file (up to 50 MB). Supports ~ and relative paths. Mutually exclusive with `content`.",
      },
      return_screenshot: {
        type: "boolean",
        description:
          "If true (default), the tool response includes a PNG screenshot of the rendered panel. Set to false to save tokens when you don't need to verify the output.",
        default: true,
      },
    },
    required: ["name"],
  },

  async validate(args: Record<string, unknown>): Promise<ValidationResult> {
    const name = args.name;
    if (typeof name !== "string" || !name.trim()) {
      return { ok: false, error: "`name` must be a non-empty string" };
    }
    const content = args.content;
    const pathArg = args.path;
    const returnScreenshot = args.return_screenshot !== false;

    const hasContent = typeof content === "string";
    const hasPath = typeof pathArg === "string";
    if (hasContent === hasPath) {
      return {
        ok: false,
        error: "exactly one of `content` or `path` must be provided",
      };
    }

    if (hasContent) {
      const bytes = Buffer.byteLength(content as string, "utf8");
      if (bytes > INLINE_MAX_BYTES) {
        return {
          ok: false,
          error: `inline content too large: ${bytes} bytes > 10 MB cap`,
        };
      }
      return {
        ok: true,
        payload: {
          contentType: "markdown",
          name,
          form: "inline",
          body: content as string,
          returnScreenshot,
        },
      };
    }

    // Path form. Validate via the path resolver; allow text MIME only.
    try {
      const resolved = await resolvePath(pathArg as string, {
        maxBytes: PATH_MAX_BYTES,
        allowedMimes: ["text/plain"],
      });
      // We read the bytes here rather than passing the path to the
      // app. Phase 1 keeps the renderer simple — the inline path the
      // renderer already supports for `inline` form just gets the
      // bytes. The PRD has `form: "path"` reserved for future
      // streaming work.
      const body = await fs.promises.readFile(resolved.absolutePath, "utf8");
      return {
        ok: true,
        payload: {
          contentType: "markdown",
          name,
          form: "inline",
          body,
          returnScreenshot,
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
