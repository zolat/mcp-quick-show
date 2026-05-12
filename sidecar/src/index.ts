// MCP server bootstrap. Phase 0: connects to the control socket,
// handshakes, registers no tools. The MCP transport stays alive over
// stdio so Claude Code keeps the process around; future phases hang
// real tools off the registry.

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { ListToolsRequestSchema, CallToolRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { SocketClient, DEFAULT_SOCKET_PATH } from "./socket.ts";
import { getOrCreateSessionId } from "./session.ts";
import { locateAppBundle, launchAndWaitFor } from "./autolaunch.ts";

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

async function main() {
  const socketPath = process.env.QUICKSHOW_SOCKET_PATH ?? DEFAULT_SOCKET_PATH;
  const client = new SocketClient(socketPath);
  const sessionId = getOrCreateSessionId();

  await ensureConnected(client);

  // Handshake — identifies this sidecar to the app.
  const helloResp = await client.request({
    kind: "hello",
    session_id: sessionId,
    client: process.env.MCP_CLIENT_ID ?? "claude-code",
  });
  if (helloResp.kind !== "ok") {
    throw new Error(`hello rejected: ${"error" in helloResp ? helloResp.error : helloResp.kind}`);
  }
  console.error(`[mcp-quick-show] connected (session=${sessionId})`);

  // Set up MCP server. Phase 0: no tools registered yet; the server
  // exists so Claude Code's MCP transport stays alive and we can prove
  // the install/wiring works end-to-end.
  const server = new Server(
    { name: "mcp-quick-show", version: "0.1.0" },
    { capabilities: { tools: {} } },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: [] }));

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    return {
      content: [{ type: "text", text: `Tool '${request.params.name}' not yet implemented (Phase 0).` }],
      isError: true,
    };
  });

  const transport = new StdioServerTransport();
  await server.connect(transport);

  // Keep the process alive until stdin closes; MCP transport handles
  // the actual lifecycle. Cleanup on SIGINT/SIGTERM.
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
