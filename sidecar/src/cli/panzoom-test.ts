// Interactive pan/zoom test setup.
// Renders a rich Mermaid diagram (busy enough that fit-to-panel is
// cramped at default zoom), a small-text SVG, and a real image —
// so the human can exercise wheel-zoom, drag-pan, and dblclick-reset
// across all three renderers.

import { randomUUID } from "node:crypto";
import * as fs from "node:fs";
import { SocketClient, DEFAULT_SOCKET_PATH } from "../socket.ts";

const SOCK = process.env.QUICKSHOW_SOCKET_PATH ?? DEFAULT_SOCKET_PATH;

async function main() {
  const sessionId = randomUUID();
  const client = new SocketClient(SOCK);
  await client.connect(2000);
  await client.request({ kind: "hello", session_id: sessionId, client: "panzoom-test" });

  // 1. A busy mermaid diagram — too many nodes to read at fit-zoom.
  await client.request({
    kind: "upsert", session: sessionId, name: "busy-diagram",
    content_type: "mermaid", form: "inline",
    body: `flowchart TB
  subgraph S1[Sidecar]
    A1[handler:markdown]
    A2[handler:svg]
    A3[handler:mermaid]
    A4[handler:image]
    A5[PathResolver]
    A6[SocketClient]
  end
  subgraph S2[App]
    B1[ControlServer]
    B2[SessionManager]
    B3[HUDWindow]
    B4[WebViewPanelRenderer]
    B5[MarkdownRenderer]
    B6[SVGRenderer]
    B7[MermaidRenderer]
    B8[ImageRenderer]
    B9[SnapshotService]
    B10[PromoteToWindowController]
    B11[TabStripView]
    B12[ResizeHandle]
  end
  A1-->A6; A2-->A6; A3-->A6; A4-->A6
  A5-->A1; A5-->A4
  A6-->B1
  B1-->B2
  B2-->B3
  B3-->B11; B3-->B12
  B2-->B4
  B4-->B5; B4-->B6; B4-->B7
  B2-->B8
  B4-->B9; B8-->B9
  B2-->B10`,
  });
  console.error("✓ busy-diagram (mermaid) — wheel-zoom into the lower cluster");

  // 2. SVG with deliberately tiny text — zoom to read.
  await client.request({
    kind: "upsert", session: sessionId, name: "tiny-text",
    content_type: "svg", form: "inline",
    body: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 400" width="600" height="400">
  <rect width="600" height="400" fill="#0d1117"/>
  <text x="300" y="40" font-family="-apple-system" font-size="20" fill="#e6edf3" text-anchor="middle" font-weight="600">Zoom in to read</text>
  ${Array.from({ length: 24 }, (_, i) => {
    const y = 70 + i * 13;
    return `<text x="20" y="${y}" font-family="ui-monospace" font-size="9" fill="#e6edf3">${
      "0x" + (0xdeadbeef + i).toString(16) + "  " +
      "lorem ipsum dolor sit amet, consectetur adipiscing elit — line " + (i + 1)
    }</text>`;
  }).join("\n  ")}
  <text x="20" y="${70 + 24 * 13 + 20}" font-family="ui-monospace" font-size="9" fill="#7d8590" font-style="italic">drag to pan when zoomed in · double-click to reset</text>
</svg>`,
  });
  console.error("✓ tiny-text (svg) — wheel-zoom to read");

  // 3. An actual image to zoom into. Use the markdown render PNG
  // from earlier tests if it exists; otherwise the demo report PNG.
  const candidates = ["/tmp/qs-phase1-render.png", "/tmp/qs-demo-report.png", "/tmp/qs-phase2-mermaid.png"];
  const image = candidates.find((p) => fs.existsSync(p));
  if (image) {
    await client.request({
      kind: "upsert", session: sessionId, name: "photo",
      content_type: "image", form: "path", body: image,
    });
    console.error(`✓ photo (image: ${image}) — wheel-zoom · drag-pan`);
  } else {
    console.error("✗ photo skipped: no fixture image at /tmp/qs-*.png — run a prior verify-phase1.ts first");
  }

  client.close();
  console.error(`
📌 Gestures to try (every panel):
   • wheel up        → zoom in (centered on cursor)
   • wheel down      → zoom out
   • drag            → pan (when zoomed in for image; always for SVG/mermaid)
   • double-click    → reset to fit + center

   Trackpad pinch should also zoom (built-in NSScrollView gesture
   for the image; WKWebView delivers pinches as wheel-with-ctrl
   events for the diagrams).`);
}

main().catch((err) => {
  console.error(`failed: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
