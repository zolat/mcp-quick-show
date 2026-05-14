---
name: chess
description: Play a casual chess game with the user in a floating QuickShow HUD panel. The board is rendered via python-chess wrapped in a draggable HTML page; the user drags a piece onto a legal target square and the page emits `{type:"move", from, to}` as a `panel_event`. Claude plays both sides using its own chess knowledge — the bundled `chess_helper.py` is the ground-truth keeper (validates moves, lists legal moves, renders the board) but does not pick moves. Use when the user asks to play chess, wants a drag-driven demo of the QuickShow panel-event loop, or asks for a quick game.
---

A casual chess demo of the QuickShow `panel_event` channel. The user
plays White by default; Claude plays Black. Moves are submitted by
**dragging a piece** onto a legal destination square — the page
validates locally before emitting, so Claude only ever sees confirmed
moves.

**Claude plays its own moves.** There is no engine. The bundled
`chess_helper.py` is the ground-truth keeper: it tracks the position,
validates moves, lists legal moves, and renders the board. The
move-selection brain is yours — pick moves based on opening
principles, tactics, and the position on the board, the same way you
would in any chess conversation.

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
   - Dropping anywhere else snaps the piece back and emits nothing.
3. Claude reacts to the `panel_event`, applies the user's move,
   thinks about a reply, plays it, and re-renders. The re-render
   replaces the DOM and unlocks the board for the next turn.

You never receive a "click" or a "selection" event — only completed
moves. The state machine is on the page.

## Setup (once per session)

1. **Decide who plays White.** Default: user is White. If they
   ask Claude to go first, swap. Board is always drawn with White
   on the bottom — if the user plays Black, they read the board
   from the top.
2. **Bootstrap.** Get the starting FEN:

   ```sh
   plugin/skills/chess/chess_helper.py new
   ```

   Store the returned FEN. That's the only state to track.
3. **Render the board.**

   ```sh
   plugin/skills/chess/chess_helper.py render-html <FEN> --size 600
   ```

   Pipe into `show_html(name: "chess-board", content: <HTML>, width: 640)`.
4. **Arm panel events** once: `enable_panel_events()`. Start the
   `Monitor` it returns.
5. If Claude is White, **play the opening move first** (see
   "Claude's turn"). Otherwise, wait for the first `panel_event`.

## On every `panel_event` with `payload.type === "move"`

Payload: `{"type":"move","from":"<sq>","to":"<sq>"}`. The move is
already validated by the page; it WILL be legal in the current FEN.

1. **Apply the user's move:**

   ```sh
   plugin/skills/chess/chess_helper.py move <FEN> <from><to>
   ```

   Update `FEN` to the helper's returned value.
2. **Check `status`** for terminal states (see "Terminal handling").
   If terminal, render the final board and stop — don't play a reply.
3. **Otherwise, play Claude's reply** (next section).

### Promotion (user's turn)

The page emits `{from, to}` without a promotion field — for a pawn
reaching the back rank, `chess_helper.py move` defaults to **queen**
promotion. If the user has specified a different piece in chat
("promote to knight"), extend the UCI before calling: `e7e8n` etc.

## Claude's turn — pick a move yourself

You play. The helper exists to validate, not to suggest.

1. **Think about the position.** You have the FEN, the user's last
   move, and the rendered board. Apply normal chess judgment:
   - Opening: develop pieces, control the centre, get the king
     safe. Don't move the same piece twice in the opening unless
     there's a reason. Connect the rooks.
   - Middlegame: look for tactics (forks, pins, skewers, double
     attacks, hanging pieces, weak king cover). Improve worst
     piece. Trade when ahead, complicate when behind.
   - Endgame: activate the king, push passed pawns, look for
     opposition + simple mating patterns.
   - **Don't shuffle.** If you can't find a strong move, play a
     sensible developing or improving move — don't move a rook
     out and back. Casual chess, not engine chess.
2. **If you want to enumerate**, ask the helper for every legal
   move (or just from one square):

   ```sh
   plugin/skills/chess/chess_helper.py legal <FEN>
   plugin/skills/chess/chess_helper.py legal <FEN> --from e4
   ```

   Useful when you want to scan for tactical targets or quickly
   confirm whether a move is available.
3. **Apply your move** via the helper. UCI notation:

   ```sh
   plugin/skills/chess/chess_helper.py move <FEN> <uci>
   ```

   - `ok: true` → update `FEN`, continue.
   - `ok: false, error: "illegal move"` → you picked something
     illegal. Re-think and resubmit. (Treat this as a sanity check
     — illegal-move rate should be near zero.)
   - Promotion: omit suffix for queen, append `n`/`r`/`b` for
     other pieces.
4. **Re-render** with the last-move highlight:

   ```sh
   plugin/skills/chess/chess_helper.py render-html <new-FEN> --size 600 \
     --last-move <your-uci>
   ```

   `show_html(name: "chess-board", ...)` — same panel name, panel
   updates in place. The re-render embeds the user's new
   legal-moves map; the page's lock clears because the DOM is
   replaced.
5. **Announce the move** in SAN (the `san` field from the `move`
   response) — one short line: "Nf3." / "Bxc4." / "O-O." /
   "Check." Skip explanation unless the move is genuinely
   interesting.
6. Check `status` (terminal handling below).

## Terminal handling

After any move, `status` tells you the game state:

- `"ongoing"` → continue.
- `"check"` → the side to move is in check. Note it ("Check.") but
  the game continues. The renderer draws a red ring around the
  king in check.
- `"checkmate"` → game over, whoever just moved won. Announce
  ("Checkmate. Good game." or "Got me — nice mate.") and offer a
  rematch.
- `"stalemate"` / `"insufficient_material"` / `"fifty_moves"` /
  `"threefold_repetition"` → game over, draw. Announce the
  specific reason and offer a rematch.

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
- **Pieces with no legal moves** (pinned, blocked, opponent's)
  can't be picked up — the page rejects the drag start silently.
- **Lock during round-trip:** after a legal drop, the page locks
  until Claude's re-render. The user can't move twice before
  Claude responds.
- **Draw mode steals pointer events.** If the user toggles markup
  draw mode (✏︎ in the title bar), the in-DOM canvas captures
  pointer input and dragging stops working until they leave draw
  mode.

## Etiquette

- **Keep responses short.** "Your move." / "Nf3." / "Check." /
  "Nice move." Don't lecture.
- **Don't narrate FEN updates** or helper invocations. Just render
  and move on.
- **Acknowledge a strong move from the user** ("Nice — didn't see
  that."). Don't fish for praise on your own moves.
- **Play your best.** Don't sandbag. If the user beats you, they
  beat you. If you find a tactic, take it.
- **On a rematch:** `chess_helper.py new`, reset `FEN`, same panel
  name.

## Limitations

- **No clock.** Casual play, no time pressure.
- **No PGN export** built in. If asked, reconstruct one from the
  SAN sequence you've been announcing.
- **Promotion default is queen.** Override with `n`/`r`/`b`
  suffix.
- **Board orientation fixed** — White on the bottom. If the user
  plays Black, they read it from the top.
- **Tactical blind spots.** You're an LLM playing chess from a
  FEN; deep tactical sequences (3+ move forced wins) can slip
  past. That's fine — it's casual chess. Use `legal` if you want
  to scan harder before committing to a sharp move.
