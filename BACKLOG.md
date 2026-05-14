# Backlog

Post-v0.1 ideas not yet on `ROADMAP.md`. Each entry is an outline an agent can pick up and plan from. Move into ROADMAP.md as a phase when scheduling.

---

## Interactive panels — DOM events back to Claude

### Why

The current feedback channel is one-way image markup: the user draws red strokes, presses Send, and Claude reads the annotated PNG. That works for *commentary* on a static rendering ("the hero is too big", "circle the wrong cell") but is strictly worse than a real interaction for cases where the surface should *be* the UI — chess pieces the user wants to click-drag, form fields, dropdowns, buttons, drag-and-drop reorderings. For those, an arrow drawn on a PNG is a lossy approximation of "I want to click here."

A small extension to the existing markup-events channel unlocks all of that.

### Existing primitives to lift from

- **`WebViewPanelRenderer.swift`** — already wires `window.webkit.messageHandlers.renderComplete` as a JS→Swift bridge. The new event channel is a second handler on the same `WKUserContentController`.
- **`Events/EventLogWriter.swift`** + **`Events/MarkupPaths.swift`** — already write NDJSON lines to per-session `events.ndjson`. The new event kind appends to the same file.
- **`sidecar/src/handlers/enableMarkupEvents.ts`** — the arm-the-push-channel pattern. The new arm tool can reuse `set_session_flag` with a new key (or be folded into the existing arming if we want them ganged).
- **`Resources/scripts/markup-canvas.js`** — proves the in-DOM JS pattern (script loaded into the WebView page that talks back to Swift). The new client-side glue sits alongside this.

### What ships

Three small pieces:

1. **New JS API in WebView templates** — `window.quickshow.emit(event)` callable from any inline `<script>` in `show_html` / `show_svg` payloads. Calls into a new `panelEvent` `WKScriptMessageHandler`.
2. **New event kind in `events.ndjson`** — one new line shape:
   ```json
   {"type":"panel_event","panel":"<name>","payload":<arbitrary JSON>,"ts":<ms>}
   ```
   `payload` is whatever the panel author chose to emit — free-form, agent-defined semantics.
3. **A new sidecar arm tool** (or extension of `enable_markup_events`) — `enable_panel_events()` flips a per-session flag (`panel_events_armed`) the same way `markup_events_armed` works, and returns the same Monitor incantation pointed at `events.ndjson`.

The wire protocol stays unchanged; this is purely an additive event kind. Skills consume it identically to `markup_sent` (read the line, react).

### Worked example — interactive chess

```html
<svg id="board" onclick="onSquareClick(event)">…</svg>
<script>
  let selected = null;
  function onSquareClick(e) {
    const sq = squareFromXY(e.offsetX, e.offsetY);
    if (!selected) { selected = sq; highlight(sq); return; }
    window.quickshow.emit({ type: "move", from: selected, to: sq });
    selected = null;
  }
</script>
```

Claude sees `{"type":"panel_event","panel":"chess","payload":{"type":"move","from":"e2","to":"e4"}}` in the log, calls `chess_helper move`, re-renders. No PNG inspection.

### Open design questions

- **Schema**: free-form `{type, payload}` blob vs typed events the app knows about (and might validate). Lean free-form — the app stays a dumb pipe, semantics live in the skill prompt + the rendered HTML.
- **Throttling**: a misbehaving page could spam the log with thousands of events (mousemove on hover, scroll). Need per-panel rate limiting — e.g. max 20 events/sec, drop excess with a `panel_event_dropped` summary line.
- **Reply channel**: does the panel ever need to *receive* messages back ("your move is invalid — flash red")? If yes, that's a second bridge direction (Swift → JS via `evaluateJavaScript`). If no, one-way is much simpler. Defer until a concrete case demands it.
- **CSP / sandbox**: `show_html` already runs with `connect-src 'none'` + `script-src 'self' 'unsafe-inline'`. The new bridge is `window.webkit.messageHandlers.panelEvent.postMessage(...)`, which is same-origin — no CSP relaxation needed.
- **Naming**: `quickshow.emit` is short and obvious. Could also be `qs.event(...)` or `claude.send(...)`. Bikeshed deferred.

### Acceptance criteria

1. Calling `window.quickshow.emit({foo: 1})` inside a `show_html` page produces a `panel_event` line in `events.ndjson` for the current session.
2. The line includes the panel `name` (so multi-panel sessions can disambiguate).
3. `enable_panel_events()` (or merged arm tool) returns the same Monitor command shape as `enable_markup_events()` — agents already know how to consume it.
4. Sample skill — a tiny "demo: click a button, Claude reacts" — proves the loop end-to-end. Could ship in the plugin as `quickshow:click-demo` or fold into the existing tic-tac-toe rewrite as evidence the loop works.
5. Throttling: rapid-fire `emit()` calls (≥ 100/sec) don't drown the log or stall the WebView; the rate limit is documented in the SKILL.md for any consumer.

### Out of scope (note explicitly)

- Per-event ack from Claude back to the panel. (See "Reply channel" above — defer.)
- Anything involving accepting input from outside the same `show_*` panel (e.g. drag from one panel into another). One panel at a time.
- Persistent state on the panel across re-renders. Same `name` updates replace the DOM; the panel author can store state in JS but loses it across updates.

### Estimated shape

~150 lines of Swift (new bridge handler + EventLogWriter line shape + flag wiring), ~30 lines of TypeScript (new `enable_panel_events` raw handler or extension), ~20 lines of JS template glue, one demo skill, one new line in `docs/control-protocol.md` documenting the event shape.

No wire-protocol envelope changes needed — `set_session_flag` already exists, and `panel_event` is an app→Claude side channel (events log), not a sidecar→app request.
