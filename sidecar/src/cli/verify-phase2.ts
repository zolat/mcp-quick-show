// Phase 2 verification: SVG, Mermaid, Image renderers.
// Drives each through an upsert + asserts the right kind of payload
// comes back.

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { randomUUID } from "node:crypto";
import { SocketClient, DEFAULT_SOCKET_PATH } from "../socket.ts";

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
  const sessionId = randomUUID();

  await client.connect(2000);
  await client.request({ kind: "hello", session_id: sessionId, client: "verify-phase2" });

  // === SVG ===
  const svgBody = `<svg xmlns="http://www.w3.org/2000/svg" width="200" height="120" viewBox="0 0 200 120">
    <rect x="10" y="10" width="180" height="100" fill="#4f46e5" rx="8"/>
    <text x="100" y="65" fill="white" font-family="sans-serif" font-size="16" text-anchor="middle">QuickShow SVG</text>
  </svg>`;
  const svgResp = await client.request({
    kind: "upsert", session: sessionId, name: "svg-test",
    content_type: "svg", form: "inline", body: svgBody,
  });
  assert(svgResp.kind === "ok", `SVG upsert ok (kind=${svgResp.kind})`);
  const svgResult = (svgResp as { result: { width: number; height: number; screenshot_b64?: string } }).result;
  assert(svgResult.width > 0 && svgResult.height > 0, `SVG dimensions > 0 (${svgResult.width}×${svgResult.height})`);
  const svgPng = Buffer.from(svgResult.screenshot_b64!, "base64");
  assert(svgPng.subarray(0, PNG_MAGIC.length).equals(PNG_MAGIC), `SVG screenshot is a PNG`);
  fs.writeFileSync("/tmp/qs-phase2-svg.png", svgPng);

  // === Mermaid ===
  const mermaidBody = `flowchart LR
    A[User] --> B{Agent}
    B -->|MCP show_mermaid| C[QuickShow]
    C --> D[(Rendered HUD)]
    C -.->|screenshot| B`;
  const mermaidResp = await client.request({
    kind: "upsert", session: sessionId, name: "mermaid-test",
    content_type: "mermaid", form: "inline", body: mermaidBody,
  });
  assert(mermaidResp.kind === "ok", `Mermaid upsert ok (kind=${mermaidResp.kind}${"error" in mermaidResp ? ` err=${mermaidResp.error}` : ""})`);
  const mermaidResult = (mermaidResp as { result: { width: number; height: number; screenshot_b64?: string } }).result;
  assert(mermaidResult.width > 0 && mermaidResult.height > 0, `Mermaid dimensions > 0`);
  const mermaidPng = Buffer.from(mermaidResult.screenshot_b64!, "base64");
  assert(mermaidPng.subarray(0, PNG_MAGIC.length).equals(PNG_MAGIC), `Mermaid screenshot is a PNG`);
  fs.writeFileSync("/tmp/qs-phase2-mermaid.png", mermaidPng);

  // === Mermaid render_error path ===
  const badMermaid = await client.request({
    kind: "upsert", session: sessionId, name: "mermaid-test",
    content_type: "mermaid", form: "inline", body: "this is not\nvalid mermaid syntax @@@",
  });
  assert(badMermaid.kind === "render_error", `Bad mermaid → render_error (got ${badMermaid.kind})`);
  const badError = badMermaid as { error: string; line?: number; screenshot_b64?: string };
  assert(typeof badError.error === "string" && badError.error.length > 0, `render_error includes message: ${badError.error.slice(0, 80)}`);

  // === Image ===
  // Write a tiny PNG fixture so we have a real file.
  const fixturePath = path.join(os.tmpdir(), `qs-fixture-${process.pid}.png`);
  // Minimal 2x2 PNG (red square).
  const fixture = Buffer.from([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, // PNG signature
    0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
    0x08, 0x02, 0x00, 0x00, 0x00, 0xfd, 0xd4, 0x9a, 0x73,
    0x00, 0x00, 0x00, 0x16, 0x49, 0x44, 0x41, 0x54,
    0x78, 0x9c, 0x62, 0xfc, 0xcf, 0xc0, 0xf0, 0x1f,
    0x08, 0x60, 0x60, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff,
    0x03, 0x00, 0x00, 0x07, 0x00, 0x02, 0xfd, 0x69, 0x46, 0x99,
    0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
  ]);
  fs.writeFileSync(fixturePath, fixture);

  const imgResp = await client.request({
    kind: "upsert", session: sessionId, name: "image-test",
    content_type: "image", form: "path", body: fixturePath,
  });
  assert(imgResp.kind === "ok", `Image upsert ok (kind=${imgResp.kind}${"error" in imgResp ? ` err=${imgResp.error}` : ""})`);
  const imgResult = (imgResp as { result: { width: number; height: number; screenshot_b64?: string } }).result;
  assert(imgResult.width > 0 && imgResult.height > 0, `Image dimensions > 0`);
  // For images, the screenshot is the image bytes themselves (per PRD).
  const imgPng = Buffer.from(imgResult.screenshot_b64!, "base64");
  assert(imgPng.subarray(0, PNG_MAGIC.length).equals(PNG_MAGIC), `Image response is a PNG`);

  // === List should show all 3 panels (svg, mermaid, image) ===
  // Post-Phase 3 each different-named upsert opens a new tab in the
  // session, so we expect 3 panels here.
  const listResp = await client.request({ kind: "list", session: sessionId });
  const panels = (listResp as { result: Array<{ name: string }> }).result;
  console.error(`list returned ${panels.length} panel(s): ${panels.map(p => p.name).join(", ")}`);
  assert(panels.length === 3, `Phase 3 multi-tab: list shows all 3 panels (got ${panels.length})`);

  client.close();
  console.error("\n✅ Phase 2 verification passed.");
  fs.unlinkSync(fixturePath);
}

main().catch((err) => {
  console.error(`FAIL: ${err instanceof Error ? err.message : String(err)}`);
  console.error(err);
  process.exit(1);
});
