// Render a tic-tac-toe board state into the running QuickShow.
//
// Usage:
//   bun run src/cli/ttt-test-render.ts                    # empty board
//   bun run src/cli/ttt-test-render.ts --user 3 --claude 5
//   bun run src/cli/ttt-test-render.ts --banner "X wins!"

import { SocketClient, DEFAULT_SOCKET_PATH } from "../socket.ts";
import { helloHandshake } from "../handshake.ts";

function parseList(args: string[], flag: string): number[] {
  const i = args.indexOf(flag);
  if (i < 0 || i + 1 >= args.length) return [];
  return args[i + 1]!.split(",").map((s) => Number(s.trim())).filter((n) => n >= 1 && n <= 9);
}
function parseStr(args: string[], flag: string): string | undefined {
  const i = args.indexOf(flag);
  if (i < 0 || i + 1 >= args.length) return undefined;
  return args[i + 1];
}

function html(user: number[], claude: number[], banner?: string): string {
  const bannerSvg = banner
    ? `<g id="banner"><text class="banner" x="300" y="300" text-anchor="middle" dominant-baseline="middle">${banner}</text></g>`
    : `<g id="banner"></g>`;
  return `<!doctype html>
<html><head><meta charset="utf-8"><style>
  :root { color-scheme: dark; }
  html, body { margin: 0; padding: 0; background: #1c1c1c; }
  body { display: flex; align-items: center; justify-content: center; min-height: 600px; }
  svg { display: block; }
  .cell { fill: transparent; cursor: pointer; transition: fill 80ms ease; }
  .cell.played { cursor: default; }
  .cell:not(.played):hover { fill: rgba(255,255,255,0.06); }
  .hint { fill: #4a4a4a; font: 28px -apple-system, system-ui, sans-serif; }
  .x, .o { stroke-linecap: round; fill: none; }
  .x { stroke: #e5e3da; stroke-width: 10; }
  .o { stroke: #d8392c; stroke-width: 10; }
  .banner { fill: #a3c47a; font: 700 64px -apple-system, system-ui, sans-serif; paint-order: stroke; stroke: #1c1c1c; stroke-width: 8; }
</style></head>
<body>
<script>window.__ttt = ${JSON.stringify({ user, claude })};</script>
<svg id="board" viewBox="0 0 600 600" width="600" height="600">
  <g id="glyphs"></g>
  <g id="cells">
    <rect class="cell" data-cell="1" x="0"   y="0"   width="200" height="200"/>
    <rect class="cell" data-cell="2" x="200" y="0"   width="200" height="200"/>
    <rect class="cell" data-cell="3" x="400" y="0"   width="200" height="200"/>
    <rect class="cell" data-cell="4" x="0"   y="200" width="200" height="200"/>
    <rect class="cell" data-cell="5" x="200" y="200" width="200" height="200"/>
    <rect class="cell" data-cell="6" x="400" y="200" width="200" height="200"/>
    <rect class="cell" data-cell="7" x="0"   y="400" width="200" height="200"/>
    <rect class="cell" data-cell="8" x="200" y="400" width="200" height="200"/>
    <rect class="cell" data-cell="9" x="400" y="400" width="200" height="200"/>
  </g>
  <g stroke="#a8a99e" stroke-width="4" stroke-linecap="round" style="pointer-events: none;">
    <line x1="200" y1="40"  x2="200" y2="560"/>
    <line x1="400" y1="40"  x2="400" y2="560"/>
    <line x1="40"  y1="200" x2="560" y2="200"/>
    <line x1="40"  y1="400" x2="560" y2="400"/>
  </g>
  <g id="hints" text-anchor="middle" dominant-baseline="middle" style="pointer-events: none;">
    <text class="hint" data-hint="1" x="100" y="100">1</text>
    <text class="hint" data-hint="2" x="300" y="100">2</text>
    <text class="hint" data-hint="3" x="500" y="100">3</text>
    <text class="hint" data-hint="4" x="100" y="300">4</text>
    <text class="hint" data-hint="5" x="300" y="300">5</text>
    <text class="hint" data-hint="6" x="500" y="300">6</text>
    <text class="hint" data-hint="7" x="100" y="500">7</text>
    <text class="hint" data-hint="8" x="300" y="500">8</text>
    <text class="hint" data-hint="9" x="500" y="500">9</text>
  </g>
  ${bannerSvg}
</svg>
<script>
  const C = {
    1:[100,100], 2:[300,100], 3:[500,100],
    4:[100,300], 5:[300,300], 6:[500,300],
    7:[100,500], 8:[300,500], 9:[500,500],
  };
  function drawX(n) {
    const [cx, cy] = C[n];
    const ns = "http://www.w3.org/2000/svg";
    const g = document.getElementById("glyphs");
    for (const [dx1, dy1, dx2, dy2] of [[-55,-55,55,55],[55,-55,-55,55]]) {
      const l = document.createElementNS(ns, "line");
      l.setAttribute("class", "x");
      l.setAttribute("x1", cx + dx1); l.setAttribute("y1", cy + dy1);
      l.setAttribute("x2", cx + dx2); l.setAttribute("y2", cy + dy2);
      g.appendChild(l);
    }
  }
  function drawO(n) {
    const [cx, cy] = C[n];
    const ns = "http://www.w3.org/2000/svg";
    const c = document.createElementNS(ns, "circle");
    c.setAttribute("class", "o");
    c.setAttribute("cx", cx); c.setAttribute("cy", cy); c.setAttribute("r", 60);
    document.getElementById("glyphs").appendChild(c);
  }
  function hideHint(n) {
    const t = document.querySelector('[data-hint="' + n + '"]');
    if (t) t.style.display = "none";
  }
  function markPlayed(n) {
    const r = document.querySelector('.cell[data-cell="' + n + '"]');
    if (r) r.classList.add("played");
  }
  for (const n of window.__ttt.user)   { drawX(n); hideHint(n); markPlayed(n); }
  for (const n of window.__ttt.claude) { drawO(n); hideHint(n); markPlayed(n); }
  document.getElementById("cells").addEventListener("click", function (e) {
    const t = e.target;
    if (!(t instanceof Element) || !t.matches(".cell")) return;
    if (t.classList.contains("played")) return;
    const n = Number(t.dataset.cell);
    drawX(n); hideHint(n); markPlayed(n);
    for (const r of document.querySelectorAll(".cell:not(.played)")) {
      r.classList.add("played");
    }
    window.quickshow.emit({ type: "move", cell: n });
  });
</script>
</body></html>`;
}

async function main(): Promise<number> {
  const args = process.argv.slice(2);
  const user = parseList(args, "--user");
  const claude = parseList(args, "--claude");
  const banner = parseStr(args, "--banner");
  const claim = process.env.QUICKSHOW_TTT_SESSION ?? "ttt-live";
  const panel = "ttt-board";
  const socketPath = process.env.QUICKSHOW_SOCKET_PATH ?? DEFAULT_SOCKET_PATH;

  const c = new SocketClient(socketPath);
  await c.connect(2000);

  const session = await helloHandshake(c, claim, "ttt-test-render");

  const armed = await c.request({
    kind: "set_session_flag", session, key: "panel_events_armed", value: true,
  });
  if (armed.kind !== "ok") { console.error("arm failed:", armed); return 1; }

  const upsert = await c.request({
    kind: "upsert", session, name: panel,
    content_type: "html", form: "inline",
    body: html(user, claude, banner), width: 640,
  });
  if (upsert.kind !== "ok") {
    console.error("upsert failed:", JSON.stringify(upsert));
    return 1;
  }
  const r = upsert.result as { width: number; height: number };
  console.error(`ttt-test-render: rendered ${r.width}×${r.height} (user=[${user}] claude=[${claude}]${banner ? ` banner="${banner}"` : ""})`);

  c.close();
  return 0;
}

main().then((code) => process.exit(code)).catch((err) => {
  console.error("ttt-test-render: error:", err instanceof Error ? err.message : String(err));
  process.exit(2);
});
