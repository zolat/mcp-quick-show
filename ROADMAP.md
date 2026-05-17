# Roadmap

**Current:** v0.1.1 released — first public tag + binary. The
backlog narrows to a `show_html` security pass (deferred from v0.1)
and Developer-ID signing + notarization (v0.1.1 ships ad-hoc signed,
Apple-Silicon only).

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
- [x] Demo skill: tic-tac-toe — `plugin/skills/fun/tic-tac-toe.md` ships
  with the plugin; SVG board + markup-driven gameplay
- [x] Demo skill: chess — `plugin/skills/fun/chess.md` with `chess_helper.py`
  (uv inline-deps + python-chess), Unicode-glyph board renderer,
  minimax-2 opponent
- [x] Interactive panels — `window.quickshow.emit(payload)` JS→Swift
  bridge, third `panelEvent` script-message channel, new
  `enable_panel_events` sidecar tool gated on `panel_events_armed`,
  token-bucket throttle (20/s/panel) with 1Hz drop summaries, demo
  skill `plugin/skills/fun/click-demo.md`
- [x] Top-bar revamp — 28pt bar (was 22pt), 22×22 buttons (was
  18×18), SF Symbols replace Unicode glyphs, in-place mode swap
  for draw mode (title region yields to tool palette at the same
  height), single-button dropdown pickers for stroke color +
  weight (`NSPopover`-backed), Send becomes a labelled accent
  pill.
- [x] Multi-color markup + stroke-weight wiring — `window.__qsMarkup`
  exposes `setColor(hex)` and `setWidth(px)`; SessionManager
  forwards `onPickMarkupColor` / `onPickMarkupWeight` from the
  title-bar pickers through `WebViewPanelRenderer` to those
  methods. New strokes use the picker's current selection;
  committed strokes preserve their captured color/width across
  re-renders.
- [x] Markup undo + eraser wiring — undo button calls
  `popLastStroke` and gates its enabled state on `hasStrokes`
  (reusing the existing strokes-changed channel — no new
  JS↔Swift wire). Eraser is a new `setTool("erase")` mode on
  `window.__qsMarkup`; pointer events in erase mode splice any
  stroke whose closest point is within `ERASE_RADIUS` (12pt)
  and broadcast `strokesChanged`. New `eraser.line.dashed`
  button in the draw-tools group; picking a color implicitly
  returns to draw mode.
- [x] **v0.1.1 release** — first public tag + DMG. README rewritten
  to lead with what's shipped (markup loop, `show_html`, design
  skill, interactive panels, Claude-Space placement, plugin
  distribution). `MARKETING_VERSION` + `marketplace.json` +
  `plugin.json` bumped to 0.1.1. Fresh `dist/QuickShow-0.1.1.dmg`
  built against current `main` (Apple-Silicon, ad-hoc signed —
  Developer-ID + notarization remain in backlog). Tag pushed +
  GitHub release published with DMG attached.

## Backlog

Loosely sorted, no commitment. Pulled into a phase or into ad-hoc
work as priorities firm up. Longer outlines live in `BACKLOG.md`.

- **Developer-ID signing + notarization.** v0.1.1 ships ad-hoc
  signed; Gatekeeper blocks first-launch from the DMG without a
  right-click → Open (or `xattr -d com.apple.quarantine`). To
  remove that hurdle: enroll a Developer ID Application cert,
  switch `tools/make-dmg.sh` to sign with it, submit the bundle
  + DMG to `notarytool`, staple. Also a good moment to make the
  sidecar universal (current `build-sidecar.sh` is
  `--target=bun-darwin-arm64` only).
- **Security pass on `show_html`.** v0.1 trades CSP rigor for
  ergonomics — agent HTML is accepted at face value. PRD § show_html
  deferred a strict-CSP / allowlisted-CDN posture to v0.2.
