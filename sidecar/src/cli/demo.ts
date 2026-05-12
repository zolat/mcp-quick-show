// Live demo — opens a few panels showcasing each renderer.
// Run after the app is already launched (or it will autolaunch).
//
// Usage:
//   bun run sidecar/src/cli/demo.ts

import { randomUUID } from "node:crypto";
import { SocketClient, DEFAULT_SOCKET_PATH } from "../socket.ts";

const SOCK = process.env.QUICKSHOW_SOCKET_PATH ?? DEFAULT_SOCKET_PATH;

async function main() {
  const sessionId = randomUUID();
  const client = new SocketClient(SOCK);
  await client.connect(2000);
  await client.request({ kind: "hello", session_id: sessionId, client: "demo" });

  // 1. A markdown report.
  await client.request({
    kind: "upsert", session: sessionId, name: "report",
    content_type: "markdown", form: "inline",
    body: `# QuickShow v0.1 — feature tour

QuickShow renders **agent-produced content** into floating HUD panels
that stay visible across macOS Spaces — including fullscreen apps.

## Supported content types

| Type      | Tool             | Example use                           |
|-----------|------------------|---------------------------------------|
| Markdown  | \`show_markdown\`  | Long-form reports, docs, summaries    |
| SVG       | \`show_svg\`       | Hand-drawn vector visualizations      |
| Mermaid   | \`show_mermaid\`   | Architecture / sequence diagrams      |
| Image     | \`show_image\`     | Screenshots, generated assets         |

## Iteration loop

Every render returns a PNG snapshot to the agent so it can verify the
output without asking the user:

\`\`\`ts
const result = await show_mermaid("arch", spec);
// result.content includes:
//   { type: "image", data: "<base64 PNG>", mimeType: "image/png" }
\`\`\`

> Update the same panel name in place; pick a new name to open a tab.

Try right-clicking any tab pill for the context menu.`,
  });
  console.error("✓ opened 'report' (markdown)");

  // 2. A mermaid architecture diagram.
  await client.request({
    kind: "upsert", session: sessionId, name: "arch",
    content_type: "mermaid", form: "inline",
    body: `flowchart LR
    subgraph User
      A[Claude Code]
    end
    subgraph Sidecar
      B[MCP stdio server]
      C[Content handlers]
      D[Socket client]
    end
    subgraph App
      E[Control server]
      F[Session manager]
      G[Renderers]
      H[(HUD windows)]
    end
    A -->|tools/call| B
    B --> C
    C --> D
    D -->|NDJSON over UDS| E
    E --> F
    F --> G
    G --> H
    G -.->|PNG snapshot| F
    F -.-> E
    E -.-> D
    D -.-> B
    B -.->|MCP response| A`,
  });
  console.error("✓ opened 'arch' (mermaid)");

  // 3. A mermaid sequence diagram showing the iteration loop.
  await client.request({
    kind: "upsert", session: sessionId, name: "iteration-loop",
    content_type: "mermaid", form: "inline",
    body: `sequenceDiagram
    autonumber
    participant Agent
    participant Sidecar
    participant App
    Agent->>Sidecar: show_mermaid("arch", spec)
    Sidecar->>App: upsert via socket
    App->>App: WKWebView renders
    App-->>Sidecar: ok + PNG screenshot
    Sidecar-->>Agent: MCP response with image
    Note over Agent: Agent sees the rendered diagram
    Agent->>Sidecar: show_mermaid("arch", improved_spec)
    Note over App: Same panel updates in place`,
  });
  console.error("✓ opened 'iteration-loop' (mermaid sequence)");

  // 4. A hand-drawn SVG illustration.
  await client.request({
    kind: "upsert", session: sessionId, name: "logo",
    content_type: "svg", form: "inline",
    body: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 200" width="320" height="200">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#4f46e5"/>
      <stop offset="1" stop-color="#06b6d4"/>
    </linearGradient>
  </defs>
  <rect x="10" y="10" width="300" height="180" rx="16" fill="url(#bg)"/>
  <g transform="translate(40,60)">
    <rect x="0" y="0" width="80" height="60" rx="6" fill="white" opacity="0.95"/>
    <rect x="6" y="6" width="68" height="6" rx="3" fill="#4f46e5" opacity="0.7"/>
    <rect x="6" y="18" width="50" height="4" rx="2" fill="#94a3b8"/>
    <rect x="6" y="26" width="40" height="4" rx="2" fill="#94a3b8"/>
    <rect x="6" y="34" width="55" height="4" rx="2" fill="#94a3b8"/>
  </g>
  <g transform="translate(150,40)">
    <circle cx="40" cy="40" r="38" fill="white" opacity="0.95"/>
    <text x="40" y="48" font-family="-apple-system, sans-serif" font-size="36" font-weight="700" text-anchor="middle" fill="#4f46e5">Q</text>
  </g>
  <text x="160" y="160" font-family="-apple-system, sans-serif" font-size="14" font-weight="600" text-anchor="middle" fill="white">QuickShow</text>
  <text x="160" y="178" font-family="-apple-system, sans-serif" font-size="10" text-anchor="middle" fill="white" opacity="0.85">render • see • iterate</text>
</svg>`,
  });
  console.error("✓ opened 'logo' (svg)");

  // 5. Show a previously-rendered PNG via show_image (uses the one we made earlier).
  // The path-form handler resolves ~ and absolute paths.
  await client.request({
    kind: "upsert", session: sessionId, name: "earlier-render",
    content_type: "image", form: "path",
    body: "/tmp/qs-phase1-render.png",
  }).catch(() => { /* fixture might not exist if /tmp was cleared */ });
  console.error("✓ opened 'earlier-render' (image)");

  // List what's open.
  const list = await client.request({ kind: "list", session: sessionId });
  const panels = (list as { result: Array<{ name: string; content_type: string }> }).result;
  console.error(`\nPanels open in this session:`);
  for (const p of panels) {
    console.error(`  • ${p.name} (${p.content_type})`);
  }

  client.close();
  console.error(`\n📌 HUD is on screen at top-right. Switch tabs with the strip,`);
  console.error(`   right-click any tab to promote / snapshot, ⇩ in title bar`);
  console.error(`   to save a PNG to ~/Downloads, × to close. Session stays open`);
  console.error(`   even after this script exits (sidecar disconnect is graceful).`);
}

main().catch((err) => {
  console.error(`demo failed: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
