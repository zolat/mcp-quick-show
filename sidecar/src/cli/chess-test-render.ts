// Render a chess board into the running QuickShow.
//
// Pipes chess_helper.py's `render-html` subcommand output straight to
// `show_html`. Same direct-socket pattern as `ttt-test-render.ts` —
// used to exercise the chess SKILL's panel_event loop during
// interactive testing.
//
// Usage:
//   bun run src/cli/chess-test-render.ts                                # starting position
//   bun run src/cli/chess-test-render.ts --fen "<FEN>"                  # custom position
//   bun run src/cli/chess-test-render.ts --selected e2 --legal e3,e4
//   bun run src/cli/chess-test-render.ts --last-move e2e4

import { spawnSync } from "node:child_process";
import * as path from "node:path";
import * as fs from "node:fs";
import { SocketClient, DEFAULT_SOCKET_PATH } from "../socket.ts";
import { helloHandshake } from "../handshake.ts";

function arg(args: string[], flag: string): string | undefined {
  const i = args.indexOf(flag);
  if (i < 0 || i + 1 >= args.length) return undefined;
  return args[i + 1];
}

function helper(...subArgs: string[]): string {
  const repoRoot = path.resolve(import.meta.dir, "../../..");
  const script = path.join(repoRoot, "plugin/skills/fun/chess_helper.py");
  const r = spawnSync(script, subArgs, { encoding: "utf8" });
  if (r.status !== 0) {
    throw new Error(`chess_helper ${subArgs.join(" ")} failed (${r.status}): ${r.stderr}`);
  }
  return r.stdout;
}

async function main(): Promise<number> {
  const args = process.argv.slice(2);
  const startingFen = JSON.parse(helper("new")).fen;
  const fen = arg(args, "--fen") ?? startingFen;
  const selected = arg(args, "--selected");
  const legal = arg(args, "--legal");
  const lastMove = arg(args, "--last-move");
  const size = arg(args, "--size") ?? "600";

  const helperArgs = ["render-html", fen, "--size", size];
  if (selected) helperArgs.push("--selected", selected);
  if (legal) helperArgs.push("--legal-targets", legal);
  if (lastMove) helperArgs.push("--last-move", lastMove);

  const html = helper(...helperArgs);

  const socketPath = process.env.QUICKSHOW_SOCKET_PATH ?? DEFAULT_SOCKET_PATH;
  const claim = process.env.QUICKSHOW_CHESS_SESSION ?? "chess-live";
  const panel = "chess-board";

  const c = new SocketClient(socketPath);
  await c.connect(2000);

  const session = await helloHandshake(c, claim, "chess-test-render");

  const armed = await c.request({
    kind: "set_session_flag", session, key: "panel_events_armed", value: true,
  });
  if (armed.kind !== "ok") { console.error("arm failed:", armed); return 1; }

  const upsert = await c.request({
    kind: "upsert", session, name: panel,
    content_type: "html", form: "inline", body: html, width: 640,
  });
  if (upsert.kind !== "ok") {
    console.error("upsert failed:", JSON.stringify(upsert));
    return 1;
  }
  const r = upsert.result as { width: number; height: number; screenshot_b64?: string };
  console.error(`chess-test-render: rendered ${r.width}×${r.height}` +
    (selected ? ` selected=${selected}` : "") +
    (legal ? ` legal=${legal}` : "") +
    (lastMove ? ` last-move=${lastMove}` : ""));
  const screenshotOut = arg(args, "--screenshot");
  if (screenshotOut && r.screenshot_b64) {
    fs.writeFileSync(screenshotOut, Buffer.from(r.screenshot_b64, "base64"));
    console.error(`chess-test-render: screenshot → ${screenshotOut}`);
  }

  c.close();
  return 0;
}

main().then((code) => process.exit(code)).catch((err) => {
  console.error("chess-test-render: error:", err instanceof Error ? err.message : String(err));
  process.exit(2);
});
