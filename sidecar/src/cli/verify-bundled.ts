// Phase 6 verification: spawn the bundled MCP server binary, send the
// MCP initialize / tools/list / tools/call sequence over stdio, and
// verify the bundled stack works end-to-end (sidecar autolaunches the
// .app, renders markdown, returns the screenshot).
//
// This is the closest a test can get to "Claude Code talking to the
// installed app." Run after `xcodebuild ... -configuration Release`.
//
// Usage:
//   QUICKSHOW_APP_PATH=<Release/QuickShow.app> bun run sidecar/src/cli/verify-bundled.ts <bundled-binary>

import { spawn } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) {
    console.error(`FAIL: ${msg}`);
    process.exit(1);
  }
  console.error(`✓ ${msg}`);
}

const bundledBinary = process.argv[2];
if (!bundledBinary) {
  console.error("usage: verify-bundled.ts <path-to-bundled-mcp-quick-show>");
  process.exit(2);
}

type RpcMsg = { jsonrpc: "2.0"; id?: number; method?: string; params?: unknown; result?: unknown; error?: unknown };

async function main() {
  const proc = spawn(bundledBinary, [], {
    stdio: ["pipe", "pipe", "pipe"],
    env: { ...process.env },
  });

  let stderr = "";
  proc.stderr.on("data", (d: Buffer) => {
    stderr += d.toString();
    process.stderr.write(`[sidecar stderr] ${d}`);
  });

  let stdoutBuffer = "";
  const pendingResponses: ((m: RpcMsg) => void)[] = [];
  proc.stdout.on("data", (d: Buffer) => {
    stdoutBuffer += d.toString();
    let nl;
    while ((nl = stdoutBuffer.indexOf("\n")) >= 0) {
      const line = stdoutBuffer.slice(0, nl).trim();
      stdoutBuffer = stdoutBuffer.slice(nl + 1);
      if (!line) continue;
      let parsed: RpcMsg;
      try { parsed = JSON.parse(line); } catch { continue; }
      const waiter = pendingResponses.shift();
      if (waiter) waiter(parsed);
    }
  });

  function send(msg: RpcMsg): Promise<RpcMsg> {
    proc.stdin.write(JSON.stringify(msg) + "\n");
    return new Promise(resolve => pendingResponses.push(resolve));
  }

  // Give the sidecar a moment to autolaunch the app + handshake.
  // The stderr will print "connected" when ready.
  for (let i = 0; i < 30; i++) {
    if (stderr.includes("[mcp-quick-show] connected")) break;
    await delay(200);
  }
  assert(stderr.includes("[mcp-quick-show] connected"), "sidecar handshaked with the app");

  // MCP initialize
  const init = await send({
    jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "verify", version: "0.1" } },
  });
  assert(init.error == null, `initialize succeeded (error: ${JSON.stringify(init.error)})`);

  // notifications/initialized
  proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");

  // tools/list
  const tools = await send({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
  const toolList = (tools.result as { tools: Array<{ name: string }> }).tools;
  const toolNames = toolList.map(t => t.name).sort();
  console.error("tools:", toolNames);
  assert(toolNames.length === 4, `4 tools registered (got ${toolNames.length})`);
  assert(
    toolNames.includes("show_markdown") &&
    toolNames.includes("show_svg") &&
    toolNames.includes("show_mermaid") &&
    toolNames.includes("show_image"),
    "all four content-type tools present"
  );

  // tools/call show_markdown
  const call = await send({
    jsonrpc: "2.0", id: 3, method: "tools/call",
    params: {
      name: "show_markdown",
      arguments: { name: "bundled-test", content: "# Bundled\n\nIt **works** end-to-end." },
    },
  });
  const callResult = call.result as { content: Array<{ type: string; data?: string }>; isError?: boolean };
  assert(!callResult.isError, `show_markdown tool call succeeded`);
  const image = callResult.content.find(c => c.type === "image");
  assert(image && typeof image.data === "string" && image.data.length > 0, `MCP response includes the PNG`);

  proc.kill("SIGTERM");
  await delay(300);
  console.error("\n✅ Phase 6 (bundled) verification passed.");
}

main().catch((err) => {
  console.error(`FAIL: ${err instanceof Error ? err.message : String(err)}`);
  console.error(err);
  process.exit(1);
});
