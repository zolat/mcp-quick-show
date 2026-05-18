#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["chess>=1.10"]
# ///
"""Chess helper for the QuickShow `chess` skill.

The helper is ground truth — it tracks the position, validates moves,
lists legal moves, and renders the board. It does **not** pick moves;
Claude plays both sides using its own chess knowledge.

Subcommands:
  new                                   → emit starting FEN as JSON
  render <fen> [--last-move uci]        → emit board SVG to stdout
  render-html <fen> [...]               → emit draggable HTML to stdout
  move <fen> <uci>                      → validate + apply a move
  status <fen>                          → game status
  legal <fen> [--from sq]               → list legal moves

All commands except `render` / `render-html` print one JSON object on
stdout. `render` prints raw SVG; `render-html` prints a full HTML
page that wraps the SVG with a drag-and-drop overlay
(panel_event-driven).
"""

import argparse
import json

import chess


STARTING_FEN = chess.STARTING_FEN

# Use the SOLID Unicode chess glyphs for both colours and tint with fill;
# the outlined ("white") glyphs look thin on screen and don't render as
# clearly through the WebView's font stack.
PIECE_GLYPH = {
    chess.PAWN: "♟",   # ♟
    chess.KNIGHT: "♞", # ♞
    chess.BISHOP: "♝", # ♝
    chess.ROOK: "♜",   # ♜
    chess.QUEEN: "♛",  # ♛
    chess.KING: "♚",   # ♚
}


def render_board_svg(board: chess.Board, size: int = 600, last_move: chess.Move | None = None) -> str:
    """Render a chess board as a compact SVG using Unicode piece glyphs.

    The output is intentionally simple — no <defs>/<use> machinery — so it
    passes cleanly through QuickShow's DOMPurify SVG sanitiser.
    """
    margin = 30
    inner = size - 2 * margin
    sq = inner / 8.0

    light = "#f0d9b5"
    dark = "#b58863"
    bg = "#312e2b"
    coord_color = "#f0d9b5"
    highlight = "#f7ec74"

    parts: list[str] = []
    parts.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" '
        f'viewBox="0 0 {size} {size}" font-family="-apple-system, Helvetica, sans-serif">'
    )
    parts.append(f'<rect width="{size}" height="{size}" fill="{bg}"/>')

    # Squares
    for r in range(8):  # r=0 is rank 8 from top
        for f in range(8):
            x = margin + f * sq
            y = margin + r * sq
            fill = light if (r + f) % 2 == 0 else dark
            parts.append(f'<rect x="{x:.2f}" y="{y:.2f}" width="{sq:.2f}" height="{sq:.2f}" fill="{fill}"/>')

    # Last-move highlight (translucent yellow on origin + destination squares)
    if last_move is not None:
        for sqi in (last_move.from_square, last_move.to_square):
            file = chess.square_file(sqi)
            rank_top = 7 - chess.square_rank(sqi)
            x = margin + file * sq
            y = margin + rank_top * sq
            parts.append(
                f'<rect x="{x:.2f}" y="{y:.2f}" width="{sq:.2f}" height="{sq:.2f}" '
                f'fill="{highlight}" fill-opacity="0.55"/>'
            )

    # Pieces — Unicode glyph, tinted by colour, with an opposite-colour stroke
    # so they read on any square (paint-order:stroke renders the outline first
    # so the fill sits on top, keeping the glyph crisp).
    #
    # `data-square` lets the drag handler (in render_board_html) look up the
    # piece <text> element by algebraic notation.
    piece_font = sq * 0.78
    for sqi in range(64):
        piece = board.piece_at(sqi)
        if piece is None:
            continue
        file = chess.square_file(sqi)
        rank_top = 7 - chess.square_rank(sqi)
        cx = margin + (file + 0.5) * sq
        # Tiny downward nudge to compensate for the Unicode chess glyph
        # sitting slightly above the "central" baseline.
        cy = margin + (rank_top + 0.5) * sq + sq * 0.03
        glyph = PIECE_GLYPH[piece.piece_type]
        if piece.color == chess.WHITE:
            fill = "#ffffff"
            stroke = "#000000"
        else:
            fill = "#1a1a1a"
            stroke = "#ffffff"
        name = chess.square_name(sqi)
        parts.append(
            f'<text data-square="{name}" x="{cx:.2f}" y="{cy:.2f}" font-size="{piece_font:.2f}" '
            f'text-anchor="middle" dominant-baseline="central" '
            f'fill="{fill}" stroke="{stroke}" stroke-width="2" paint-order="stroke">{glyph}</text>'
        )

    # Coordinate labels — files (a-h) along the bottom, ranks (1-8) along the left
    coord_font = 14
    for f in range(8):
        x = margin + (f + 0.5) * sq
        y = size - 10
        letter = "abcdefgh"[f]
        parts.append(
            f'<text x="{x:.2f}" y="{y}" font-size="{coord_font}" text-anchor="middle" '
            f'fill="{coord_color}">{letter}</text>'
        )
    for r in range(8):
        x = 14
        y = margin + (7 - r + 0.5) * sq
        parts.append(
            f'<text x="{x}" y="{y:.2f}" font-size="{coord_font}" text-anchor="middle" '
            f'dominant-baseline="central" fill="{coord_color}">{r + 1}</text>'
        )

    # Check indicator — red ring around king's square when in check
    if board.is_check():
        king_sq = board.king(board.turn)
        if king_sq is not None:
            file = chess.square_file(king_sq)
            rank_top = 7 - chess.square_rank(king_sq)
            x = margin + file * sq
            y = margin + rank_top * sq
            parts.append(
                f'<rect x="{x:.2f}" y="{y:.2f}" width="{sq:.2f}" height="{sq:.2f}" '
                f'fill="none" stroke="#d83a2c" stroke-width="4"/>'
            )

    parts.append("</svg>")
    return "".join(parts)


def render_board_html(
    board: chess.Board,
    size: int = 600,
    last_move: chess.Move | None = None,
    selected: int | None = None,
    legal_targets: list[int] | None = None,
) -> str:
    """Wrap `render_board_svg` in an HTML page with drag-and-drop
    interaction. The page embeds the side-to-move's legal-moves map
    and validates drops locally; only successful (legal) drops emit a
    `panel_event` of shape `{type:"move", from, to}`. Illegal / off-
    board drops snap back and emit nothing.

    `selected` / `legal_targets` are optional static decorations —
    useful for snapshotting / debugging without a real drag, no
    effect on the live drag UX (which paints its own highlights).
    """
    base_svg = render_board_svg(board, size=size, last_move=last_move)
    margin = 30
    inner = size - 2 * margin
    sq = inner / 8.0

    overlay: list[str] = []

    # Static decorations (debugging only — drag UX paints its own).
    if selected is not None:
        file = chess.square_file(selected)
        rank_top = 7 - chess.square_rank(selected)
        x = margin + file * sq
        y = margin + rank_top * sq
        overlay.append(
            f'<rect x="{x:.2f}" y="{y:.2f}" width="{sq:.2f}" height="{sq:.2f}" '
            f'fill="none" stroke="#f7ec74" stroke-width="4" pointer-events="none"/>'
        )
    if legal_targets:
        for tgt in legal_targets:
            file = chess.square_file(tgt)
            rank_top = 7 - chess.square_rank(tgt)
            cx = margin + (file + 0.5) * sq
            cy = margin + (rank_top + 0.5) * sq
            if board.piece_at(tgt) is not None:
                overlay.append(
                    f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="{sq * 0.46:.2f}" '
                    f'fill="none" stroke="#f7ec74" stroke-width="4" '
                    f'opacity="0.85" pointer-events="none"/>'
                )
            else:
                overlay.append(
                    f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="{sq * 0.16:.2f}" '
                    f'fill="#f7ec74" opacity="0.85" pointer-events="none"/>'
                )

    # Click/drop overlay — 64 transparent rects, one per square,
    # tagged with `data-square` so the JS handler can map pointer
    # position → square name without a hit-test loop. Pieces sit
    # below this layer; the drag handler reorders the picked piece
    # on top during drag so it visually rides above the overlay.
    overlay.append('<g id="click-overlay">')
    for sqi in range(64):
        file = chess.square_file(sqi)
        rank_top = 7 - chess.square_rank(sqi)
        x = margin + file * sq
        y = margin + rank_top * sq
        name = chess.square_name(sqi)
        overlay.append(
            f'<rect class="click-cell" data-square="{name}" '
            f'x="{x:.2f}" y="{y:.2f}" width="{sq:.2f}" height="{sq:.2f}" '
            f'fill="transparent"/>'
        )
    overlay.append("</g>")
    svg_with_overlay = base_svg.replace("</svg>", "".join(overlay) + "</svg>")

    # Precompute the side-to-move's legal moves so the page can
    # validate drops without an embedded chess engine. Map shape:
    #   { "e2": ["e3","e4"], "g1": ["f3","h3"], ... }
    # Promotion is intentionally not encoded — the page emits
    # {from,to} only and lets chess_helper.py move default to queen
    # (the user can override via chat for non-queen promotions).
    legal_map: dict[str, list[str]] = {}
    for move in board.legal_moves:
        legal_map.setdefault(chess.square_name(move.from_square), []).append(
            chess.square_name(move.to_square)
        )
    # Dedupe target lists (promotions otherwise produce 4 entries per to-square).
    legal_map = {k: sorted(set(v)) for k, v in legal_map.items()}
    state_json = json.dumps({
        "legalMoves": legal_map,
        "turn": "white" if board.turn == chess.WHITE else "black",
    })

    drag_script = r"""
(function () {
  // Embedded at render time by chess_helper.render-html.
  const state = window.__chess || { legalMoves: {} };
  const legalMoves = state.legalMoves || {};

  // Index click-cells (drop zones) by square name.
  const cells = {};
  for (const c of document.querySelectorAll(".click-cell")) {
    cells[c.dataset.square] = {
      el: c,
      x: parseFloat(c.getAttribute("x")),
      y: parseFloat(c.getAttribute("y")),
      w: parseFloat(c.getAttribute("width")),
      h: parseFloat(c.getAttribute("height")),
    };
  }

  // Index piece <text> elements by their data-square attribute.
  const pieces = {};
  for (const t of document.querySelectorAll("text[data-square]")) {
    pieces[t.dataset.square] = t;
  }

  const svgEl = document.querySelector("svg");

  function clientToSvg(cx, cy) {
    const pt = svgEl.createSVGPoint();
    pt.x = cx; pt.y = cy;
    return pt.matrixTransform(svgEl.getScreenCTM().inverse());
  }

  function squareAt(x, y) {
    for (const [name, c] of Object.entries(cells)) {
      if (x >= c.x && x < c.x + c.w && y >= c.y && y < c.y + c.h) return name;
    }
    return null;
  }

  // Dynamic highlight layer drawn during drag.
  let hlGroup = null;
  function drawHighlights(originSq, targets) {
    clearHighlights();
    const ns = "http://www.w3.org/2000/svg";
    hlGroup = document.createElementNS(ns, "g");
    hlGroup.setAttribute("id", "drag-highlights");
    hlGroup.setAttribute("pointer-events", "none");
    const o = cells[originSq];
    const border = document.createElementNS(ns, "rect");
    border.setAttribute("x", o.x); border.setAttribute("y", o.y);
    border.setAttribute("width", o.w); border.setAttribute("height", o.h);
    border.setAttribute("fill", "none");
    border.setAttribute("stroke", "#f7ec74");
    border.setAttribute("stroke-width", "4");
    hlGroup.appendChild(border);
    for (const tgt of targets) {
      const c = cells[tgt];
      if (!c) continue;
      const cx = c.x + c.w / 2;
      const cy = c.y + c.h / 2;
      const shape = document.createElementNS(ns, "circle");
      shape.setAttribute("cx", cx); shape.setAttribute("cy", cy);
      if (pieces[tgt]) {
        shape.setAttribute("r", c.w * 0.46);
        shape.setAttribute("fill", "none");
        shape.setAttribute("stroke", "#f7ec74");
        shape.setAttribute("stroke-width", "4");
      } else {
        shape.setAttribute("r", c.w * 0.16);
        shape.setAttribute("fill", "#f7ec74");
      }
      shape.setAttribute("opacity", "0.85");
      hlGroup.appendChild(shape);
    }
    const clickGroup = document.getElementById("click-overlay");
    svgEl.insertBefore(hlGroup, clickGroup);
  }
  function clearHighlights() {
    if (hlGroup && hlGroup.parentNode) hlGroup.parentNode.removeChild(hlGroup);
    hlGroup = null;
  }

  let drag = null;
  let locked = false;

  function startDrag(e) {
    if (locked) return;
    if (e.button !== 0 && e.button !== undefined) return;
    const p = clientToSvg(e.clientX, e.clientY);
    const sq = squareAt(p.x, p.y);
    if (!sq) return;
    const targets = legalMoves[sq];
    if (!targets || targets.length === 0) return;
    const piece = pieces[sq];
    if (!piece) return;
    drag = {
      origin: sq,
      piece: piece,
      ox: parseFloat(piece.getAttribute("x")),
      oy: parseFloat(piece.getAttribute("y")),
      legalSet: new Set(targets),
    };
    // Bring piece above the click-overlay group during drag.
    svgEl.appendChild(piece);
    piece.style.cursor = "grabbing";
    piece.setAttribute("pointer-events", "none");
    drawHighlights(sq, targets);
    // Track pointer immediately so the piece centres under the cursor.
    piece.setAttribute("x", p.x);
    piece.setAttribute("y", p.y);
    try { e.target.setPointerCapture && e.target.setPointerCapture(e.pointerId); } catch (_) {}
    e.preventDefault();
  }

  function moveDrag(e) {
    if (!drag) return;
    const p = clientToSvg(e.clientX, e.clientY);
    drag.piece.setAttribute("x", p.x);
    drag.piece.setAttribute("y", p.y);
  }

  function endDrag(e) {
    if (!drag) return;
    const p = clientToSvg(e.clientX, e.clientY);
    const dropSq = squareAt(p.x, p.y);
    clearHighlights();
    if (dropSq && dropSq !== drag.origin && drag.legalSet.has(dropSq)) {
      const c = cells[dropSq];
      drag.piece.setAttribute("x", c.x + c.w / 2);
      drag.piece.setAttribute("y", c.y + c.h / 2 + c.h * 0.03);
      // Remove captured piece visually so the board reads cleanly
      // while Claude's re-render is in flight.
      if (pieces[dropSq] && pieces[dropSq] !== drag.piece) {
        pieces[dropSq].remove();
      }
      locked = true;
      if (window.quickshow && window.quickshow.emit) {
        window.quickshow.emit({ type: "move", from: drag.origin, to: dropSq });
      }
    } else {
      drag.piece.setAttribute("x", drag.ox);
      drag.piece.setAttribute("y", drag.oy);
    }
    drag.piece.style.cursor = "";
    drag = null;
  }

  function cancelDrag() {
    if (!drag) return;
    drag.piece.setAttribute("x", drag.ox);
    drag.piece.setAttribute("y", drag.oy);
    drag.piece.style.cursor = "";
    clearHighlights();
    drag = null;
  }

  document.addEventListener("pointerdown", startDrag);
  document.addEventListener("pointermove", moveDrag);
  document.addEventListener("pointerup", endDrag);
  document.addEventListener("pointercancel", cancelDrag);
})();
"""

    return f"""<!doctype html>
<html><head><meta charset="utf-8"><style>
  :root {{ color-scheme: dark; }}
  html, body {{ margin: 0; padding: 0; background: #1c1c1c; user-select: none; -webkit-user-select: none; }}
  body {{ display: flex; align-items: center; justify-content: center; min-height: {size}px; }}
  svg {{ display: block; touch-action: none; }}
  .click-cell {{ cursor: grab; }}
  .click-cell:hover {{ fill: rgba(255,255,255,0.06); }}
</style></head><body>
<script>window.__chess = {state_json};</script>
{svg_with_overlay}
<script>{drag_script}</script>
</body></html>"""


def status_str(board: chess.Board) -> str:
    if board.is_checkmate():
        return "checkmate"
    if board.is_stalemate():
        return "stalemate"
    if board.is_insufficient_material():
        return "insufficient_material"
    if board.can_claim_fifty_moves():
        return "fifty_moves"
    if board.can_claim_threefold_repetition():
        return "threefold_repetition"
    if board.is_check():
        return "check"
    return "ongoing"


def emit(obj):
    print(json.dumps(obj))


def normalize_uci(board: chess.Board, uci: str) -> chess.Move:
    """Parse UCI and default queen promotion for pawn-to-back-rank moves."""
    move = chess.Move.from_uci(uci)
    piece = board.piece_at(move.from_square)
    if piece and piece.piece_type == chess.PAWN and move.promotion is None:
        rank_to = chess.square_rank(move.to_square)
        if (piece.color == chess.WHITE and rank_to == 7) or (
            piece.color == chess.BLACK and rank_to == 0
        ):
            move = chess.Move(move.from_square, move.to_square, promotion=chess.QUEEN)
    return move


def cmd_new(_args):
    emit({"fen": STARTING_FEN})


def cmd_render(args):
    board = chess.Board(args.fen)
    last_move = None
    if args.last_move:
        try:
            last_move = chess.Move.from_uci(args.last_move)
        except ValueError:
            pass
    print(render_board_svg(board, size=args.size, last_move=last_move))


def cmd_render_html(args):
    board = chess.Board(args.fen)
    last_move = None
    if args.last_move:
        try:
            last_move = chess.Move.from_uci(args.last_move)
        except ValueError:
            pass
    selected = None
    if args.selected:
        try:
            selected = chess.parse_square(args.selected)
        except ValueError:
            pass
    legal_targets: list[int] = []
    if args.legal_targets:
        for s in args.legal_targets.split(","):
            s = s.strip()
            if not s:
                continue
            try:
                legal_targets.append(chess.parse_square(s))
            except ValueError:
                pass
    print(render_board_html(
        board,
        size=args.size,
        last_move=last_move,
        selected=selected,
        legal_targets=legal_targets,
    ))


def cmd_move(args):
    board = chess.Board(args.fen)
    try:
        move = normalize_uci(board, args.move)
    except ValueError as e:
        emit({"ok": False, "error": f"invalid uci: {e}"})
        return

    if move not in board.legal_moves:
        # Suggest legal destinations from the origin square so the caller
        # can give the user a useful hint without re-querying.
        legal_from_origin = [
            chess.square_name(m.to_square)
            for m in board.legal_moves
            if m.from_square == move.from_square
        ]
        emit({
            "ok": False,
            "error": "illegal move",
            "from": chess.square_name(move.from_square),
            "to": chess.square_name(move.to_square),
            "legal_to_from_origin": legal_from_origin,
        })
        return

    san = board.san(move)
    board.push(move)
    emit({
        "ok": True,
        "fen": board.fen(),
        "uci": move.uci(),
        "san": san,
        "status": status_str(board),
        "turn": "white" if board.turn == chess.WHITE else "black",
    })


def cmd_status(args):
    board = chess.Board(args.fen)
    emit({
        "status": status_str(board),
        "turn": "white" if board.turn == chess.WHITE else "black",
        "fullmove": board.fullmove_number,
        "halfmove": board.halfmove_clock,
        "in_check": board.is_check(),
    })


def cmd_legal(args):
    board = chess.Board(args.fen)
    origin_filter = None
    if args.from_:
        try:
            origin_filter = chess.parse_square(args.from_)
        except ValueError:
            emit({"ok": False, "error": f"bad square: {args.from_}"})
            return
    moves = []
    for m in board.legal_moves:
        if origin_filter is not None and m.from_square != origin_filter:
            continue
        moves.append({
            "from": chess.square_name(m.from_square),
            "to": chess.square_name(m.to_square),
            "promotion": chess.piece_symbol(m.promotion) if m.promotion else None,
            "uci": m.uci(),
            "san": board.san(m),
        })
    emit({"ok": True, "moves": moves})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("new", help="Emit starting FEN")
    p.set_defaults(func=cmd_new)

    p = sub.add_parser("render", help="Emit SVG of position to stdout")
    p.add_argument("fen")
    p.add_argument("--last-move", default=None, help="UCI of last move to highlight")
    p.add_argument("--size", type=int, default=600)
    p.set_defaults(func=cmd_render)

    p = sub.add_parser("render-html",
                       help="Emit a clickable HTML page wrapping the SVG (panel_event-driven)")
    p.add_argument("fen")
    p.add_argument("--last-move", default=None, help="UCI of last move to highlight")
    p.add_argument("--size", type=int, default=600)
    p.add_argument("--selected", default=None,
                   help="Selected square, e.g. e2 — draws a yellow border")
    p.add_argument("--legal-targets", default=None,
                   help="Comma-separated legal target squares, e.g. e3,e4 — draws move dots / capture rings")
    p.set_defaults(func=cmd_render_html)

    p = sub.add_parser("move", help="Apply a move (UCI: e2e4, or e7e8q for promotion)")
    p.add_argument("fen")
    p.add_argument("move")
    p.set_defaults(func=cmd_move)

    p = sub.add_parser("status", help="Game status")
    p.add_argument("fen")
    p.set_defaults(func=cmd_status)

    p = sub.add_parser("legal", help="List legal moves (optionally filtered by origin square)")
    p.add_argument("fen")
    p.add_argument("--from", dest="from_", default=None, help="Filter by origin square e.g. e2")
    p.set_defaults(func=cmd_legal)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
