// One-off verification driver for the top-bar revamp.
//
// Usage:
//   bun run src/cli/verify-topbar.ts
//
// Connects to the running QuickShow.app socket, does the hello
// handshake, arms markup events so the ✏︎ button appears on the
// idle bar, then upserts a small panel for visual inspection.
//
// Session alignment:
//   Defaults to the per-cwd persisted UUID (via `getOrCreateSessionId`),
//   isolated from any active Claude Code session — correct for headless
//   smoke runs.
//
//   `QUICKSHOW_SESSION_ID` is honoured as a CLAIM. Caveat: the app's
//   allocator detects contests against any live FD already holding the
//   same id (e.g. an active MCP sidecar) and mints a fresh id anyway.
//   So the override is most useful for pinning offline smokes to a
//   stable id, or reattaching to an orphaned session — NOT for
//   sharing events with a Claude whose MCP sidecar is connected.
//
//   For Claude-driven verification, render through that Claude's MCP
//   `show_html` tool instead.

import { SocketClient, DEFAULT_SOCKET_PATH } from "../socket.ts";
import { getOrCreateSessionId } from "../session.ts";
import { helloHandshake } from "../handshake.ts";

async function main() {
  const client = new SocketClient(
    process.env.QUICKSHOW_SOCKET_PATH ?? DEFAULT_SOCKET_PATH,
  );
  await client.connect(2000);

  // Honour the env override so a Claude can pin this script to its
  // own session. Falls back to the per-cwd persisted UUID otherwise.
  const candidate = process.env.QUICKSHOW_SESSION_ID || getOrCreateSessionId();
  const sessionId = await helloHandshake(client, candidate, "verify-topbar");
  console.log(`hello: session_id=${sessionId}`);

  // Arm markup so the idle bar shows ✏︎.
  const armed = await client.request({
    kind: "set_session_flag",
    session: sessionId,
    key: "markup_events_armed",
    value: true,
  });
  console.log(`set_session_flag(markup_events_armed=true): ${armed.kind}`);

  // Render a small panel — content doesn't matter much; we want to
  // see the surrounding title bar.
  const html = `<!doctype html><html><head><style>
    html,body{margin:0;padding:0;background:#1c1c1c;color:#a8a99e;
      font-family:-apple-system,sans-serif;display:flex;
      align-items:center;justify-content:center;height:100vh}
    .box{text-align:center;font-size:13px;line-height:1.6}
    code{background:#2a2620;padding:2px 6px;border-radius:3px;color:#ededed}
  </style></head><body>
    <div class="box">
      <p>Top-bar verification panel</p>
      <p>Look up — that's the new 28pt bar with SF Symbols.</p>
      <p>Click <code>✏︎</code> to enter draw mode and exercise the pickers.</p>
    </div>
  </body></html>`;

  const upsert = await client.request({
    kind: "upsert",
    session: sessionId,
    name: "topbar-verify",
    content_type: "html",
    form: "inline",
    body: html,
    width: 520,
  });
  console.log(`upsert: ${upsert.kind}`);

  client.close();
  process.exit(0);
}

main().catch((err) => {
  console.error("verify-topbar failed:", err);
  process.exit(1);
});
