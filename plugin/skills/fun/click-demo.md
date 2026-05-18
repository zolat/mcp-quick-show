# Click-bridge demo

A minimal proof of the QuickShow **panel-event** loop:
agent renders an HTML panel → user clicks a button → the page calls
`window.quickshow.emit(...)` → Claude reads the resulting
`panel_event` line off the session's events log → re-renders the
panel with an acknowledgment.

This is the click-driven cousin of the markup feedback loop. The two
channels are independent (`enable_markup_events` vs.
`enable_panel_events`) but share the same `events.ndjson` log.

## Setup (do this once at the start of the session)

1. Arm the panel-event channel:
   ```
   enable_panel_events()
   ```
   The response includes a `Monitor` command pointed at the session's
   `events.ndjson`. **Start that Monitor as `persistent: true`** so
   each click triggers a notification.

2. Render the initial panel:
   ```
   show_html(name: "click-demo", content: <HTML below>, width: 480)
   ```

3. Wait. The next `panel_event` line on the Monitor channel is the
   user's click.

## Initial HTML

```html
<!doctype html>
<html><head><meta charset="utf-8"><style>
  :root { color-scheme: dark; }
  body {
    margin: 0; padding: 48px;
    font: 17px -apple-system, system-ui, sans-serif;
    background: #1c1c1c; color: #e5e3da;
    display: flex; flex-direction: column; align-items: center;
    gap: 24px;
  }
  h1 { margin: 0; font-size: 22px; font-weight: 600; }
  p  { margin: 0; color: #a8a99e; }
  button {
    appearance: none; border: 0; cursor: pointer;
    padding: 12px 24px; border-radius: 8px;
    font: inherit; font-weight: 600;
    background: #d8392c; color: #fff;
  }
  button:hover { filter: brightness(1.08); }
  #count { font-variant-numeric: tabular-nums; color: #a8a99e; }
</style></head>
<body>
  <h1>Click the button.</h1>
  <p>Claude will see it on the events log.</p>
  <button id="go" onclick="emitClick()">Send a click →</button>
  <p>local count: <span id="count">0</span></p>
  <script>
    let n = 0;
    function emitClick() {
      n += 1;
      document.getElementById("count").textContent = String(n);
      window.quickshow.emit({ type: "click", n: n, ts: Date.now() });
    }
  </script>
</body></html>
```

## Reaction loop

On every `panel_event` line whose `panel === "click-demo"`:

1. Parse the payload (`{type: "click", n, ts}`).
2. Re-render the same panel name with the acknowledgement folded in
   — change the heading to "Got click #N" or similar. Keep the
   button so the user can click again.

Example follow-up render (after the first click):

```html
<!doctype html><html>... (same style as above) ...
  <h1 style="color:#a3c47a;">Got click #1.</h1>
  <p>Click again or close the panel.</p>
  <button id="go" onclick="emitClick()">Send another →</button>
  <script>let n=1; ...</script>
</body></html>
```

## Notes the agent should know

- **The bridge is one-way.** `window.quickshow.emit(payload)` posts;
  nothing flows back from Claude into the running page until the
  next `show_html` re-render. If you need to "reply", re-render.
- **Throttle.** The Swift side caps emission at ~20 events/sec per
  panel. If you see a `panel_event_dropped` line, the page is firing
  too fast — throttle in JS (debounce, `requestAnimationFrame`,
  whatever).
- **Draw mode steals clicks.** If the user enters markup draw mode
  (✏︎ in the title bar), the canvas captures pointer events and
  buttons in the agent HTML stop responding until they leave draw
  mode. Not a bug — same trade-off the markup loop already makes.
  Don't try to "fix" it client-side.
- **Same `name` updates in place.** Re-rendering with
  `name: "click-demo"` replaces the HTML; JS state is lost. Encode
  any state the user should keep in the re-rendered HTML directly.
- **The events log is shared.** Lines have a `type` field —
  `panel_event` for emits, `panel_event_dropped` for throttle
  summaries, `markup_sent` / `markup_dismissed` for markup events.
  Filter by `type` if you've armed both channels.

## Etiquette

- Keep replies short — "Got it." / "Click #N." / a one-line tease.
  The panel is the conversation surface.
- Don't narrate the HTML or the bridge. Just render and react.
- On panel close: nothing special happens for panel events (there's
  no `panel_event_dismissed` — `panel_event_dropped` is the only
  out-of-band line and it's about throttling, not lifecycle). If the
  user closes and asks again, just re-arm and re-render.
