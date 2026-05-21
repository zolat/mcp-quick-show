// MCP server bootstrap. Phase 1: registers content-type tools from
// the handler registry, routes each call into a control-socket upsert,
// and returns the rendered screenshot (PNG) as an MCP image content
// block alongside the textual confirmation.

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
  type CallToolResult,
} from "@modelcontextprotocol/sdk/types.js";
import { SocketClient, DEFAULT_SOCKET_PATH } from "./socket.ts";
import { resolveSessionId } from "./session.ts";
import { helloHandshake } from "./handshake.ts";
import { withReconnect } from "./reconnect.ts";
import { locateAppBundle, launchAndWaitFor } from "./autolaunch.ts";
import {
  allHandlers,
  findHandler,
  allRawHandlers,
  findRawHandler,
} from "./handlers/registry.ts";

// Side-effect import: each handler module calls `registerHandler()`
// (upsert-style) or `registerRawHandler()` (own-call) on load. Adding a
// new tool is a single import line here.
import "./handlers/markdown.ts";
import "./handlers/svg.ts";
import "./handlers/mermaid.ts";
import "./handlers/image.ts";
import "./handlers/html.ts";
import "./handlers/url.ts";
import "./handlers/enableMarkupEvents.ts";
import "./handlers/getMarkup.ts";
import "./handlers/getShare.ts";
import "./handlers/enablePanelEvents.ts";

async function ensureConnected(client: SocketClient): Promise<void> {
  try {
    await client.connect(500);
    return;
  } catch {
    // Fall through to autolaunch.
  }

  if (process.env.QUICKSHOW_NO_AUTOLAUNCH === "1") {
    throw new Error("control socket unreachable and QUICKSHOW_NO_AUTOLAUNCH=1 — start QuickShow manually");
  }

  const appPath = locateAppBundle();
  if (!appPath) {
    throw new Error(
      "QuickShow.app not found. Install it to /Applications, or set QUICKSHOW_APP_PATH to the bundle path.",
    );
  }
  await launchAndWaitFor(
    appPath,
    async () => {
      try {
        await client.connect(500);
        return true;
      } catch {
        return false;
      }
    },
    { timeoutMs: 5000, pollMs: 150 },
  );
}

function asString(v: unknown): string | undefined {
  return typeof v === "string" ? v : undefined;
}

async function main() {
  const socketPath = process.env.QUICKSHOW_SOCKET_PATH ?? DEFAULT_SOCKET_PATH;
  const client = new SocketClient(socketPath);
  // Resolve the CLAIM. Primary path: the Claude conversation UUID,
  // discovered from `~/.claude/projects/.../<uuid>.jsonl`. That id is
  // distinct across parallel Claudes and stable across sidecar
  // respawn / `claude --resume`, which is exactly what the app's
  // session model wants. Falls back to env override or persisted cwd
  // UUID — see `resolveSessionId` for the precedence chain.
  const { id: candidateId, source } = await resolveSessionId();
  console.error(`[mcp-quick-show] session id source: ${source} (claim=${candidateId})`);

  const clientName = process.env.MCP_CLIENT_ID ?? "claude-code";

  await ensureConnected(client);

  // Handshake — send the resolved id as the CLAIM. The app's
  // allocator still does a live-FD contest check as belt-and-braces
  // (with conversation-UUID claims this should never fire) and
  // returns the granted id we adopt for everything downstream.
  //
  // `sessionRef` keeps the granted id mutable so `withReconnect()` can
  // refresh it after an app-restart-driven re-handshake. Handlers read
  // `sessionRef.id` at call time via the per-request ctx.
  const sessionRef: { id: string } = { id: "" };
  sessionRef.id = await helloHandshake(client, candidateId, clientName);
  if (sessionRef.id === candidateId) {
    console.error(`[mcp-quick-show] connected (session=${sessionRef.id})`);
  } else {
    console.error(
      `[mcp-quick-show] connected (session=${sessionRef.id}, claim=${candidateId} contested)`,
    );
  }

  /// Reconnect + re-handshake closure passed into `withReconnect()`.
  /// Pulled out so the message logging stays here rather than inside
  /// the (otherwise pure) helper.
  const reconnect = async (): Promise<void> => {
    console.error(
      "[mcp-quick-show] socket disconnected — reconnecting + re-handshaking",
    );
    await ensureConnected(client);
    sessionRef.id = await helloHandshake(client, candidateId, clientName);
    console.error(`[mcp-quick-show] reconnected (session=${sessionRef.id})`);
  };

  const server = new Server(
    { name: "mcp-quick-show", version: "0.1.0" },
    { capabilities: { tools: {} } },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => {
    const upsertTools = allHandlers().map((h) => ({
      name: h.toolName,
      description: h.description,
      inputSchema: h.inputSchema,
    }));
    const rawTools = allRawHandlers().map((h) => ({
      name: h.toolName,
      description: h.description,
      inputSchema: h.inputSchema,
    }));
    return { tools: [...upsertTools, ...rawTools] };
  });

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const args = (request.params.arguments ?? {}) as Record<string, unknown>;

    // Raw handlers own their full call flow (own MCP CallToolResult).
    const rawHandler = findRawHandler(request.params.name);
    if (rawHandler) {
      return withReconnect(
        () => rawHandler.call(args, { client, sessionId: sessionRef.id }),
        reconnect,
      );
    }

    const handler = findHandler(request.params.name);
    if (!handler) {
      return {
        content: [{ type: "text", text: `unknown tool: ${request.params.name}` }],
        isError: true,
      } as CallToolResult;
    }
    const validation = await handler.validate(args);
    if (!validation.ok) {
      return {
        content: [{ type: "text", text: `invalid arguments: ${validation.error}` }],
        isError: true,
      } as CallToolResult;
    }
    const payload = validation.payload;
    const resp = await withReconnect(
      () =>
        client.request({
          kind: "upsert",
          session: sessionRef.id,
          name: payload.name,
          content_type: payload.contentType,
          form: payload.form,
          body: payload.body,
          ...(payload.width !== undefined ? { width: payload.width } : {}),
          ...(payload.group !== undefined ? { group: payload.group } : {}),
          ...(payload.description !== undefined ? { description: payload.description } : {}),
          ...(payload.hudDescription !== undefined ? { hud_description: payload.hudDescription } : {}),
        }),
      reconnect,
    );

    if (resp.kind === "ok") {
      const result = resp.result as { width: number; height: number; screenshot_b64?: string };
      const content: CallToolResult["content"] = [
        {
          type: "text",
          text: `Rendered '${payload.name}' (${payload.contentType}) — ${result.width}×${result.height}.`,
        },
      ];
      if (payload.returnScreenshot && result.screenshot_b64) {
        content.push({
          type: "image",
          data: result.screenshot_b64,
          mimeType: "image/png",
        });
      }
      return { content };
    }

    if (resp.kind === "render_error") {
      const content: CallToolResult["content"] = [
        {
          type: "text",
          text: `render error: ${resp.error}${typeof resp.line === "number" ? ` (line ${resp.line})` : ""}`,
        },
      ];
      if (payload.returnScreenshot && resp.screenshot_b64) {
        content.push({
          type: "image",
          data: resp.screenshot_b64,
          mimeType: "image/png",
        });
      }
      return { content, isError: true };
    }

    // protocol_error or anything else.
    return {
      content: [{
        type: "text",
        text: `protocol error: ${"error" in resp ? resp.error : resp.kind}`,
      }],
      isError: true,
    } as CallToolResult;
  });

  const transport = new StdioServerTransport();
  await server.connect(transport);

  const shutdown = () => {
    client.close();
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((err) => {
  console.error(`[mcp-quick-show] fatal: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});

// Silence unused-import warnings for asString — kept for future
// handlers that need to coerce optional string fields.
void asString;
