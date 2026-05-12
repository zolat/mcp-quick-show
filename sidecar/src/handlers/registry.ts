// Content-type handler registry. Each handler:
//   - declares the MCP tool name + description + JSON-schema for args,
//   - validates incoming args into a normalized PanelPayload,
//   - returns the wire envelope the sidecar forwards to the app.
//
// Adding a new content type = one file in `handlers/` + one
// `register()` call below. The MCP server bootstrap iterates the
// registry to build its tool list, so no `index.ts` change is needed.

import type { Tool } from "@modelcontextprotocol/sdk/types.js";

/** Normalized payload bound for the control socket. */
export type NormalizedUpsert = {
  contentType: "markdown" | "svg" | "image" | "mermaid";
  name: string;
  form: "inline" | "path";
  body: string;
  returnScreenshot: boolean;
};

/** Validation result a handler returns from `validate()`. */
export type ValidationOk = { ok: true; payload: NormalizedUpsert };
export type ValidationErr = { ok: false; error: string };
export type ValidationResult = ValidationOk | ValidationErr;

export interface ContentTypeHandler {
  /** MCP tool name (e.g. `show_markdown`). */
  toolName: string;
  /** Description shown to the LLM. */
  description: string;
  /** JSON schema for the tool's args. */
  inputSchema: Tool["inputSchema"];
  /** Validate + normalize the call args. */
  validate(args: Record<string, unknown>): Promise<ValidationResult>;
}

const handlers: ContentTypeHandler[] = [];

/** Register a handler. Idempotent on toolName. */
export function registerHandler(handler: ContentTypeHandler): void {
  const existing = handlers.findIndex((h) => h.toolName === handler.toolName);
  if (existing >= 0) {
    handlers[existing] = handler;
  } else {
    handlers.push(handler);
  }
}

/** All registered handlers (in registration order). */
export function allHandlers(): ContentTypeHandler[] {
  return [...handlers];
}

/** Find by tool name. */
export function findHandler(toolName: string): ContentTypeHandler | undefined {
  return handlers.find((h) => h.toolName === toolName);
}
