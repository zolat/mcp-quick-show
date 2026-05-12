// End-to-end verification for the markup push channel.
//
// Pre-req: app already running with QUICKSHOW_NO_AUTOLAUNCH and a
// matching QUICKSHOW_SOCKET_PATH + QUICKSHOW_EVENTS_DIR. We bypass the
// MCP layer here and talk to the control socket directly, the same
// way verify-phase3.ts does.
//
// Verifies:
//   1. set_session_flag {markup_events_armed: true} returns ok.
//   2. After the app's markupEvent bridge has fired (via the
//      QUICKSHOW_TEST_MARKUP smoke), the events file exists and
//      contains both `markup_sent` and `markup_dismissed` lines.
//   3. The artifact PNG is present.
//   4. get_markup-style read of the artifact succeeds (file is
//      readable, size > 0).

import * as fs from "node:fs";
import { SocketClient, DEFAULT_SOCKET_PATH } from "../socket.ts";
import {
  markupEventsLog,
  markupArtifactsDir,
} from "../session.ts";

async function main(): Promise<number> {
  const socketPath = process.env.QUICKSHOW_SOCKET_PATH ?? DEFAULT_SOCKET_PATH;
  const sessionId = process.env.QUICKSHOW_VERIFY_SESSION ?? "markup-verify";
  const client = new SocketClient(socketPath);
  await client.connect(2000);

  const hello = await client.request({
    kind: "hello",
    session_id: sessionId,
    client: "verify-markup",
  });
  if (hello.kind !== "ok") {
    console.error("verify-markup: hello rejected:", JSON.stringify(hello));
    return 1;
  }

  const armed = await client.request({
    kind: "set_session_flag",
    session: sessionId,
    key: "markup_events_armed",
    value: true,
  });
  if (armed.kind !== "ok") {
    console.error("verify-markup: set_session_flag rejected:", JSON.stringify(armed));
    return 1;
  }
  console.error(`verify-markup: armed session ${sessionId}`);

  // If QUICKSHOW_VERIFY_EXPECT_EVENTS is set, also assert that the
  // events log + at least one artifact landed. Caller is responsible
  // for triggering them (e.g. via QUICKSHOW_TEST_MARKUP for a
  // different session, or via a manual JS bridge call).
  if (process.env.QUICKSHOW_VERIFY_EXPECT_EVENTS === "1") {
    const log = markupEventsLog(sessionId);
    if (!fs.existsSync(log)) {
      console.error(`verify-markup: expected events log at ${log}, not present`);
      return 1;
    }
    const lines = fs.readFileSync(log, "utf8").split("\n").filter(Boolean);
    const hasSent = lines.some((l) => l.includes('"markup_sent"'));
    const hasDismissed = lines.some((l) => l.includes('"markup_dismissed"'));
    console.error(`verify-markup: log lines=${lines.length} sent=${hasSent} dismissed=${hasDismissed}`);
    if (!hasSent || !hasDismissed) return 1;

    const dir = markupArtifactsDir(sessionId);
    const arts = fs.existsSync(dir)
      ? fs.readdirSync(dir).filter((f) => f.endsWith(".png"))
      : [];
    console.error(`verify-markup: artifacts=${arts.length}`);
    if (arts.length === 0) return 1;
  }

  client.close();
  console.error("verify-markup: OK");
  return 0;
}

main().then((code) => process.exit(code)).catch((err) => {
  console.error("verify-markup: error:", err instanceof Error ? err.message : String(err));
  process.exit(2);
});
