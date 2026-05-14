---
name: tic-tac-toe
description: Play tic-tac-toe with the user in a floating QuickShow HUD panel. The board is rendered as a `show_html` page with clickable cells; clicking a cell calls `window.quickshow.emit({type:"move", cell: N})`, Claude reads the `panel_event` line off the session's events log, picks a reply, and re-renders the board. Use when the user asks to play tic-tac-toe, wants a click-driven demo of the QuickShow panel-event loop, or asks for a quick game.
---

A click-driven demo of the QuickShow `panel_event` channel.
The user plays X. Claude plays O. The board lives in a single HUD
panel that updates in place after each move.

## Setup (do this once at the start of the session)

1. Decide who goes first. Default: **the user is X and moves first.**
   If they ask Claude to go first, swap roles and start with O on
   cell 5 (center) — strong opening.
2. Arm the panel-event channel **once**:

   ```
   enable_panel_events()
   ```

   The response includes the `Monitor` command pointed at the
   session's `events.ndjson`. Start that Monitor as
   `persistent: true` so each click fires a notification.
3. Render the empty board (see "HTML starter" below):

   ```
   show_html(name: "ttt-board", content: <board HTML>, width: 600)
   ```

4. Wait. The first `panel_event` with `payload.type === "move"` is
   the user's first move.

## The turn loop

On every `panel_event` line whose `panel === "ttt-board"` and
`payload.type === "move"`:

1. **Read the cell.** `payload.cell` is an integer 1–9, row-major
   top-left to bottom-right. No PNG reading, no ambiguity — the
   page emitted exactly the cell number that was clicked.
2. **Validate.** Ignore (silently) any cell that's already played
   in your internal state. The HTML disables played cells locally,
   but a stale Monitor line shouldn't double-fire your logic.
3. **Record the move** in your internal board state.
4. **Check for a win or draw** *after the user's move*:
   - **Win lines:** rows (1-2-3, 4-5-6, 7-8-9), columns (1-4-7,
     2-5-8, 3-6-9), diagonals (1-5-9, 3-5-7).
   - **Draw:** all 9 cells filled, no win.
   - If terminal: re-render with the final state plus a result
     banner, announce it, offer a rematch (and on yes, re-render
     a fresh empty board and continue).
5. **Pick Claude's cell.** Use the heuristic in "Move selection"
   below.
6. **Re-render** the board with both moves marked, same
   `name: "ttt-board"`. The panel updates in place.
7. **Check for win or draw again** *after Claude's move*. Same
   terminal handling.
8. Wait for the next `panel_event`. Repeat.

## Board layout

Cells are numbered 1–9 row-major:

```
 1 | 2 | 3
---+---+---
 4 | 5 | 6
---+---+---
 7 | 8 | 9
```

Each empty cell shows its number faintly in the center (low-opacity
gray) so the user knows what they're clicking. Played cells show a
crisp X or O instead of the number.

## HTML starter

A 600×600 board with cells 200×200. The cell `<rect>` elements
sit *above* the grid lines so they receive clicks; the grid lines
are drawn with `pointer-events: none` so the click hits the cell
rect, not a line.

When Claude re-renders, inject the played-cells set into the page
so it can suppress further clicks on those cells *and* draw the
correct glyphs. The script reads `window.__ttt = {claude: [..], user: [..]}`.

```html
<!doctype html>
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
  .banner { fill: #a3c47a; font: 700 36px -apple-system, system-ui, sans-serif; }
</style></head>
<body>
<svg id="board" viewBox="0 0 600 600" width="600" height="600">
  <!-- played glyphs go here, before cells so cells still receive clicks -->
  <g id="glyphs"></g>

  <!-- 9 invisible cell rects — these capture clicks -->
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

  <!-- grid lines on top of cells, pointer-events: none so clicks pass through -->
  <g stroke="#a8a99e" stroke-width="4" stroke-linecap="round" style="pointer-events: none;">
    <line x1="200" y1="40"  x2="200" y2="560"/>
    <line x1="400" y1="40"  x2="400" y2="560"/>
    <line x1="40"  y1="200" x2="560" y2="200"/>
    <line x1="40"  y1="400" x2="560" y2="400"/>
  </g>

  <!-- cell number hints, also pointer-events: none -->
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

  <!-- optional result banner; populated by Claude's re-render at terminal -->
  <g id="banner"></g>
</svg>

<script>
  // Claude injects the played cells per render (see "Re-render
  // shape" below). Empty arrays for the first render.
  window.__ttt = window.__ttt || { user: [], claude: [] };

  // Cell center coords for drawing X/O glyphs.
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

  // Replay state from Claude on each render.
  for (const n of window.__ttt.user)   { drawX(n); hideHint(n); markPlayed(n); }
  for (const n of window.__ttt.claude) { drawO(n); hideHint(n); markPlayed(n); }

  // Click handler — fires on the cell rect.
  document.getElementById("cells").addEventListener("click", function (e) {
    const t = e.target;
    if (!(t instanceof Element) || !t.matches(".cell")) return;
    if (t.classList.contains("played")) return;
    const n = Number(t.dataset.cell);
    // Optimistic local update so the UI feels snappy while Claude
    // tails the events log and re-renders.
    drawX(n); hideHint(n); markPlayed(n);
    // Disable all cells until Claude re-renders, to prevent rapid-
    // fire double-clicks while we wait for the round trip.
    for (const r of document.querySelectorAll(".cell:not(.played)")) {
      r.classList.add("played");
    }
    window.quickshow.emit({ type: "move", cell: n });
  });
</script>
</body></html>
```

## Re-render shape

When Claude re-renders, inject `window.__ttt` with both arrays
filled in *before* the script runs. Easiest: prepend an inline
`<script>` block above the main `<script>` that sets the state:

```html
<script>window.__ttt = { user: [3, 5], claude: [1, 7] };</script>
```

Then ship the same HTML body as the initial render. The script
replays both arrays and renders the correct board.

At terminal positions (win/draw), also inject a banner:

```html
<svg>...
  <g id="banner"><text class="banner" x="300" y="300" text-anchor="middle">X wins!</text></g>
</svg>
```

Place it last so it overlays the grid. Skip the click handler for
terminal renders (or leave it; the cells are all `.played` anyway).

## Move selection

This is a fun demo, not a Minimax engine. A simple heuristic is
plenty:

1. **Win if you can.** If you have two-in-a-row with an empty
   third, take the third.
2. **Block if you must.** If the user has two-in-a-row with an
   empty third, take the third.
3. **Center.** Take cell 5 if it's free.
4. **Corner.** Take any free corner (1, 3, 7, 9).
5. **Edge.** Take any free edge (2, 4, 6, 8).

This makes Claude a competent opponent without making the game
unwinnable — the user can still beat you with a fork. That's fine.
The point is the loop, not the AI.

## Notes the agent should know

- **No PNG inspection.** This skill is pure `panel_event` — never
  `get_markup`, never `enable_markup_events`. The cell number
  arrives directly in `payload.cell`.
- **Optimistic update is harmless.** The page draws the user's X
  immediately on click; Claude's subsequent re-render replaces the
  whole DOM with the authoritative state. If they diverge (they
  shouldn't), the re-render wins.
- **One emit per click** — throttle is irrelevant here (a human
  can't click fast enough to overflow a 20/sec bucket). No need to
  handle `panel_event_dropped`.
- **Draw mode steals clicks.** If the user toggles markup draw
  mode (✏︎ in the title bar), the in-DOM canvas captures pointer
  events and the cells stop responding until they leave draw mode.
  Don't bother working around it; the game isn't useful in draw
  mode anyway. Just keep playing once they exit.
- **Same `name: "ttt-board"`** for every re-render — the panel
  updates in place. Different `name` would open a new tab and
  break the loop.

## Etiquette

- **Don't lecture or commentate** during play. Keep responses
  short — "Your move." / "Going middle." / "Nice fork!" / "Draw."
- **Don't narrate the HTML or the emit.** Just render and move on.
- **Don't expose your internal board state.** The panel is the
  source of truth the user sees.
- **Celebrate a user win** ("Got me — nice game"). Don't sandbag,
  don't gloat.
- **On a rematch** start fresh with cell numbers visible; don't
  carry residual marks. Re-render the empty board (`__ttt = {user:
  [], claude: []}`) and you're back in the loop.
