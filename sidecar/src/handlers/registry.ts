// Content-type handler registry. Each handler:
//   - declares the MCP tool name + description + JSON-schema for args,
//   - validates incoming args into a normalized PanelPayload,
//   - returns the wire envelope the sidecar forwards to the app.
//
// Adding a new content type = one file in `handlers/` + one
// `register()` call below. The MCP server bootstrap iterates the
// registry to build its tool list, so no `index.ts` change is needed.
//
// Two flavours live here:
//   - `ContentTypeHandler` for upsert-style tools (show_markdown, ...).
//   - `RawToolHandler` for tools that own their own MCP call flow
//     (enable_markup_events, get_markup). These get a `SocketClient`
//     and `sessionId` and return a `CallToolResult` directly.

import type { CallToolResult, Tool } from "@modelcontextprotocol/sdk/types.js";
import type { SocketClient } from "../socket.ts";

/** Normalized payload bound for the control socket. */
export type NormalizedUpsert = {
  contentType: "markdown" | "svg" | "image" | "mermaid" | "html" | "url";
  name: string;
  form: "inline" | "path" | "url";
  body: string;
  returnScreenshot: boolean;
  /** Optional canvas-width hint in points (HTMLRenderer + URLRenderer). */
  width?: number;
  /** Optional grouping key — HUD identity. See `_groupingFields.ts`. */
  group?: string;
  /** Optional per-tab framing line for the banner. */
  description?: string;
  /** Optional HUD-level framing line for the banner. */
  hudDescription?: string;
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

// ---------------------------------------------------------------------
// Raw tool handlers (non-upsert)
// ---------------------------------------------------------------------

export type RawToolContext = {
  client: SocketClient;
  sessionId: string;
};

export interface RawToolHandler {
  /** MCP tool name (e.g. `enable_markup_events`). */
  toolName: string;
  /** Description shown to the LLM. */
  description: string;
  /** JSON schema for the tool's args. */
  inputSchema: Tool["inputSchema"];
  /** Handle the call directly. Owns the full MCP CallToolResult shape. */
  call(args: Record<string, unknown>, ctx: RawToolContext): Promise<CallToolResult>;
}

const rawHandlers: RawToolHandler[] = [];

export function registerRawHandler(handler: RawToolHandler): void {
  const existing = rawHandlers.findIndex((h) => h.toolName === handler.toolName);
  if (existing >= 0) {
    rawHandlers[existing] = handler;
  } else {
    rawHandlers.push(handler);
  }
}

export function allRawHandlers(): RawToolHandler[] {
  return [...rawHandlers];
}

export function findRawHandler(toolName: string): RawToolHandler | undefined {
  return rawHandlers.find((h) => h.toolName === toolName);
}
