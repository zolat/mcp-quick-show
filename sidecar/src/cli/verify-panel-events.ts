// End-to-end verification for the panel_event push channel.
//
// Pre-req: app already running with QUICKSHOW_NO_AUTOLAUNCH and a
// matching QUICKSHOW_SOCKET_PATH + QUICKSHOW_EVENTS_DIR. We bypass the
// MCP layer here and talk to the control socket directly, the same
// way verify-markup.ts does.
//
// Verifies:
//   1. set_session_flag {panel_events_armed: true} returns ok.
//   2. Rendering a show_html panel that calls
//      window.quickshow.emit({...}) on load produces a `panel_event`
//      line in the session's events.ndjson with the panel name and
//      the agent-supplied payload.
//   3. If --gate is passed, also verifies the un-armed path: a
//      different session that has NEVER called set_session_flag for
//      panel_events_armed produces NO panel_event lines even when
//      the same HTML emits.
//
// Usage:
//   QUICKSHOW_SOCKET_PATH=/tmp/qs.sock \
//   QUICKSHOW_EVENTS_DIR=/tmp/qs-events \
//   bun run src/cli/verify-panel-events.ts [--gate]

import * as fs from "node:fs";
import { SocketClient, DEFAULT_SOCKET_PATH } from "../socket.ts";
import { markupEventsLog } from "../session.ts";

const EMIT_HTML = `<!doctype html><html><head><meta charset="utf-8"></head>
<body>
<h1>verify-panel-events</h1>
<script>
  // Fire one emit on load. window.quickshow is defined by the
  // bundle's WKUserScript injection at .atDocumentStart.
  function go() {
    if (window.quickshow && window.quickshow.emit) {
      window.quickshow.emit({ type: "verify", source: "smoke", n: 1 });
    }
  }
  if (document.readyState === "complete") {
    go();
  } else {
    window.addEventListener("load", go);
  }
</script>
</body></html>`;

async function helloAndArm(client: SocketClient, sessionId: string, arm: boolean): Promise<boolean> {
  const hello = await client.request({
    kind: "hello",
    session_id: sessionId,
    client: "verify-panel-events",
  });
  if (hello.kind !== "ok") {
    console.error("verify-panel-events: hello rejected:", JSON.stringify(hello));
    return false;
  }
  if (arm) {
    const armed = await client.request({
      kind: "set_session_flag",
      session: sessionId,
      key: "panel_events_armed",
      value: true,
    });
    if (armed.kind !== "ok") {
      console.error("verify-panel-events: set_session_flag rejected:", JSON.stringify(armed));
      return false;
    }
    console.error(`verify-panel-events: armed session ${sessionId}`);
  } else {
    console.error(`verify-panel-events: session ${sessionId} left un-armed (gate test)`);
  }
  return true;
}

async function renderAndWait(client: SocketClient, sessionId: string, panel: string): Promise<boolean> {
  const upsert = await client.request({
    kind: "upsert",
    session: sessionId,
    name: panel,
    content_type: "html",
    form: "inline",
    body: EMIT_HTML,
  });
  if (upsert.kind !== "ok") {
    console.error(`verify-panel-events: upsert rejected for ${panel}:`, JSON.stringify(upsert));
    return false;
  }
  // The emit is fire-and-forget — the panel's load fired before
  // upsert returns. Give the writer a tick to flush.
  await new Promise((r) => setTimeout(r, 250));
  return true;
}

function readLines(sessionId: string): string[] {
  const log = markupEventsLog(sessionId);
  if (!fs.existsSync(log)) return [];
  return fs.readFileSync(log, "utf8").split("\n").filter(Boolean);
}

async function main(): Promise<number> {
  const gate = process.argv.includes("--gate");
  const socketPath = process.env.QUICKSHOW_SOCKET_PATH ?? DEFAULT_SOCKET_PATH;
  const armedSession = process.env.QUICKSHOW_VERIFY_SESSION ?? "panel-verify-armed";
  const unarmedSession = (process.env.QUICKSHOW_VERIFY_SESSION ?? "panel-verify") + "-unarmed";
  const panel = "verify-pe";

  const client = new SocketClient(socketPath);
  await client.connect(2000);

  // (1) Armed path: arm, render, expect a panel_event line.
  if (!(await helloAndArm(client, armedSession, true))) return 1;
  if (!(await renderAndWait(client, armedSession, panel))) return 1;

  const lines = readLines(armedSession);
  const panelLines = lines.filter((l) => l.includes('"panel_event"') && l.includes(`"${panel}"`));
  console.error(`verify-panel-events: armed log lines=${lines.length} panel_event=${panelLines.length}`);
  if (panelLines.length === 0) {
    console.error("verify-panel-events: expected at least one panel_event line — none found");
    return 1;
  }
  const first = panelLines[0]!;
  // Quick payload sanity check.
  if (!first.includes('"type":"verify"') || !first.includes('"source":"smoke"')) {
    console.error("verify-panel-events: payload did not round-trip — line:", first);
    return 1;
  }
  console.error("verify-panel-events: panel_event line OK:", first);

  // (2) Optional gate test: un-armed session must NOT produce panel_event lines.
  if (gate) {
    // Re-hello under a different session id; we deliberately skip arming.
    if (!(await helloAndArm(client, unarmedSession, false))) return 1;
    if (!(await renderAndWait(client, unarmedSession, panel))) return 1;
    const ungated = readLines(unarmedSession).filter((l) => l.includes('"panel_event"'));
    console.error(`verify-panel-events: un-armed panel_event=${ungated.length}`);
    if (ungated.length !== 0) {
      console.error("verify-panel-events: arming gate FAILED — un-armed session leaked panel_event lines");
      return 1;
    }
    console.error("verify-panel-events: arming gate OK (un-armed session produced no panel_event lines)");
  }

  client.close();
  console.error("verify-panel-events: OK");
  return 0;
}

main().then((code) => process.exit(code)).catch((err) => {
  console.error("verify-panel-events: error:", err instanceof Error ? err.message : String(err));
  process.exit(2);
});
