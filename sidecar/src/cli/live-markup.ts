// Live-test helper: arm the session + render a markdown panel.
//
// Used in tandem with `Monitor` on the events log to exercise the
// close→dismiss path interactively. Not part of the regular test
// suite — invoked by hand:
//
//   QUICKSHOW_SOCKET_PATH=/tmp/qs-live.sock \
//   QUICKSHOW_EVENTS_DIR=/tmp/qs-live \
//   bun run sidecar/src/cli/live-markup.ts

import { SocketClient, DEFAULT_SOCKET_PATH } from "../socket.ts";
import { markupEventsLog } from "../session.ts";
import { helloHandshake } from "../handshake.ts";

async function main(): Promise<number> {
  const socketPath = process.env.QUICKSHOW_SOCKET_PATH ?? DEFAULT_SOCKET_PATH;
  const claim = process.env.QUICKSHOW_VERIFY_SESSION ?? "live-test";
  const client = new SocketClient(socketPath);
  await client.connect(2000);

  const session = await helloHandshake(client, claim, "live-markup");

  const armed = await client.request({
    kind: "set_session_flag",
    session,
    key: "markup_events_armed",
    value: true,
  });
  if (armed.kind !== "ok") {
    console.error("set_session_flag rejected:", armed);
    return 1;
  }

  const up = await client.request({
    kind: "upsert",
    session,
    name: "close-me",
    content_type: "markdown",
    form: "inline",
    body:
      "# Live markup-close test\n\n" +
      "Markup events are **armed** for this session.\n\n" +
      "Close this panel (tab × button or HUD title-bar ×) and an event will land in the log:\n\n" +
      "    " + markupEventsLog(session),
  });
  if (up.kind !== "ok") {
    console.error("upsert rejected:", up);
    return 1;
  }

  console.error(`session=${session}`);
  console.error(`events_log=${markupEventsLog(session)}`);
  console.error("panel rendered — close it to fire markup_dismissed");
  client.close();
  return 0;
}

main().then((c) => process.exit(c)).catch((err) => {
  console.error("live-markup: error:", err);
  process.exit(2);
});
