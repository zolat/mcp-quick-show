// Interactive tear-out test setup.
// Opens 4 panels in one session with short, distinct names so the
// tab strip is easy to grab. Each panel is visually distinct (color
// + heading) so you can spot which one you dragged.

import { randomUUID } from "node:crypto";
import { SocketClient, DEFAULT_SOCKET_PATH } from "../socket.ts";
import { helloHandshake } from "../handshake.ts";

const SOCK = process.env.QUICKSHOW_SOCKET_PATH ?? DEFAULT_SOCKET_PATH;

async function main() {
  const client = new SocketClient(SOCK);
  await client.connect(2000);
  const sessionId = await helloHandshake(client, randomUUID(), "tearout-test");

  const cases: Array<{ name: string; color: string; emoji: string; n: number }> = [
    { name: "one",   color: "#ef4444", emoji: "🟥", n: 1 },
    { name: "two",   color: "#22c55e", emoji: "🟩", n: 2 },
    { name: "three", color: "#3b82f6", emoji: "🟦", n: 3 },
    { name: "four",  color: "#a855f7", emoji: "🟪", n: 4 },
  ];

  for (const c of cases) {
    await client.request({
      kind: "upsert", session: sessionId, name: c.name,
      content_type: "markdown", form: "inline",
      body: `# ${c.emoji} Panel ${c.n}: "${c.name}"

This is panel **${c.n}** of 4. The tab strip up top has all four pills.

## Try this

1. **Hover** the tab strip near the top of the HUD — it fades to 100% alpha.
2. **Mouse-down** on this pill (\`${c.name}\`).
3. **Drag downward 12+ pt** — a new HUD will pop out under the cursor.
4. **Keep dragging** — the new HUD follows the cursor.
5. **Release** anywhere — the new HUD lands there.

## After tear-out

- **Right-click** the new HUD's background → set **opacity 50 %** → only that HUD fades.
- **Right-click** the torn pill (now the only one) → **Promote to standard window** → standard NSWindow with title bar + Cmd-Tab.
- **Drag-back is NOT supported** in v0.1 — torn HUDs are independent.

## Visual fingerprint

<div style="background:${c.color};color:white;padding:8px;border-radius:6px;text-align:center;font-weight:600;font-size:13px;">
  panel "${c.name}" — color ${c.color}
</div>
`,
    });
    console.error(`✓ opened '${c.name}'`);
  }

  client.close();
  console.error(`\n📌 4 panels in one HUD. Pick a middle pill (e.g. 'two' or 'three')`);
  console.error(`   and drag it 12+pt downward. A new HUD will follow your cursor.`);
}

main().catch((err) => {
  console.error(`failed: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
