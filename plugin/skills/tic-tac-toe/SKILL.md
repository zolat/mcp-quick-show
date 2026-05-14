---
name: tic-tac-toe
description: Play tic-tac-toe with the user in a floating QuickShow HUD panel. The board is rendered as an SVG; the user marks their move by drawing on the panel and pressing Send; Claude reads the annotated PNG, identifies the cell, plays back, and re-renders. Use when the user asks to play tic-tac-toe, wants a demo of the QuickShow markup feedback loop, or asks for a quick game.
---

A fun, self-contained demo of the QuickShow markup feedback loop.
The user plays X. Claude plays O. The board lives in a single HUD
panel that updates in place after each move.

## Setup (do this once at the start of the session)

1. Decide who goes first. Default: **the user is X and moves first.**
   If they ask Claude to go first, swap roles and start with O on
   cell 5 (center) — strong opening.
2. Render the empty board:

   ```
   show_svg(name: "ttt-board", content: <empty board SVG>, width: 600)
   ```

3. Arm markup events **once**:

   ```
   enable_markup_events()
   ```

   The response includes the `Monitor` command to start. Start it.
4. Wait. The first `markup_sent` event is the user's first move.

## The turn loop

On every `markup_sent`:

1. `get_markup(artifact_id)` — fetch the annotated PNG.
2. **Identify the cell.** The user has drawn an X (or any mark) in
   one cell of the 3×3 grid. The cells are large and the grid is
   regular — look at where the red strokes' centroid sits relative
   to the grid lines and read off the cell number (1–9 in row-major
   order, top-left to bottom-right). If the mark is *genuinely
   ambiguous* (straddling two cells, off-board, no marks at all),
   ask the user to clarify rather than guess.
3. **Record the move.** Update your internal board state.
4. **Check for a win or draw** *after the user's move*:
   - **Win lines:** rows (1-2-3, 4-5-6, 7-8-9), columns (1-4-7,
     2-5-8, 3-6-9), diagonals (1-5-9, 3-5-7).
   - **Draw:** all 9 cells filled, no win.
   - If terminal: re-render with the final state plus a result
     banner ("X wins!" / "Draw."), announce it, offer a rematch
     (and on yes, re-render an empty board and continue).
5. **Pick Claude's cell.** Use a small bit of strategy — see "Move
   selection" below.
6. **Re-render** the board with both moves marked, same `name:
   "ttt-board"`. The panel updates in place.
7. **Check for win or draw again** *after Claude's move*. Same
   terminal handling.
8. Wait for the next `markup_sent`. Repeat.

## Board layout

Cells are numbered 1–9 row-major:

```
 1 | 2 | 3
---+---+---
 4 | 5 | 6
---+---+---
 7 | 8 | 9
```

Render the SVG so each empty cell shows its number faintly in the
center (low-opacity gray) — that way the user knows where to draw,
and you have a clear reference for cell identification when you
read the markup back. Played cells show a crisp X or O instead of
the number.

## SVG starter

A 600×600 board with cells ~200×200. Adapt freely — the only
constraint is that the cells are visually distinct so the cell-
identification step is robust.

```html
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 600">
  <rect width="600" height="600" fill="#fafafa"/>
  <!-- grid lines -->
  <g stroke="#1a1a1a" stroke-width="6" stroke-linecap="round">
    <line x1="200" y1="40"  x2="200" y2="560"/>
    <line x1="400" y1="40"  x2="400" y2="560"/>
    <line x1="40"  y1="200" x2="560" y2="200"/>
    <line x1="40"  y1="400" x2="560" y2="400"/>
  </g>
  <!-- cell numbers (faded) — drop for played cells -->
  <g font-family="-apple-system, Helvetica" font-size="28"
     fill="#bbb" text-anchor="middle" dominant-baseline="middle">
    <text x="100" y="100">1</text>
    <text x="300" y="100">2</text>
    <text x="500" y="100">3</text>
    <text x="100" y="300">4</text>
    <text x="300" y="300">5</text>
    <text x="500" y="300">6</text>
    <text x="100" y="500">7</text>
    <text x="300" y="500">8</text>
    <text x="500" y="500">9</text>
  </g>
  <!-- played moves: draw thick X (user) or O (Claude) over the cell
       in place of its number -->
</svg>
```

For an X glyph, draw two diagonal strokes inside the cell box. For
an O, draw a circle centered in the cell. Use distinct colors
(e.g. user X in dark ink `#1a1a1a`; Claude O in a strong accent
like `#d83a2c`) — makes the board readable at a glance and easy to
talk about.

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

## Etiquette

- **Don't lecture or commentate** during play. Keep responses short
  — "Your move." / "Ok — going middle." / "Nice fork!" / "Draw."
- **Don't narrate the SVG generation.** Just render and move on.
- **Don't expose your internal board state.** The panel is the
  source of truth the user sees.
- **Celebrate a user win** ("Got me — nice game"). Don't sandbag,
  don't gloat.
- **On a rematch** start fresh with cell numbers visible; don't
  carry residual marks.
