// Mermaid content handler.
//
// Tool: `show_mermaid`
// Args:
//   - name: string
//   - definition: string                 — mermaid diagram spec
//   - return_screenshot?: boolean = true
//
// Size cap: 1 MB (mermaid specs that big aren't usable anyway).

import { registerHandler, type ContentTypeHandler, type ValidationResult } from "./registry.ts";

const INLINE_MAX_BYTES = 1 * 1024 * 1024;

const handler: ContentTypeHandler = {
  toolName: "show_mermaid",
  description:
    "Render a Mermaid diagram (flowchart, sequence, class, state, ER, gantt, …) in a " +
    "floating HUD panel on the user's screen, and return a PNG screenshot. Pass the " +
    "definition string starting with the diagram type (e.g. 'graph LR; A-->B'). On a " +
    "syntax error the response is a render_error with the parser's line number so you " +
    "can fix and retry. Same `name` updates the existing panel in place.",
  inputSchema: {
    type: "object",
    properties: {
      name: {
        type: "string",
        description: "Stable slot name. Same name updates in place.",
      },
      definition: {
        type: "string",
        description: "Mermaid diagram source. Starts with the diagram type, e.g. 'flowchart LR\\nA-->B'.",
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
      return { ok: false, error: `mermaid spec too large: ${bytes} bytes > 1 MB cap` };
    }
    return {
      ok: true,
      payload: {
        contentType: "mermaid",
        name,
        form: "inline",
        body: definition,
        returnScreenshot: args.return_screenshot !== false,
      },
    };
  },
};

registerHandler(handler);
