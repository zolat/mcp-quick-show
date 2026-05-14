// Throttle verification for the panel_event channel.
//
// Renders a `show_html` panel that fires 200 emits as fast as JS can
// run them (a synchronous for-loop). The token bucket has capacity
// 20, so we expect ~20 panel_event lines admitted and the rest
// dropped, with at least one `panel_event_dropped` summary line
// reporting the discard count.
//
// Usage:
//   QUICKSHOW_SOCKET_PATH=/tmp/qs.sock \
//   QUICKSHOW_EVENTS_DIR=/tmp/qs-events \
//   bun run src/cli/verify-panel-throttle.ts

import * as fs from "node:fs";
import { SocketClient, DEFAULT_SOCKET_PATH } from "../socket.ts";
import { markupEventsLog } from "../session.ts";
import { helloHandshake } from "../handshake.ts";

const BURST_HTML = `<!doctype html><html><body>
<h1>throttle smoke</h1>
<script>
  function burst() {
    if (!window.quickshow || !window.quickshow.emit) return;
    for (let i = 0; i < 200; i++) {
      window.quickshow.emit({ i: i, ts: Date.now() });
    }
  }
  if (document.readyState === "complete") burst();
  else window.addEventListener("load", burst);
</script>
</body></html>`;

async function main(): Promise<number> {
  const socketPath = process.env.QUICKSHOW_SOCKET_PATH ?? DEFAULT_SOCKET_PATH;
  const claim = process.env.QUICKSHOW_VERIFY_SESSION ?? "panel-throttle";
  const panel = "throttle-pe";

  const client = new SocketClient(socketPath);
  await client.connect(2000);

  const sessionId = await helloHandshake(client, claim, "verify-panel-throttle");
  const armed = await client.request({
    kind: "set_session_flag",
    session: sessionId,
    key: "panel_events_armed",
    value: true,
  });
  if (armed.kind !== "ok") {
    console.error("verify-panel-throttle: set_session_flag rejected");
    return 1;
  }

  const upsert = await client.request({
    kind: "upsert",
    session: sessionId,
    name: panel,
    content_type: "html",
    form: "inline",
    body: BURST_HTML,
  });
  if (upsert.kind !== "ok") {
    console.error("verify-panel-throttle: upsert rejected:", JSON.stringify(upsert));
    return 1;
  }

  // Wait long enough for the 1Hz drop reporter to flush at least
  // once (it fires ~1s after the first drop).
  await new Promise((r) => setTimeout(r, 1500));

  const log = markupEventsLog(sessionId);
  if (!fs.existsSync(log)) {
    console.error("verify-panel-throttle: events log missing");
    return 1;
  }
  const lines = fs.readFileSync(log, "utf8").split("\n").filter(Boolean);
  const events = lines.filter((l) => l.includes('"panel_event"') && l.includes(`"${panel}"`));
  const dropSummaries = lines.filter((l) =>
    l.includes('"panel_event_dropped"') && l.includes(`"${panel}"`),
  );

  console.error(`verify-panel-throttle: panel_event=${events.length} panel_event_dropped=${dropSummaries.length}`);

  // Acceptance:
  //   - admitted count is bounded — capacity 20 + ~1.5s of refill at 20/s
  //     means at most ~50 admitted out of 200 emits. (We're permissive
  //     so a slow CI machine doesn't fail.)
  //   - at least one drop summary line was emitted (200 emits in <50ms
  //     guarantees the bucket overflowed).
  const admittedCap = 60;
  if (events.length > admittedCap) {
    console.error(`verify-panel-throttle: throttle did not cap (got ${events.length}, expected <= ${admittedCap})`);
    return 1;
  }
  if (dropSummaries.length === 0) {
    console.error("verify-panel-throttle: expected a panel_event_dropped summary line, got none");
    return 1;
  }
  // Total dropped across summaries should account for what didn't get admitted.
  let totalDropped = 0;
  for (const l of dropSummaries) {
    const m = l.match(/"dropped":(\d+)/);
    if (m) totalDropped += Number(m[1]);
  }
  console.error(`verify-panel-throttle: total dropped across summaries=${totalDropped}`);
  if (events.length + totalDropped < 150) {
    console.error(`verify-panel-throttle: admitted+dropped (${events.length + totalDropped}) far below the 200 emitted — events lost without account`);
    return 1;
  }

  client.close();
  console.error("verify-panel-throttle: OK");
  return 0;
}

main().then((code) => process.exit(code)).catch((err) => {
  console.error("verify-panel-throttle: error:", err instanceof Error ? err.message : String(err));
  process.exit(2);
});
