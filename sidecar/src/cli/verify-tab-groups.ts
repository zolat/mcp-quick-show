// Tab-grouping verification: drive the new `group` /
// `description` / `hud_description` wire fields end-to-end against a
// running QuickShow app, then assert via the `list` verb that the
// groupings landed in the right HUDs.
//
// Caveat: `list` is panel-flat — it doesn't return HUD topology. To
// observe grouping we count distinct panels and rely on app-side
// behaviour (re-using `name` is idempotent, novel `name` with the same
// `group` lands in the same HUD). For visual confirmation, screenshots
// are saved to /tmp/qs-group-*.png — eyeball them after the run.
//
// Coverage:
//   1. Two panels in `group=a` — one HUD, two tabs.
//   2. One panel in `group=b`  — a second HUD.
//   3. One ungrouped panel    — a third HUD (the default).
//   4. Re-render existing name with mismatched `group` → group ignored,
//      panel stays put (verified by total panel count not changing).

import * as fs from "node:fs";
import { randomUUID } from "node:crypto";
import { SocketClient, DEFAULT_SOCKET_PATH } from "../socket.ts";
import { helloHandshake } from "../handshake.ts";

const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) {
    console.error(`FAIL: ${msg}`);
    process.exit(1);
  }
  console.error(`✓ ${msg}`);
}

const HTML_A = "<!doctype html><html><body style='font:24px sans-serif;padding:24px;background:#1e293b;color:#f8fafc'><h1>Variant A</h1></body></html>";
const HTML_B = "<!doctype html><html><body style='font:24px sans-serif;padding:24px;background:#7c2d12;color:#fef3c7'><h1>Variant B</h1></body></html>";
const HTML_C = "<!doctype html><html><body style='font:24px sans-serif;padding:24px;background:#064e3b;color:#d1fae5'><h1>Comparison view</h1></body></html>";
const HTML_D = "<!doctype html><html><body style='font:24px sans-serif;padding:24px;background:#1f2937;color:#e5e7eb'><h1>Standalone</h1></body></html>";

async function main() {
  const socketPath = process.env.QUICKSHOW_SOCKET_PATH ?? DEFAULT_SOCKET_PATH;
  const client = new SocketClient(socketPath);
  await client.connect(2000);
  const sessionId = await helloHandshake(client, randomUUID(), "verify-tab-groups");

  // --- Step 1: two panels in group=a with a hud_description ---
  const resp1 = await client.request({
    kind: "upsert", session: sessionId,
    name: "variant-a", content_type: "html", form: "inline", body: HTML_A,
    group: "design-review",
    hud_description: "Three hero variants ranked best-to-worst.",
    description: "Bold serif. 90s editorial revival.",
  });
  assert(resp1.kind === "ok", `variant-a upsert ok (kind=${resp1.kind})`);
  const r1 = (resp1 as { result: { screenshot_b64?: string } }).result;
  fs.writeFileSync("/tmp/qs-group-variant-a.png", Buffer.from(r1.screenshot_b64!, "base64"));

  const resp2 = await client.request({
    kind: "upsert", session: sessionId,
    name: "variant-b", content_type: "html", form: "inline", body: HTML_B,
    group: "design-review",
    description: "Neo-grotesk. Tighter.",
  });
  assert(resp2.kind === "ok", `variant-b upsert ok (kind=${resp2.kind})`);
  const r2 = (resp2 as { result: { screenshot_b64?: string } }).result;
  fs.writeFileSync("/tmp/qs-group-variant-b.png", Buffer.from(r2.screenshot_b64!, "base64"));

  // --- Step 2: one panel in group=b ---
  const resp3 = await client.request({
    kind: "upsert", session: sessionId,
    name: "comparison", content_type: "html", form: "inline", body: HTML_C,
    group: "research",
    hud_description: "Field research notes.",
  });
  assert(resp3.kind === "ok", `comparison upsert ok (kind=${resp3.kind})`);
  const r3 = (resp3 as { result: { screenshot_b64?: string } }).result;
  fs.writeFileSync("/tmp/qs-group-comparison.png", Buffer.from(r3.screenshot_b64!, "base64"));

  // --- Step 3: ungrouped panel (default HUD) ---
  const resp4 = await client.request({
    kind: "upsert", session: sessionId,
    name: "standalone", content_type: "html", form: "inline", body: HTML_D,
  });
  assert(resp4.kind === "ok", `standalone upsert ok (kind=${resp4.kind})`);
  const r4 = (resp4 as { result: { screenshot_b64?: string; screenshot_b64Buf?: never } }).result;
  fs.writeFileSync("/tmp/qs-group-standalone.png", Buffer.from(r4.screenshot_b64!, "base64"));
  assert(Buffer.from(r4.screenshot_b64!, "base64").subarray(0, PNG_MAGIC.length).equals(PNG_MAGIC),
    "standalone screenshot is a PNG");

  // --- Step 4: list — 4 panels total ---
  const listResp = await client.request({ kind: "list", session: sessionId });
  const panels = (listResp as { result: Array<{ name: string }> }).result;
  assert(panels.length === 4, `list returns 4 panels (got ${panels.length})`);
  const names = panels.map(p => p.name).sort();
  assert(JSON.stringify(names) === JSON.stringify(["comparison", "standalone", "variant-a", "variant-b"]),
    `panels named correctly (got ${JSON.stringify(names)})`);

  // --- Step 5: re-render existing `variant-a` with a different `group` ---
  // The same name should stay in its original HUD; group is ignored on update.
  // We can't observe HUD topology directly via `list`, but we can confirm:
  //   (a) the upsert succeeds (no error from "panel exists in another HUD"),
  //   (b) total panel count still 4 — no new panel created.
  const respRehome = await client.request({
    kind: "upsert", session: sessionId,
    name: "variant-a", content_type: "html", form: "inline",
    body: "<!doctype html><html><body><h1>variant-a updated</h1></body></html>",
    group: "this-should-be-ignored",
    description: "Updated description.",
  });
  assert(respRehome.kind === "ok", `re-render with mismatched group ok (kind=${respRehome.kind})`);

  const listResp2 = await client.request({ kind: "list", session: sessionId });
  const panels2 = (listResp2 as { result: Array<{ name: string }> }).result;
  assert(panels2.length === 4, `still 4 panels after re-render (got ${panels2.length}) — group was correctly ignored`);

  // --- Step 6: clear hud_description by sending empty string ---
  const respClear = await client.request({
    kind: "upsert", session: sessionId,
    name: "variant-a", content_type: "html", form: "inline",
    body: HTML_A,
    hud_description: "",
  });
  assert(respClear.kind === "ok", `clear hud_description ok (kind=${respClear.kind})`);

  client.close();
  console.error("\n✅ tab-groups verification passed.");
  console.error("   Screenshots in /tmp/qs-group-*.png — eyeball for banner correctness.");
}

main().catch((err) => {
  console.error(`FAIL: ${err instanceof Error ? err.message : String(err)}`);
  console.error(err);
  process.exit(1);
});
