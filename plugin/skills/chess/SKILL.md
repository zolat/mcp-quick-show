---
name: chess
description: Play a casual chess game with the user in a floating QuickShow HUD panel. The board is rendered via python-chess; the user marks their move by drawing an arrow from the origin square to the destination square and pressing Send; Claude reads the arrow endpoints, validates the move with the bundled chess_helper.py, plays a response, and re-renders. Use when the user asks to play chess, wants a chess demo of the QuickShow markup feedback loop, or asks for a quick game.
---

A casual chess demo of the QuickShow markup feedback loop. The user plays White by default; Claude plays Black. Moves are submitted by drawing an arrow on the board from the origin square to the destination square.

Claude is not a strong chess engine — the bundled helper uses depth-2 minimax with material-only evaluation. Strong players will win easily. The point is the loop, not Stockfish.

## Setup (once per session)

1. **Decide who plays White.** Default: user is White. If the user asks Claude to go first, swap (Claude plays White, user plays Black).
2. **Bootstrap the game state.** Get the starting FEN:

   ```sh
   plugin/skills/chess/chess_helper.py new
   ```

   Store the returned FEN in your working memory — you'll thread it through every subsequent helper call.
3. **Render the board.** Generate the board SVG from the FEN and show it:

   ```sh
   plugin/skills/chess/chess_helper.py render <FEN> --size 600
   ```

   Pipe the SVG into `show_svg(name: "chess-board", content: <svg>, width: 600)`.
4. **Arm markup events.** Call `enable_markup_events()` once. The response includes the Monitor command — start it.
5. If Claude is White, **make the opening move first** (see "Claude's turn" below). Otherwise, wait for the first `markup_sent`.

## User's turn — reading an arrow

When you get a `markup_sent` event:

1. `get_markup(artifact_id)` — fetch the annotated PNG.
2. **Identify the from-square and to-square** from the arrow.
   - The python-chess board includes algebraic coordinates (a–h along the bottom, 1–8 along the side). Each square is roughly the same size.
   - The arrow is a red stroke with a clear head and tail. The **tail** (where the arrow starts, often where the stroke begins) is the origin square; the **head** (where it points, usually where the stroke ends) is the destination.
   - If the user drew something that doesn't look like an arrow (a circle, a scribble, multiple strokes), ask them to redraw rather than guess.
3. **Apply the move via the helper:**

   ```sh
   plugin/skills/chess/chess_helper.py move <FEN> <from><to>
   ```

   `<from><to>` is UCI notation, e.g. `e2e4`. For a pawn reaching the back rank, omit the promotion suffix to default to queen, or append a piece letter (`q`, `r`, `b`, `n`) — e.g. `e7e8r`.
4. **Handle the response:**
   - `ok: true` → update your FEN and proceed to Claude's turn.
   - `ok: false, error: "illegal move"` → tell the user "That's not legal — from `<from>` you can play to: `<legal_to_from_origin>`." Then wait for another `markup_sent`. Don't apply anything.
5. **Check for promotion:** if the user moved a pawn to rank 1/8 *and* didn't say what to promote to in chat, default to queen. If they want something else ("promote to knight"), pass `<from><to>n` instead.
6. **Check status:** if `status` is `checkmate`, the user just won — render the final board, congratulate them, offer rematch. If `stalemate` / `insufficient_material` / `fifty_moves` / `threefold_repetition`, announce the draw. If `check`, note it but proceed.

## Claude's turn

1. **Pick a move:**

   ```sh
   plugin/skills/chess/chess_helper.py best <FEN>
   ```

   Returns `{from, to, uci, san, fen, status}`. The default depth (2) is fast and weak — fine for casual play. Use `--depth 3` if you want slower, slightly better play.
2. **Re-render** the board with the last-move highlight:

   ```sh
   plugin/skills/chess/chess_helper.py render <new-FEN> --last-move <uci> --size 600
   ```

   Then `show_svg(name: "chess-board", content: <svg>, width: 600)` — same `name` updates the panel in place.
3. **Announce the move** in standard algebraic (the `san` field from the helper response) — one short line: "Nf3." / "Bxc4." / "O-O." Skip explanation unless the move is interesting.
4. **Check status:** terminal states handled the same as the user's turn. If `checkmate`, you (Claude) just won — render the final board, "Checkmate. Good game.", offer rematch.

## Notes on arrow reading

- **Standard chess board orientation:** when the user is White, files run a–h left-to-right and ranks 1–8 bottom-to-top. The python-chess renderer respects this.
- **Castling:** the user draws the king's two-square move (e1→g1 short, e1→c1 long). The helper will accept the king move and execute the castle automatically. Do not require them to drag the rook too.
- **Captures:** just an arrow into the captured square — the helper handles it.
- **En passant:** arrow into the empty diagonal target square. The helper handles it.
- **If the arrow looks like it might mean two adjacent moves** (e.g., the tail is near a file boundary), say which interpretation you're taking and proceed; the user can correct via chat.

## State tracking

You must keep the current FEN in your working context between turns — the helper is stateless. The easiest pattern is to write the latest FEN in chat-as-context after each helper call, then thread it into the next call. Don't expose the raw FEN to the user; keep it for your own bookkeeping.

## Etiquette

- **Keep responses short.** "Your move." / "Nf3." / "Check." / "Hmm — that's not legal from e2; you can play e3 or e4." Don't lecture.
- **Don't narrate FEN updates** or the SVG generation. Just render and move on.
- **Don't sandbag.** Play the move the helper gives you, even if it's bad. Don't pretend to think hard; minimax-2 is what it is.
- **On a brilliant move from the user**, acknowledge it: "Nice — didn't see that." Don't fish for praise on your own moves.
- **On a rematch:** start over with `chess_helper.py new`, render fresh, keep the same panel `name: "chess-board"` so the panel updates in place.

## Limitations to be upfront about

- **Weak play.** Minimax-2 with material eval makes me a beatable opponent. That's intentional.
- **No clock.** Casual play, no time pressure.
- **No PGN export.** If the user wants the game record, you can offer to construct one from the SAN sequence you've been announcing.
- **Promotion default is queen.** Override via chat ("promote to knight") or by extending the UCI string yourself before calling `move`.
