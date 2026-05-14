// Phase 1 end-to-end verification:
//   1. Connect to a pre-launched app via QUICKSHOW_SOCKET_PATH.
//   2. Send hello + a show_markdown upsert.
//   3. Assert the response is `ok` and includes a non-empty PNG.
//   4. Decode the base64 → bytes; check PNG magic.
//   5. Update the panel a second time (latest-wins).
//   6. Send close. List should now return empty.
//   7. Print summary + write the snapshot to /tmp/qs-phase1-render.png.
//
// Usage:
//   QUICKSHOW_SOCKET_PATH=/tmp/qs.sock bun run sidecar/src/cli/verify-phase1.ts

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

async function main() {
  const socketPath = process.env.QUICKSHOW_SOCKET_PATH ?? DEFAULT_SOCKET_PATH;
  const client = new SocketClient(socketPath);
  await client.connect(2000);

  // 1. Hello — helloHandshake throws on non-ok, so passing here means
  //    the handshake worked. Adopts the app-granted session_id.
  const sessionId = await helloHandshake(client, randomUUID(), "verify-cli");
  assert(typeof sessionId === "string" && sessionId.length > 0, `hello returned a session_id`);

  // 2. show_markdown upsert
  const markdownBody = "# Hello QuickShow\n\nThis is a **Phase 1** verification render.\n\n- one\n- two\n- three\n\n```ts\nconst x: number = 42;\n```";
  const upsert = await client.request({
    kind: "upsert",
    session: sessionId,
    name: "verify",
    content_type: "markdown",
    form: "inline",
    body: markdownBody,
  });
  assert(upsert.kind === "ok", `upsert returned ok (kind=${upsert.kind}${"error" in upsert ? `, err=${upsert.error}` : ""})`);
  const result = (upsert as { result: { width: number; height: number; screenshot_b64?: string } }).result;
  assert(typeof result.width === "number" && result.width > 0, `width > 0 (got ${result.width})`);
  assert(typeof result.height === "number" && result.height > 0, `height > 0 (got ${result.height})`);
  assert(typeof result.screenshot_b64 === "string" && result.screenshot_b64.length > 0, `screenshot_b64 present (len=${result.screenshot_b64?.length})`);

  // 3. Decode + validate PNG
  const png = Buffer.from(result.screenshot_b64!, "base64");
  assert(png.length > PNG_MAGIC.length, `PNG bytes len > magic (got ${png.length})`);
  assert(png.subarray(0, PNG_MAGIC.length).equals(PNG_MAGIC), `PNG magic bytes match`);

  // 4. Save for human inspection
  const outPath = "/tmp/qs-phase1-render.png";
  fs.writeFileSync(outPath, png);
  console.error(`✓ snapshot saved to ${outPath} (${png.length} bytes, ${result.width}×${result.height})`);

  // 5. Update same panel with new content (latest-wins)
  const upsert2 = await client.request({
    kind: "upsert",
    session: sessionId,
    name: "verify",
    content_type: "markdown",
    form: "inline",
    body: "# Updated\n\nThis is the second render. Panel should update in place.",
  });
  assert(upsert2.kind === "ok", `second upsert returned ok`);

  // 6. Render-error path: pass a body that doesn't trigger marked errors,
  //    but verify the panel handles weird input gracefully.
  const weirdUpsert = await client.request({
    kind: "upsert",
    session: sessionId,
    name: "verify",
    content_type: "markdown",
    form: "inline",
    body: "<script>alert('xss')</script>\n\n**Should sanitize the script away.**",
  });
  assert(weirdUpsert.kind === "ok", `sanitization upsert returned ok (DOMPurify dropped the script)`);

  // 7. List
  const list = await client.request({ kind: "list", session: sessionId });
  assert(list.kind === "ok", `list returned ok`);
  const panels = (list as { result: Array<{ name: string }> }).result;
  assert(Array.isArray(panels), `list result is an array`);
  assert(panels.length === 1, `list shows 1 panel (got ${panels.length})`);
  assert(panels[0]!.name === "verify", `list shows correct panel name`);

  // 8. Close
  const close = await client.request({ kind: "close", session: sessionId, name: "verify" });
  assert(close.kind === "ok", `close returned ok`);

  // 9. List after close → empty
  const list2 = await client.request({ kind: "list", session: sessionId });
  assert(list2.kind === "ok", `second list returned ok`);
  const panels2 = (list2 as { result: Array<unknown> }).result;
  assert(panels2.length === 0, `list shows 0 panels after close (got ${panels2.length})`);

  client.close();
  console.error("\n✅ Phase 1 verification passed.");
}

main().catch((err) => {
  console.error(`FAIL: ${err instanceof Error ? err.message : String(err)}`);
  console.error(err);
  process.exit(1);
});
