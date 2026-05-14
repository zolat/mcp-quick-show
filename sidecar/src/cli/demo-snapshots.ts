// Pull a fresh snapshot of each demo panel via `inspect` and save to
// /tmp/qs-demo-*.png for inline viewing.

import * as fs from "node:fs";
import { SocketClient, DEFAULT_SOCKET_PATH } from "../socket.ts";
import { helloHandshake } from "../handshake.ts";

const SOCK = process.env.QUICKSHOW_SOCKET_PATH ?? DEFAULT_SOCKET_PATH;

async function main() {
  // We need to know the session id from the demo run. Easier: just
  // open a new session, re-render the same content, and snapshot.
  // But the existing session has panels we want to capture. The
  // session id was random in demo.ts — we can't recover it.
  //
  // Simpler: do `list` against every session we know about by trying
  // the most-recently-created session UUID file under
  // ~/Library/Application Support/QuickShow/sessions/. But our
  // `demo.ts` used randomUUID() (not getOrCreateSessionId), so it's
  // not on disk.
  //
  // Simplest of all: open a new session, re-render the same content,
  // and snapshot via inspect. We render once + immediately inspect.

  const candidate = `demo-snapshots-${process.pid}`;
  const client = new SocketClient(SOCK);
  await client.connect(2000);
  const sessionId = await helloHandshake(client, candidate, "demo-snapshots");

  const cases: Array<{ name: string; type: string; body: string; form: "inline" | "path" }> = [
    {
      name: "report",
      type: "markdown",
      form: "inline",
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
output without asking the user.

> Update the same panel name in place; pick a new name to open a tab.`,
    },
    {
      name: "arch",
      type: "mermaid",
      form: "inline",
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
    },
    {
      name: "iteration-loop",
      type: "mermaid",
      form: "inline",
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
    },
    {
      name: "logo",
      type: "svg",
      form: "inline",
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
    },
  ];

  for (const c of cases) {
    const resp = await client.request({
      kind: "upsert", session: sessionId, name: c.name,
      content_type: c.type, form: c.form, body: c.body,
    });
    if (resp.kind !== "ok") {
      console.error(`✗ ${c.name}: ${resp.kind}`, resp);
      continue;
    }
    const result = (resp as { result: { width: number; height: number; screenshot_b64?: string } }).result;
    if (result.screenshot_b64) {
      const out = `/tmp/qs-demo-${c.name}.png`;
      fs.writeFileSync(out, Buffer.from(result.screenshot_b64, "base64"));
      console.error(`✓ ${c.name}: ${result.width}×${result.height} → ${out}`);
    }
  }

  client.close();
}

main().catch((err) => {
  console.error(`failed: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
