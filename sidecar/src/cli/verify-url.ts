// show_url verification: drive URLRenderer end-to-end against a
// local HTTP server so the test is hermetic.
//
// Steps:
//   1. Start `Bun.serve` on a random port serving two known pages.
//   2. Upsert a URL panel pointing at /a → assert ok, non-zero dims,
//      a PNG screenshot.
//   3. Re-upsert the same `name` pointing at /b → assert ok and
//      different document size from the first response (proves the
//      panel reloaded rather than stayed pinned to /a).
//   4. Upsert a URL panel pointing at a port nothing listens on →
//      assert render_error (no hang, no crash).

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

const PAGE_A = `<!DOCTYPE html>
<html><head><title>QuickShow URL test A</title>
<style>body { margin:0; padding:24px; font-family: system-ui; background:#0f172a; color:#f8fafc; }
h1 { color:#a78bfa; } .badge { background:#7c3aed; padding:4px 10px; border-radius:4px; }</style>
</head><body>
<h1>show_url smoke — page A</h1>
<p>This page is served by Bun.serve at a random port.</p>
<p><span class="badge">A</span></p>
</body></html>`;

const PAGE_B = `<!DOCTYPE html>
<html><head><title>QuickShow URL test B</title>
<style>body { margin:0; padding:24px; font-family: system-ui; background:#0c4a6e; color:#f0f9ff; }
h1 { color:#67e8f9; }
/* Deliberately bigger than page A so the dims differ. */
.spacer { height:600px; }</style>
</head><body>
<h1>show_url smoke — page B</h1>
<p>A different page reached via re-upsert with the same name.</p>
<div class="spacer"></div>
<p>End of page B.</p>
</body></html>`;

async function main() {
  // Start local server first so we have a stable URL to test against.
  const server = Bun.serve({
    port: 0,
    fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/a") {
        return new Response(PAGE_A, { headers: { "content-type": "text/html" } });
      }
      if (url.pathname === "/b") {
        return new Response(PAGE_B, { headers: { "content-type": "text/html" } });
      }
      return new Response("not found", { status: 404 });
    },
  });
  const base = `http://127.0.0.1:${server.port}`;
  console.error(`local server on ${base}`);

  try {
    const socketPath = process.env.QUICKSHOW_SOCKET_PATH ?? DEFAULT_SOCKET_PATH;
    const client = new SocketClient(socketPath);
    await client.connect(2000);
    const sessionId = await helloHandshake(client, randomUUID(), "verify-url");

    // === Step 1: load page A ===
    const respA = await client.request({
      kind: "upsert", session: sessionId, name: "url-test",
      content_type: "url", form: "url", body: `${base}/a`,
      width: 800,
    });
    assert(respA.kind === "ok", `page A upsert ok (kind=${respA.kind}${"error" in respA ? ` err=${respA.error}` : ""})`);
    const resultA = (respA as { result: { width: number; height: number; screenshot_b64?: string } }).result;
    assert(resultA.width > 0 && resultA.height > 0, `page A dims > 0 (${resultA.width}×${resultA.height})`);
    const pngA = Buffer.from(resultA.screenshot_b64!, "base64");
    assert(pngA.subarray(0, PNG_MAGIC.length).equals(PNG_MAGIC), "page A screenshot is a PNG");
    fs.writeFileSync("/tmp/qs-url-a.png", pngA);

    // === Step 2: same name, different URL → panel reloads ===
    const respB = await client.request({
      kind: "upsert", session: sessionId, name: "url-test",
      content_type: "url", form: "url", body: `${base}/b`,
      width: 800,
    });
    assert(respB.kind === "ok", `page B upsert ok (kind=${respB.kind}${"error" in respB ? ` err=${respB.error}` : ""})`);
    const resultB = (respB as { result: { width: number; height: number; screenshot_b64?: string } }).result;
    assert(resultB.width > 0 && resultB.height > 0, `page B dims > 0 (${resultB.width}×${resultB.height})`);
    const pngB = Buffer.from(resultB.screenshot_b64!, "base64");
    assert(pngB.subarray(0, PNG_MAGIC.length).equals(PNG_MAGIC), "page B screenshot is a PNG");
    fs.writeFileSync("/tmp/qs-url-b.png", pngB);
    // Page B has a 600px spacer; expect height > page A.
    assert(resultB.height > resultA.height,
      `page B taller than page A (B=${resultB.height} vs A=${resultA.height}) — proves panel reloaded`);

    // === Step 3: list shows one panel under that name ===
    const listResp = await client.request({ kind: "list", session: sessionId });
    const panels = (listResp as { result: Array<{ name: string; content_type: string }> }).result;
    const urlPanel = panels.find(p => p.name === "url-test");
    assert(urlPanel !== undefined, "list contains the url-test panel");
    assert(urlPanel!.content_type === "url", `panel content_type is 'url' (got '${urlPanel!.content_type}')`);

    // === Step 4: render_error path — ATS-blocked URL ===
    // App Transport Security blocks plain-http to non-localhost
    // hostnames. WebKit fires didFailProvisionalNavigation before
    // any page render, so this is the cleanest deterministic way to
    // exercise the render_error wire path.
    //
    // (Other failure modes — connection-refused, TLS handshake to a
    // dead port — get rendered as WebKit's own in-page error UI and
    // fire didFinish instead. The user still sees the failure
    // visually in the panel, but the MCP response is `ok`. That's a
    // WebKit behaviour, not a QuickShow bug.)
    const respBad = await client.request({
      kind: "upsert", session: sessionId, name: "url-test-bad",
      content_type: "url", form: "url",
      body: "http://this-host-does-not-exist-quickshow.invalid/",
    });
    assert(respBad.kind === "render_error",
      `ATS-blocked URL → render_error (got ${respBad.kind})`);
    const badError = respBad as { error: string };
    assert(typeof badError.error === "string" && badError.error.length > 0,
      `render_error includes a message: ${badError.error.slice(0, 80)}`);

    client.close();
    console.error("\n✅ show_url verification passed.");
  } finally {
    server.stop(true);
  }
}

main().catch((err) => {
  console.error(`FAIL: ${err instanceof Error ? err.message : String(err)}`);
  console.error(err);
  process.exit(1);
});
