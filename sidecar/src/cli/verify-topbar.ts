// One-off verification driver for the top-bar revamp.
//
// Usage:
//   bun run src/cli/verify-topbar.ts
//
// Connects to the running QuickShow.app socket, does the hello
// handshake (so session_id is granted properly), arms markup events
// so the ✏︎ button appears on the idle bar, then upserts a small
// panel. The user can then visually inspect the new title bar.

import { SocketClient, DEFAULT_SOCKET_PATH } from "../socket.ts";
import { getOrCreateSessionId } from "../session.ts";
import { helloHandshake } from "../handshake.ts";

async function main() {
  const client = new SocketClient(
    process.env.QUICKSHOW_SOCKET_PATH ?? DEFAULT_SOCKET_PATH,
  );
  await client.connect(2000);

  const sessionId = await helloHandshake(
    client,
    getOrCreateSessionId(),
    "verify-topbar",
  );
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
