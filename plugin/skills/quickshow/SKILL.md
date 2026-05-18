---
name: quickshow
description: Render visual output (markdown reports, diagrams, SVGs, images, full HTML designs) into a floating QuickShow HUD panel the user can see — and get a screenshot back so you can verify your own work. Use whenever the conversation involves something the user should look at rather than read in the transcript — architecture diagrams, long-form reports, mockups, generated artwork, screenshots of existing files, or any visual the user would otherwise have to open a separate file or app to see. Same `name` updates the panel in place so iteration is cheap.
---

QuickShow turns visual artifacts from "described in chat" into "shown
on screen." The user sees a floating HUD panel with your rendered
output. You see the same thing — every render returns a PNG
screenshot in the MCP response. **Verify your own work before
declaring done.**

## The tool palette

Pick the right one. They're not interchangeable.

| Tool | Reach for it when |
| --- | --- |
| `show_markdown` | Long-form report, structured doc, or note you'd otherwise dump into the chat. Path *or* inline string. |
| `show_mermaid` | The user needs to *see* a relationship — architecture, flow, sequence, class, state. Don't paste raw Mermaid into chat; render it. |
| `show_svg` | Inline SVG you've authored — diagrams, hand-drawn schematics, annotated illustrations, anything where you control the vector geometry. |
| `show_image` | An existing PNG/JPEG/GIF/WebP file on disk. Surface what's there; don't re-encode it inline. |
| `show_html` | Full design that needs CSS/JS/layout — landing pages, dashboards, mockups, anything where the styling is the point. Heavier than the others; pick it deliberately. The whole document must be inline (no remote fonts, no CDN). |

## Iteration is the point

Pass a **stable, semantic `name`** the first time and reuse it. Same
name updates the existing panel in place; different name opens a new
tab. Pick `"architecture"`, `"billing-mock"`, `"q3-report"` —
something the user (and future-you) can recognize.

Tabs are cheap to open but visually noisy. Prefer updating in place
when you're iterating; only fan out when you're showing genuine
alternatives the user should compare side-by-side.

## Verify before responding

The screenshot in the tool response is for you. Look at it. If the
mermaid syntax errored, the SVG sanitizer stripped something
important, or the HTML laid out wrong, fix it on the spot — don't
declare success and let the user catch it.

If a render fails (mermaid parse error, malformed SVG, missing
image), the response is structured with the error text *and* a
screenshot of the in-panel error UI. Read both and retry without
asking the user.

## When the user should react visually, not verbally

QuickShow has a markup feedback loop: the user draws on a panel
(red strokes), presses Send, and you get back the annotated PNG.
Use it when the user's response is more naturally "circle the thing
that's wrong" than "type a paragraph of feedback."

Two extra tools:

- `enable_markup_events()` — arms the per-session push channel.
  Returns the exact `Monitor` / `tail -F` command to start. Call
  once per session before rendering markup-capable panels.
- `get_markup(artifact_id)` — fetch the annotated PNG that landed
  with a `markup_sent` event. Returns an MCP image content block
  you can inspect like any other.

Event log lines look like:

```
{"type":"markup_sent","panel":"design","artifact":"<uuid>","ts":...}
{"type":"markup_dismissed","panel":"design","ts":...}
```

For full design-iteration choreography, defer to
`quickshow:frontend-design` (build a design, mark it up, refine).
For a smaller worked example, see `quickshow:fun` (the `tic-tac-toe.md`
file in that skill).

## Common-trap reminders

- **Don't paste raw mermaid/SVG/HTML into chat as a substitute for
  rendering.** If you'd consider opening a file or pasting a code
  block "for the user to look at," that's the trigger to call
  `show_*` instead.
- **HTML renders are network-blocked.** No `<link>` to Google Fonts,
  no `<script src="https://...">`, no remote `<img>`. Inline
  everything (fonts via `@font-face data: URI`, images via `data:`
  URI, scripts inline). External requests silently fail.
- **`show_image` is path-only.** It surfaces a file that already
  exists — don't try to pass image bytes inline. For agent-generated
  vector art, use `show_svg`.
- **Width matters for `show_html`.** The optional `width` argument
  (points, 100–4096) sets the canvas width. Without it, the canvas
  defaults to ~400pt — too narrow for most designs. Pick 800–1280
  for desktop content; 375 for mobile mocks.
- **`return_screenshot: false`** opts out of the screenshot on a
  per-call basis when the user is the one looking and you don't
  need to verify. Saves tokens. Default is `true` — keep it on
  when iterating.
