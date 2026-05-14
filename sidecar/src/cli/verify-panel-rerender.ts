// Re-render survival check for the panel_event channel.
//
// Renders the same panel name twice (back-to-back show_html upserts
// with different tag values). Confirms BOTH emits produce panel_event
// lines — verifying that the .atDocumentStart WKUserScript that
// defines window.quickshow.emit is re-injected on full document
// reloads (loadHTMLString).

import * as fs from "node:fs";
import { SocketClient, DEFAULT_SOCKET_PATH } from "../socket.ts";
import { markupEventsLog } from "../session.ts";

const HTML = (tag: string) => `<!doctype html><html><body><script>
  function go() {
    if (window.quickshow && window.quickshow.emit) {
      window.quickshow.emit({ tag: ${JSON.stringify(tag)} });
    }
  }
  if (document.readyState === "complete") go();
  else window.addEventListener("load", go);
</script></body></html>`;

async function main(): Promise<number> {
  const socketPath = process.env.QUICKSHOW_SOCKET_PATH ?? DEFAULT_SOCKET_PATH;
  const session = process.env.QUICKSHOW_VERIFY_SESSION ?? "panel-rerender-smoke";
  const panel = "rerender-pe";

  const c = new SocketClient(socketPath);
  await c.connect(2000);

  const hello = await c.request({ kind: "hello", session_id: session, client: "verify-rerender" });
  if (hello.kind !== "ok") { console.error("hello failed:", hello); return 1; }
  const armed = await c.request({ kind: "set_session_flag", session, key: "panel_events_armed", value: true });
  if (armed.kind !== "ok") { console.error("arm failed:", armed); return 1; }

  const u1 = await c.request({ kind: "upsert", session, name: panel, content_type: "html", form: "inline", body: HTML("first") });
  if (u1.kind !== "ok") { console.error("first upsert failed:", u1); return 1; }
  await new Promise((r) => setTimeout(r, 300));

  const u2 = await c.request({ kind: "upsert", session, name: panel, content_type: "html", form: "inline", body: HTML("second") });
  if (u2.kind !== "ok") { console.error("second upsert failed:", u2); return 1; }
  await new Promise((r) => setTimeout(r, 300));

  const lines = fs.readFileSync(markupEventsLog(session), "utf8").split("\n").filter(Boolean);
  const tags = lines.filter((l) => l.includes('"panel_event"') && l.includes(`"${panel}"`))
    .map((l) => (l.match(/"tag":"([^"]+)"/) || [, ""])[1]);
  console.error("verify-panel-rerender: tags=", tags);
  if (!tags.includes("first") || !tags.includes("second")) {
    console.error("verify-panel-rerender: FAILED — expected both 'first' and 'second' tags");
    return 1;
  }
  c.close();
  console.error("verify-panel-rerender: OK");
  return 0;
}

main().then((code) => process.exit(code)).catch((err) => {
  console.error("verify-panel-rerender: error:", err instanceof Error ? err.message : String(err));
  process.exit(2);
});
