# Roadmap

**Current:** v0.1 feature-complete; significant post-v0.1 work has
shipped (markup feedback loop, in-DOM canvas, `show_html` renderer,
`quickshow-design` skill, Arthur theming). No active phase. The
project has not been publicly released yet — a v0.1.1 tag + signed
DMG + refreshed README is the natural next milestone.

## v0.1 — Original scope (shipped)

- [x] Phase 0 — Scaffolding
- [x] Phase 1 — Markdown vertical slice
- [x] Phase 2 — Remaining renderers (SVG, Mermaid, Image)
- [x] Phase 3 — Multiplexing (tabs, sessions, list/close/inspect)
- [x] Phase 4 — Lifecycle (session UUID, orphan, reconnect)
- [x] Phase 5 — Promote-to-window + UX polish (tear-out, reattach,
  pin-to-Space, prefs panel)
- [x] Phase 6 — Distribution polish — bundled sidecar + DMG build
  (`dist/QuickShow-0.1.0.dmg` exists, **unsigned**, predates the
  markup work; never tagged or pushed as a release)

## Post-v0.1 (shipped)

- [x] Diagram + image pan/zoom (PRD #35b)
- [x] Markup push channel — app → Claude via tail + Monitor
- [x] Close → `markup_dismissed` for armed sessions
- [x] `show_html` renderer — agent-supplied HTML with full
  `<script>` execution (escapes the `innerHTML`-drops-scripts trap
  the other templates use)
- [x] `quickshow-design` skill — render → user marks up → iterate
- [x] Markup feedback loop UI — title-bar ✏︎ / ⌫ / ✓; NDJSON events
  log; per-session artifacts dir
- [x] Fixed-canvas pan/zoom — WebView pinned to its natural document
  size; outer `ZoomableCanvasScrollView` handles pan + zoom + smartFit
- [x] `show_html` `width` arg — agent controls the canvas width so
  responsive designs lay out at the intended viewport
- [x] In-DOM canvas markup — strokes live inside the WebView via a
  `WKUserScript`-injected `<canvas>`; `takeSnapshot` captures them
  natively (no separate composite layer); strokes survive re-render
- [x] Arthur dark theme — content stage `#1c1c1c`, canvas border,
  top-bar tint `#2a2620` / `#a8a99e`
- [x] Centered-fit when content < window; crosshair-cursor-in-draw-
  mode suppressing the scroll view's open-hand pan cursor
- [x] Claude Code plugin distribution — `.claude-plugin/marketplace.json`
  at repo root + `plugin/` tree (manifest, `.mcp.json` pointing at
  bundled sidecar, foundational `quickshow` skill, adapted
  `frontend-design` skill, `tic-tac-toe` demo skill)
- [x] Demo skill: tic-tac-toe — `plugin/skills/tic-tac-toe/` ships
  with the plugin; SVG board + markup-driven gameplay
- [x] Demo skill: chess — `plugin/skills/chess/` with `chess_helper.py`
  (uv inline-deps + python-chess), Unicode-glyph board renderer,
  minimax-2 opponent

## Backlog

Loosely sorted, no commitment. Pulled into a phase or into ad-hoc
work as priorities firm up. Longer outlines live in `BACKLOG.md`.

- **Public release: v0.1.1.** README is stale (still pitches "v0.1
  in development" and doesn't mention the markup loop, `show_html`,
  or the design skill). The DMG in `dist/` is unsigned and predates
  the markup work. To ship: refresh README to feature the markup
  loop + design skill, rebuild the DMG against current `main`, sign
  + notarize, tag `v0.1.1`, publish to GitHub Releases. This is
  the highest-ROI move — work is done, story isn't told.
- **Interactive panels — DOM events back to Claude.** Generic
  `window.quickshow.emit(...)` JS → Swift bridge → new
  `panel_event` line in `events.ndjson`. Turns `show_html` panels
  into real two-way UIs (click-to-move chess, dropdowns, form
  submissions) instead of static renderings with arrow-on-PNG
  markup. Full outline in `BACKLOG.md`.
- **Top-bar rework.** Current top bar got a quick Arthur tint pass
  but is otherwise unchanged from v0.1. Open question: what
  belongs there once the markup loop is the marquee feature
  (panel name? session indicator? markup state hints? per-stroke
  color picker?).
- **Multi-color markup.** Today's stroke is always red
  (`#d8392c`). Semantic colors — red for "fix", green for "this is
  good", maybe one more — would let the user encode review intent
  in the markup itself. Small JS-bridge addition + a title-bar
  color selector.
- **Security pass on `show_html`.** v0.1 trades CSP rigor for
  ergonomics — agent HTML is accepted at face value. PRD § show_html
  deferred a strict-CSP / allowlisted-CDN posture to v0.2.
