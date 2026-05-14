---
name: chess
description: Play a casual chess game with the user in a floating QuickShow HUD panel. The board is rendered via python-chess wrapped in a clickable HTML page; the user clicks the from-square then the to-square, each click is emitted as a `panel_event`, Claude reads the event, validates the move with the bundled chess_helper.py, plays a response, and re-renders. Use when the user asks to play chess, wants a click-driven demo of the QuickShow panel-event loop, or asks for a quick game.
---

A casual chess demo of the QuickShow `panel_event` channel. The user
plays White by default; Claude plays Black. Moves are submitted as
**two clicks**: first the piece, then the destination. The selected
square highlights yellow and legal targets appear as dots (or rings
on capture squares).

Claude is not a strong chess engine — the bundled helper uses
depth-2 minimax with material-only evaluation. Strong players will
win easily. The point is the loop, not Stockfish.

## Setup (once per session)

1. **Decide who plays White.** Default: user is White. If the user
   asks Claude to go first, swap (Claude plays White, user plays
   Black). The board is always drawn with White on the bottom — if
   the user is Black, they're playing from the top.
2. **Bootstrap the game state.** Get the starting FEN:

   ```sh
   plugin/skills/chess/chess_helper.py new
   ```

   Store the returned FEN. Initialize `selected = null` in your
   working memory.
3. **Render the board.** Pipe the helper's HTML output into `show_html`:

   ```sh
   plugin/skills/chess/chess_helper.py render-html <FEN> --size 600
   ```

   Then `show_html(name: "chess-board", content: <HTML>, width: 640)`.
4. **Arm panel events.** Call `enable_panel_events()` once. The
   response includes the Monitor command — start it.
5. If Claude is White, **make the opening move first** (see "Claude's
   turn" below). Otherwise, wait for the first `panel_event`.

## State you maintain

- `FEN` — current position (returned by the helper after each move).
- `selected` — either a square name (e.g. `"e2"`) or `null`. Tracks
  whether the user is in the middle of a move (first click landed,
  waiting for second). Re-render with `--selected <sq>
  --legal-targets <csv>` whenever this is non-null so the user sees
  what's picked.

## On every `panel_event` with `payload.type === "click"`

The page emits `{"type":"click","square":"e2"}` — that's it. The
page doesn't know chess rules; you do all the routing. Logic:

### Case A — `selected == null` (no piece picked yet)

The user is choosing what to move. Ask the helper for that square's
legal moves:

```sh
plugin/skills/chess/chess_helper.py legal <FEN> --from <clicked>
```

- **Empty moves list** (empty square, opponent piece, or pinned
  piece with no legal moves): no-op. Don't re-render — the page's
  optimistic yellow flash already gave them feedback, and a re-render
  just to do nothing wastes a round trip.
- **Non-empty moves list**: set `selected = clicked`. Build the
  legal-targets CSV from the `to` field of each move. Re-render:

  ```sh
  plugin/skills/chess/chess_helper.py render-html <FEN> --size 600 \
    --selected <clicked> --legal-targets <to1,to2,...>
  ```

  Done — wait for the next click.

### Case B — `selected != null` (a piece is picked)

The user is choosing where it goes. Three sub-cases:

1. **Click on the same square as `selected`** → user wants to
   deselect. Set `selected = null`. Re-render plain (no `--selected`,
   no `--legal-targets`).
2. **Try the move** as UCI `<selected><clicked>`:

   ```sh
   plugin/skills/chess/chess_helper.py move <FEN> <selected><clicked>
   ```

   - **`ok: true`** → user's move is applied:
     - Update `FEN` to the returned value.
     - Set `selected = null`.
     - If the helper says `status` is `checkmate` (rare from one
       user move — would mean the user delivered mate) or any
       draw status, render the final board and handle the terminal
       (see "Terminal handling" below).
     - Otherwise, **Claude plays a reply** (see "Claude's turn").
   - **`ok: false, error: "illegal move"`** → ambiguous; the click
     might be a *reselection*. Ask the helper for the clicked
     square's legal moves:

     ```sh
     plugin/skills/chess/chess_helper.py legal <FEN> --from <clicked>
     ```

     - Empty list: not a legal source. Set `selected = null` and
       re-render plain. (The previously-selected piece can't move
       there, and the new square has no moves of its own.)
     - Non-empty list: the user is switching their pick. Set
       `selected = clicked`. Re-render with the new selection +
       legal targets.

### Promotion (User's turn)

If the user's pawn reaches the back rank (rank 8 for White, rank 1
for Black) and they didn't specify a promotion piece in chat,
default to queen — `chess_helper.py move` does this automatically
when the UCI string omits the suffix. If they want a knight/rook/
bishop, accept it in chat (`"promote to knight"`) and pass the
extended UCI yourself: `<selected><clicked>n` etc.

## Claude's turn

After applying the user's move (and any terminal-checks land on
"ongoing"), pick a reply:

```sh
plugin/skills/chess/chess_helper.py best <FEN>
```

Returns `{from, to, uci, san, fen, status}`. The default depth (2)
is fast and weak — fine for casual play. Use `--depth 3` if you
want slower, slightly better play.

Update `FEN` to the returned value, then re-render with the
last-move highlight:

```sh
plugin/skills/chess/chess_helper.py render-html <new-FEN> --size 600 \
  --last-move <uci>
```

`show_html(name: "chess-board", ...)` — same name, panel updates in
place.

**Announce the move** in standard algebraic (the `san` field) —
one short line: "Nf3." / "Bxc4." / "O-O." / "Check." Skip
explanation unless the move is interesting.

Then check `status`:

## Terminal handling

After any move (user's or Claude's), the helper's `status` field
tells you the game state:

- `"ongoing"` → continue.
- `"check"` → note it in your one-line announcement ("Check.") but
  the game continues. The board renderer also draws a red ring
  around the king in check.
- `"checkmate"` → game over. Whoever just moved won. Announce
  ("Checkmate. Good game." or "Got me — nice mate.") and offer a
  rematch.
- `"stalemate"` / `"insufficient_material"` / `"fifty_moves"` /
  `"threefold_repetition"` → game over, draw. Announce the specific
  reason and offer a rematch.

On rematch, run `chess_helper.py new`, reset `FEN` and `selected =
null`, re-render with the same panel name.

## Tips for the click loop

- **Castling:** the user clicks the king (e1), then the king's
  destination two squares away (g1 short, c1 long). The helper
  accepts the king move and executes the castle automatically. No
  separate rook click needed.
- **En passant:** click the pawn, then the diagonal empty target
  square. The helper handles the captured-pawn removal.
- **Captures:** just click the enemy piece's square as the
  destination — it'll show up as a yellow capture *ring* (vs. the
  filled dot for empty-square moves) in the legal-targets render.
- **Two clicks in fast succession:** the throttle is 20/sec/panel,
  so a human click pace can't overflow. If the user double-clicks
  the same square accidentally, the second click is a deselect.
- **Click on the opponent's piece without a selection:** opponent
  pieces have no legal moves for the user, so this is a no-op (the
  helper's `legal --from` will return an empty list).
- **Draw mode steals clicks.** If the user toggles markup draw mode
  (✏︎ in the title bar), the in-DOM canvas captures pointer events
  and the board stops responding until they leave draw mode. Just
  resume play once they exit.

## Etiquette

- **Keep responses short.** "Your move." / "Nf3." / "Check." /
  "That's not legal — pick another square or click e2 again to
  deselect." Don't lecture.
- **Don't narrate FEN updates** or the helper invocations. Just
  render and move on.
- **Don't sandbag.** Play the move the helper gives you, even if
  it's bad. Don't pretend to think hard; minimax-2 is what it is.
- **On a brilliant move from the user**, acknowledge it: "Nice —
  didn't see that." Don't fish for praise on your own moves.
- **On a rematch:** `chess_helper.py new`, reset state, same panel
  name (`chess-board`) so the panel updates in place.

## Limitations to be upfront about

- **Weak play.** Minimax-2 with material eval makes me a beatable
  opponent. That's intentional.
- **No clock.** Casual play, no time pressure.
- **No PGN export.** If the user wants the game record, you can
  offer to construct one from the SAN sequence you've been
  announcing.
- **Promotion default is queen.** Override via chat ("promote to
  knight") or by extending the UCI string yourself before calling
  `move`.
- **Board orientation fixed.** White is always on the bottom — if
  the user plays Black, they read the board from Black's side.
