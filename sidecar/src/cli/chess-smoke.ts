// Chess smoke-test driver. Reads `chess_helper.py` output and sends the SVG
// straight to the QuickShow app via the control socket, so we can play a
// game from Bash without having to embed 30 KB of SVG in an MCP tool-call
// argument every turn.
//
// Usage:
//   bun run sidecar/src/cli/chess-smoke.ts render <FEN> [--last <UCI>]
//
// Uses the same session_id discovery as the real sidecar so the upsert
// lands in the existing HUD panel.

import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { SocketClient, DEFAULT_SOCKET_PATH } from "../socket.ts";
import { getOrCreateSessionId } from "../session.ts";

const HELPER = resolve(import.meta.dir, "../../../plugin/skills/chess/chess_helper.py");

function parseArgs(argv: string[]) {
  const [cmd, ...rest] = argv;
  const opts: Record<string, string> = {};
  const pos: string[] = [];
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a === "--last") opts.lastMove = rest[++i];
    else if (a === "--name") opts.name = rest[++i];
    else pos.push(a);
  }
  return { cmd, pos, opts };
}

async function main() {
  const { cmd, pos, opts } = parseArgs(process.argv.slice(2));
  if (cmd !== "render") {
    console.error("usage: chess-smoke.ts render <FEN> [--last <UCI>] [--name <slot>]");
    process.exit(2);
  }
  const fen = pos[0];
  if (!fen) {
    console.error("missing FEN");
    process.exit(2);
  }
  const name = opts.name ?? "chess-board";

  const args = ["render", fen, "--size", "600"];
  if (opts.lastMove) args.push("--last-move", opts.lastMove);
  const svg = execFileSync(HELPER, args, { encoding: "utf-8" });
  console.error(`[chess-smoke] svg ${svg.length} bytes`);

  const sessionId = getOrCreateSessionId();
  const socketPath = process.env.QUICKSHOW_SOCKET_PATH ?? DEFAULT_SOCKET_PATH;
  const client = new SocketClient(socketPath);
  await client.connect(2000);

  const hello = await client.request({
    kind: "hello",
    session_id: sessionId,
    client: process.env.MCP_CLIENT_ID ?? "claude-code",
  });
  if (hello.kind !== "ok") {
    console.error(`[chess-smoke] hello rejected: ${JSON.stringify(hello)}`);
    process.exit(1);
  }

  const resp = await client.request({
    kind: "upsert",
    session: sessionId,
    name,
    content_type: "svg",
    form: "inline",
    body: svg,
  });
  if (resp.kind !== "ok") {
    console.error(`[chess-smoke] upsert failed: ${JSON.stringify(resp)}`);
    process.exit(1);
  }
  const result = resp.result as { width: number; height: number };
  console.error(`[chess-smoke] rendered ${name} — ${result.width}×${result.height}`);
  client.close();
}

main().catch((err) => {
  console.error(`[chess-smoke] fatal: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
