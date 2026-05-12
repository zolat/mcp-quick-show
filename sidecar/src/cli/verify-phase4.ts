// Phase 4 verification: orphan-on-disconnect + reconnect window.
//
// Strategy:
//   1. Open a panel with session UUID X.
//   2. Close the socket → simulates sidecar dying.
//   3. Reconnect with the same UUID within the grace window →
//      panel should still be there, no orphan badge.
//   4. Close again, wait LONGER than the grace window.
//   5. Reconnect with same UUID → panel should still be there,
//      orphan badge would have been visible before the reconnect
//      cleared it.
//   6. Reconnect with a DIFFERENT UUID → that's a separate session;
//      original session's HUD persists.
//
// Requires `QUICKSHOW_RECONNECT_GRACE_SECONDS=2` (or another short
// value) so the test runs quickly.

import { randomUUID } from "node:crypto";
import { SocketClient, DEFAULT_SOCKET_PATH } from "../socket.ts";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) {
    console.error(`FAIL: ${msg}`);
    process.exit(1);
  }
  console.error(`✓ ${msg}`);
}

const SOCK = process.env.QUICKSHOW_SOCKET_PATH ?? DEFAULT_SOCKET_PATH;

async function connectHello(sessionId: string, label: string): Promise<SocketClient> {
  const c = new SocketClient(SOCK);
  await c.connect(2000);
  await c.request({ kind: "hello", session_id: sessionId, client: `verify-phase4-${label}` });
  return c;
}

async function sleep(ms: number) {
  return new Promise(r => setTimeout(r, ms));
}

async function main() {
  const sessionA = randomUUID();
  const sessionB = randomUUID();

  // Step 1: open a panel.
  let c = await connectHello(sessionA, "first");
  await c.request({
    kind: "upsert", session: sessionA, name: "lifecycle",
    content_type: "markdown", form: "inline", body: "# Lifecycle test",
  });
  let list = await c.request({ kind: "list", session: sessionA });
  let panels = (list as { result: Array<unknown> }).result;
  assert(panels.length === 1, "step 1: panel open");

  // Step 2: drop the connection (simulates sidecar crash).
  c.close();
  console.error("⏳ dropped connection — waiting 200ms");
  await sleep(200);

  // Step 3: reconnect inside grace window with the same UUID.
  c = await connectHello(sessionA, "reconnect-fast");
  list = await c.request({ kind: "list", session: sessionA });
  panels = (list as { result: Array<unknown> }).result;
  assert(panels.length === 1, "step 3: panel still present after fast reconnect");

  // Step 4: drop, wait beyond grace window.
  c.close();
  const grace = parseFloat(process.env.QUICKSHOW_RECONNECT_GRACE_SECONDS ?? "60");
  const waitMs = (grace + 0.5) * 1000;
  console.error(`⏳ dropped connection — waiting ${waitMs}ms (grace=${grace}s)`);
  await sleep(waitMs);

  // Step 5: reconnect after grace — HUD persists, badge would have shown.
  c = await connectHello(sessionA, "reconnect-slow");
  list = await c.request({ kind: "list", session: sessionA });
  panels = (list as { result: Array<unknown> }).result;
  assert(panels.length === 1, "step 5: panel still present after slow reconnect (orphaned then reattached)");

  // Step 6: different session works concurrently.
  const c2 = await connectHello(sessionB, "concurrent");
  await c2.request({
    kind: "upsert", session: sessionB, name: "lifecycle-b",
    content_type: "markdown", form: "inline", body: "# Sibling session",
  });
  const listB = await c2.request({ kind: "list", session: sessionB });
  const panelsB = (listB as { result: Array<unknown> }).result;
  assert(panelsB.length === 1, "step 6: sibling session works concurrently");
  const listA = await c.request({ kind: "list", session: sessionA });
  const panelsA = (listA as { result: Array<unknown> }).result;
  assert(panelsA.length === 1, "step 6: original session unaffected by sibling");

  c.close();
  c2.close();
  console.error("\n✅ Phase 4 verification passed.");
}

main().catch((err) => {
  console.error(`FAIL: ${err instanceof Error ? err.message : String(err)}`);
  console.error(err);
  process.exit(1);
});
