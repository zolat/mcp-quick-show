// Plugin smoke test: drives the compiled plugin/bin/mcp-quick-show
// binary as an MCP server and verifies the seven expected tools are
// registered. Used by the plugin build pipeline; not a runtime artifact.
//
// Usage:
//   QUICKSHOW_APP_PATH=/path/to/QuickShow.app bun run src/cli/smoke-plugin.ts
//
// Exits non-zero if any expected tool is missing or the handshake fails.

import { spawn } from "node:child_process";
import { resolve } from "node:path";

const BIN = resolve(import.meta.dir, "../../../plugin/bin/mcp-quick-show");
const EXPECTED_TOOLS = [
  "show_markdown",
  "show_svg",
  "show_mermaid",
  "show_image",
  "show_html",
  "enable_markup_events",
  "get_markup",
].sort();

const proc = spawn(BIN, [], {
  stdio: ["pipe", "pipe", "inherit"],
  env: { ...process.env },
});

let buf = "";
const responses: Record<string | number, unknown> = {};
proc.stdout.on("data", (chunk) => {
  buf += chunk.toString("utf8");
  let i: number;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i);
    buf = buf.slice(i + 1);
    if (!line.trim()) continue;
    try {
      const msg = JSON.parse(line);
      if (msg.id !== undefined) responses[msg.id] = msg;
    } catch {
      // ignore non-JSON lines
    }
  }
});

function send(obj: unknown) {
  proc.stdin.write(JSON.stringify(obj) + "\n");
}

async function waitFor(id: string | number, timeoutMs = 10000): Promise<any> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (responses[id]) return responses[id];
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`timeout waiting for response id=${id}`);
}

try {
  send({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "smoke-plugin", version: "0.0.0" },
    },
  });
  const init = await waitFor(1, 15000);
  if (!init || (init as any).error) {
    console.error("FAIL: initialize errored", JSON.stringify(init));
    process.exit(1);
  }

  send({ jsonrpc: "2.0", method: "notifications/initialized", params: {} });

  send({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
  const list = (await waitFor(2)) as { result?: { tools: { name: string }[] } };
  const got = (list.result?.tools ?? []).map((t) => t.name).sort();
  const missing = EXPECTED_TOOLS.filter((t) => !got.includes(t));
  const extra = got.filter((t) => !EXPECTED_TOOLS.includes(t));

  console.log("tools/list returned:", got.join(", "));
  if (missing.length) console.error("MISSING:", missing.join(", "));
  if (extra.length) console.log("(extra tools also present:", extra.join(", "), ")");

  if (missing.length) {
    process.exit(1);
  }

  console.log("OK — plugin binary registers all 7 expected tools");
  process.exit(0);
} finally {
  proc.stdin.end();
  proc.kill();
}
