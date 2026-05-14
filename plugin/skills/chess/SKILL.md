---
name: chess
description: Play a casual chess game with the user in a floating QuickShow HUD panel. The board is rendered via python-chess wrapped in a draggable HTML page; the user drags a piece onto a legal target square, the page validates locally against the embedded legal-moves map and emits `{type:"move", from, to}` as a `panel_event` only on a successful drop, Claude applies the move, plays a minimax-2 reply, and re-renders. Use when the user asks to play chess, wants a drag-driven demo of the QuickShow panel-event loop, or asks for a quick game.
---

A casual chess demo of the QuickShow `panel_event` channel. The user
plays White by default; Claude plays Black. Moves are submitted by
**dragging a piece** onto a legal destination square — the page
validates locally before emitting, so Claude only ever sees confirmed
moves.

Claude is not a strong chess engine — the bundled helper uses
depth-2 minimax with material-only evaluation. Strong players will
win easily. The point is the loop, not Stockfish.

## How the loop works

1. The agent renders the board via `chess_helper.py render-html`.
   That command embeds the side-to-move's **legal-moves map** into
   the page (`{"e2":["e3","e4"], ...}`).
2. The page's drag handler uses the map to validate drops locally:
   - Picking up a piece is only allowed if the from-square has
     legal moves (i.e. it's the side-to-move's piece with at least
     one legal destination).
   - During the drag, the origin square gets a yellow border and
     every legal target is marked (dot for empty squares, ring for
     captures).
   - Dropping onto a legal square commits the move visually,
     locks the board, and emits `{"type":"move","from":"e2","to":"e4"}`.
   - Dropping anywhere else (illegal square, same square, off the
     board) snaps the piece back and emits nothing.
3. The agent reacts to the `panel_event`, applies the move, plays a
   reply, and re-renders. The re-render replaces the DOM, unlocking
   the board for the next turn.

You never receive a "click" or a "selection" event — only completed
moves. The state machine is on the page.

## Setup (once per session)

1. **Decide who plays White.** Default: user is White. If the user
   asks Claude to go first, swap (Claude plays White, user plays
   Black). The board is always drawn with White on the bottom — if
   the user is Black, they'll be reading the board from the top.
2. **Bootstrap.** Get the starting FEN:

   ```sh
   plugin/skills/chess/chess_helper.py new
   ```

   Store the returned FEN. There is no per-click state to track —
   just the FEN.
3. **Render the board.**

   ```sh
   plugin/skills/chess/chess_helper.py render-html <FEN> --size 600
   ```

   Pipe into `show_html(name: "chess-board", content: <HTML>, width: 640)`.
4. **Arm panel events** once: `enable_panel_events()`. Start the
   `Monitor` it returns.
5. If Claude is White, **play the opening move first** (see "Claude's
   turn"). Otherwise, wait for the first `panel_event`.

## On every `panel_event` with `payload.type === "move"`

The payload shape is `{"type":"move","from":"<sq>","to":"<sq>"}`. The
move is already validated by the page — it WILL be legal in the
current FEN (modulo Claude having de-synced state, which shouldn't
happen).

1. **Apply the user's move:**

   ```sh
   plugin/skills/chess/chess_helper.py move <FEN> <from><to>
   ```

   This should always return `ok: true`. If it returns `ok: false`,
   something's out of sync — re-render the board from the current
   FEN to resync the page's legal-moves map, then wait for the next
   `panel_event`.
2. Update `FEN` to the helper's returned value.
3. **Check `status`**: if it's a terminal state (`checkmate`,
   `stalemate`, `insufficient_material`, `fifty_moves`,
   `threefold_repetition`), render the final board and handle the
   terminal (see "Terminal handling"). Don't play a reply.
4. **Otherwise, play Claude's reply** (next section).

### Promotion

The page emits `{from, to}` without a promotion field — for a pawn
reaching the back rank, `chess_helper.py move` defaults to **queen**
promotion. If the user has specified a different piece in chat
("promote to knight"), extend the UCI before calling: e.g.
`e7e8n`. Otherwise, queen.

## Claude's turn

Pick a reply:

```sh
plugin/skills/chess/chess_helper.py best <FEN>
```

Returns `{from, to, uci, san, fen, status}`. Default depth (2) is
fast and weak — fine for casual play. Use `--depth 3` for slower,
slightly better play.

Update `FEN` to the returned value. Re-render with the last-move
highlight:

```sh
plugin/skills/chess/chess_helper.py render-html <new-FEN> --size 600 \
  --last-move <uci>
```

`show_html(name: "chess-board", ...)` — same panel name, updates in
place. The re-render embeds the user's new legal-moves map; the
page's `locked` flag is reset because the DOM is replaced.

**Announce the move** in SAN (the `san` field) — one short line:
"Nf3." / "Bxc4." / "O-O." / "Check." Skip explanation unless the
move is genuinely interesting.

Then check `status` (terminal handling below).

## Terminal handling

After any move (user's or Claude's), the helper's `status` field
tells you the game state:

- `"ongoing"` → continue.
- `"check"` → note it ("Check.") but the game continues. The board
  renderer also draws a red ring around the king in check.
- `"checkmate"` → game over, whoever just moved won. Announce
  ("Checkmate. Good game." or "Got me — nice mate.") and offer a
  rematch.
- `"stalemate"` / `"insufficient_material"` / `"fifty_moves"` /
  `"threefold_repetition"` → game over, draw. Announce the specific
  reason and offer a rematch.

On rematch: `chess_helper.py new`, reset `FEN`, re-render with the
same panel name (`chess-board`).

## Tips for the drag loop

- **Castling:** the user drags the king two squares (e1→g1 short,
  e1→c1 long). The legal-moves map for the king includes these as
  valid destinations; the helper's `move` executes the rook move
  automatically. No separate rook drag needed.
- **En passant:** the legal-moves map for the capturing pawn
  includes the diagonal empty square as a target. The helper's
  `move` handles the captured-pawn removal.
- **Captures:** legal capture squares appear as yellow **rings**
  around the enemy piece during the drag (vs. filled dots for
  empty-square moves). Dropping onto the enemy piece executes the
  capture.
- **Off-board / illegal drops** snap back. Nothing emits. The user
  can try again immediately.
- **Pieces with no legal moves** (pinned, blocked, opponent's) can't
  be picked up — the page rejects the drag start silently.
- **Lock during round-trip:** after a legal drop, the page locks
  until Claude's re-render. The user can't move twice before
  Claude responds.
- **Draw mode steals pointer events.** If the user toggles markup
  draw mode (✏︎ in the title bar), the in-DOM canvas captures
  pointer input and dragging stops working until they leave draw
  mode. Same trade-off the markup loop already lives with.

## Etiquette

- **Keep responses short.** "Your move." / "Nf3." / "Check." /
  "Nice move." Don't lecture.
- **Don't narrate FEN updates** or helper invocations. Just render
  and move on.
- **Don't sandbag.** Play the move the helper gives you, even if
  it's bad. Minimax-2 is what it is.
- **Acknowledge a brilliant move** ("Nice — didn't see that.")
  without fishing for praise on your own moves.
- **On a rematch:** `chess_helper.py new`, same panel name.

## Limitations to be upfront about

- **Weak play.** Minimax-2 with material eval makes me a beatable
  opponent. That's intentional.
- **No clock.** Casual play, no time pressure.
- **No PGN export.** If the user wants the game record, you can
  reconstruct one from the SAN sequence you've been announcing.
- **Promotion default is queen.** Override via chat ("promote to
  knight") and extend the UCI yourself before calling `move`.
- **Board orientation fixed.** White is always on the bottom — if
  the user plays Black, they read the board from Black's side.
