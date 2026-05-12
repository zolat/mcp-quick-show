// Phase 3 verification: multi-tab per session, list/close semantics.

import { randomUUID } from "node:crypto";
import { SocketClient, DEFAULT_SOCKET_PATH } from "../socket.ts";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) {
    console.error(`FAIL: ${msg}`);
    process.exit(1);
  }
  console.error(`✓ ${msg}`);
}

async function main() {
  const socketPath = process.env.QUICKSHOW_SOCKET_PATH ?? DEFAULT_SOCKET_PATH;
  const client = new SocketClient(socketPath);
  const sessionId = randomUUID();

  await client.connect(2000);
  await client.request({ kind: "hello", session_id: sessionId, client: "verify-phase3" });

  // Open three different-named panels in the same session.
  for (const [name, body] of [
    ["arch", "# Arch v1\n\nFirst panel."],
    ["plan", "# Plan\n\n- step 1\n- step 2"],
    ["notes", "# Notes\n\nSome notes go here."],
  ] as const) {
    const r = await client.request({
      kind: "upsert", session: sessionId, name,
      content_type: "markdown", form: "inline", body,
    });
    assert(r.kind === "ok", `upsert '${name}' ok`);
  }

  // list should return all three.
  const list1 = await client.request({ kind: "list", session: sessionId });
  const panels1 = (list1 as { result: Array<{ name: string }> }).result;
  assert(panels1.length === 3, `list returns 3 panels (got ${panels1.length})`);
  assert(panels1.map(p => p.name).sort().join(",") === "arch,notes,plan",
    `panel names match: ${panels1.map(p => p.name).join(",")}`);

  // Same-name re-upsert updates in place (still 3 panels).
  const update = await client.request({
    kind: "upsert", session: sessionId, name: "arch",
    content_type: "markdown", form: "inline", body: "# Arch v2\n\nUpdated in place.",
  });
  assert(update.kind === "ok", `re-upsert 'arch' ok`);
  const list2 = await client.request({ kind: "list", session: sessionId });
  const panels2 = (list2 as { result: Array<{ name: string }> }).result;
  assert(panels2.length === 3, `re-upsert kept panel count at 3 (got ${panels2.length})`);

  // Close one panel.
  const close1 = await client.request({ kind: "close", session: sessionId, name: "plan" });
  assert(close1.kind === "ok", `close 'plan' ok`);
  const list3 = await client.request({ kind: "list", session: sessionId });
  const panels3 = (list3 as { result: Array<{ name: string }> }).result;
  assert(panels3.length === 2, `after close: 2 panels (got ${panels3.length})`);
  assert(!panels3.some(p => p.name === "plan"), `'plan' is gone`);

  // Inspect a still-open panel.
  const inspect = await client.request({ kind: "inspect", session: sessionId, name: "notes" });
  assert(inspect.kind === "ok", `inspect 'notes' ok`);
  const inspectResult = (inspect as { result: { screenshot_b64?: string } }).result;
  assert(typeof inspectResult.screenshot_b64 === "string" && inspectResult.screenshot_b64.length > 0,
    `inspect returned a screenshot`);

  // Inspect a closed panel → protocol_error.
  const inspectGone = await client.request({ kind: "inspect", session: sessionId, name: "plan" });
  assert(inspectGone.kind === "protocol_error", `inspect on closed panel → protocol_error (got ${inspectGone.kind})`);

  // Two sessions should be isolated.
  const otherSession = randomUUID();
  await client.request({ kind: "hello", session_id: otherSession, client: "verify-phase3-other" });
  const otherList = await client.request({ kind: "list", session: otherSession });
  const otherPanels = (otherList as { result: Array<unknown> }).result;
  assert(otherPanels.length === 0, `other session sees 0 panels (got ${otherPanels.length})`);

  // Open a panel with the SAME name in the other session — should not collide.
  await client.request({
    kind: "upsert", session: otherSession, name: "arch",
    content_type: "markdown", form: "inline", body: "# Other-session arch",
  });
  const otherList2 = await client.request({ kind: "list", session: otherSession });
  const otherPanels2 = (otherList2 as { result: Array<{ name: string }> }).result;
  assert(otherPanels2.length === 1 && otherPanels2[0]!.name === "arch",
    `other session has its own 'arch' panel`);
  const list4 = await client.request({ kind: "list", session: sessionId });
  const panels4 = (list4 as { result: Array<{ name: string }> }).result;
  assert(panels4.length === 2, `original session still has 2 panels (got ${panels4.length})`);

  client.close();
  console.error("\n✅ Phase 3 verification passed.");
}

main().catch((err) => {
  console.error(`FAIL: ${err instanceof Error ? err.message : String(err)}`);
  console.error(err);
  process.exit(1);
});
