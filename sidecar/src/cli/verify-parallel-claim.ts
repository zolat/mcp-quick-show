// Integration smoke for the parallel-Claude-same-cwd fix.
//
// Opens TWO concurrent control-socket connections sending the same
// claim. Expects:
//   - First hello → granted = claim (uncontested).
//   - Second hello → granted ≠ claim (allocator minted a fresh UUID
//     because the claim was already bound to the first FD).
//   - Each connection renders a panel with the same name; each lands
//     in its OWN session — the lists on each side must show exactly
//     one panel.
//   - Each connection's events.ndjson path is distinct.
//
// Usage:
//   QUICKSHOW_SOCKET_PATH=/tmp/qs.sock \
//   QUICKSHOW_EVENTS_DIR=/tmp/qs-events \
//   bun run src/cli/verify-parallel-claim.ts

import { SocketClient, DEFAULT_SOCKET_PATH } from "../socket.ts";
import { helloHandshake } from "../handshake.ts";
import { markupEventsLog } from "../session.ts";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) {
    console.error(`FAIL: ${msg}`);
    process.exit(1);
  }
  console.error(`✓ ${msg}`);
}

async function main(): Promise<number> {
  const socketPath = process.env.QUICKSHOW_SOCKET_PATH ?? DEFAULT_SOCKET_PATH;
  const claim = `parallel-claim-${process.pid}`;

  const c1 = new SocketClient(socketPath);
  await c1.connect(2000);
  const s1 = await helloHandshake(c1, claim, "verify-parallel-1");
  assert(s1 === claim, `first hello: granted = claim (${s1})`);

  // Second connection with the SAME claim — must get a fresh id.
  const c2 = new SocketClient(socketPath);
  await c2.connect(2000);
  const s2 = await helloHandshake(c2, claim, "verify-parallel-2");
  assert(s2 !== claim, `second hello: granted ≠ claim (got ${s2})`);
  assert(s2 !== s1, `second granted ≠ first granted`);

  // Render the same-name panel through each connection. Each lands
  // in its own session.
  for (const [c, s, tag] of [[c1, s1, "one"], [c2, s2, "two"]] as const) {
    const r = await c.request({
      kind: "upsert", session: s, name: "isolation",
      content_type: "markdown", form: "inline",
      body: `# session ${tag}\n\nsession_id = ${s}`,
    });
    assert(r.kind === "ok", `upsert under ${tag} ok`);
  }

  for (const [c, s, tag] of [[c1, s1, "one"], [c2, s2, "two"]] as const) {
    const list = await c.request({ kind: "list", session: s });
    const panels = (list as { result: Array<{ name: string }> }).result;
    assert(panels.length === 1, `${tag}: list shows 1 panel`);
    assert(panels[0]!.name === "isolation", `${tag}: panel name correct`);
  }

  // events.ndjson paths must be distinct.
  const log1 = markupEventsLog(s1);
  const log2 = markupEventsLog(s2);
  assert(log1 !== log2, `events.ndjson paths differ (${log1} vs ${log2})`);

  // Close everything.
  await c1.request({ kind: "close", session: s1, name: "isolation" });
  await c2.request({ kind: "close", session: s2, name: "isolation" });
  c1.close();
  c2.close();
  console.error("\n✅ parallel-claim verification passed.");
  return 0;
}

main().then((code) => process.exit(code)).catch((err) => {
  console.error(`FAIL: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
