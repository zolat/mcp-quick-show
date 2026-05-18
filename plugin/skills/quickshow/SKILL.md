---
name: quickshow
description: Render visual output (markdown reports, diagrams, SVGs, images, full HTML designs, live URLs) into a floating QuickShow HUD panel the user can see — and get a screenshot back so you can verify your own work. Use whenever the conversation involves something the user should look at rather than read in the transcript — architecture diagrams, code walkthroughs, plans and roadmaps, comparisons of options, long-form reports, mockups, generated artwork, screenshots of existing files, **online docs you want them to read**, or **the running site you just changed** during end-to-end verification. Same `name` updates the panel in place so iteration is cheap.
---

QuickShow turns visual artifacts from "described in chat" into "shown
on screen." The user sees a floating HUD panel with your rendered
output. You see the same thing — every render returns a PNG
screenshot in the MCP response. **Verify your own work before
declaring done.**

## Reach for it when…

You're often mid-task on something unrelated when one of these moments
hits. Render instead of describing. If you'd otherwise paste a
multi-line code block, file path, or wall of structured text "for the
user to look at," that's the trigger.

- **Explaining architecture, flow, or how something works** —
  `show_mermaid` (flow, sequence, class, state). Don't paste raw
  mermaid into chat.
- **Walking through a codebase or feature** — start with a mermaid
  overview, then a `show_markdown` panel with the key files /
  responsibilities. Iterate against the same `name` as the user asks
  follow-ups.
- **Presenting a plan, roadmap, or design doc** — `show_markdown`.
  Better than a wall of chat the user has to scroll back through.
- **Comparing options** (libraries, designs, approaches, configs) —
  two panels with related names (`"option-a"`, `"option-b"`) or a
  side-by-side `show_html`. A visual diff beats prose pros-and-cons.
- **Pointing at a file the user should see** — `show_image` for
  PNG/JPEG/GIF/WebP on disk; `show_svg` for SVG content. Don't say
  "open `~/Downloads/foo.png`" when you can render it for them.
- **Pointing at an online doc** — `show_url` for a spec, RFC, blog
  post, release notes, or any web page you want the user to read.
  Don't paste the URL and ask them to context-switch; render it.
- **End-to-end verification of a running site** — `show_url` for
  the local dev server / staging URL / deployed app you just
  changed. This is the load-bearing way to satisfy CLAUDE.md's
  "exercise the running system" quality gate for web work without
  asking the user to leave the conversation. Pair with
  `enable_markup_events` if you want them to circle what's wrong.
- **Surfacing structured output** — test results, dependency trees,
  git log analyses, table-shaped data — render as a markdown table
  panel, not a raw stderr dump.
- **Final-report verification** — when the CLAUDE.md "What changed /
  How verified / What the user can now do" wrap-up is long, a
  `show_markdown` panel makes it scannable.
- **Mockup, hero, dashboard, or any styled visual** — `show_html`
  with the right `width`. For full design choreography (markup
  feedback loop, aesthetic direction), defer to
  `quickshow:frontend-design`.

## The tool palette

Pick the right one. They're not interchangeable.

| Tool | Reach for it when |
| --- | --- |
| `show_markdown` | Long-form report, structured doc, or note you'd otherwise dump into the chat. Path *or* inline string. |
| `show_mermaid` | The user needs to *see* a relationship — architecture, flow, sequence, class, state. Don't paste raw Mermaid into chat; render it. |
| `show_svg` | Inline SVG you've authored — diagrams, hand-drawn schematics, annotated illustrations, anything where you control the vector geometry. |
| `show_image` | An existing PNG/JPEG/GIF/WebP file on disk. Surface what's there; don't re-encode it inline. |
| `show_html` | Full design that needs CSS/JS/layout — landing pages, dashboards, mockups, anything where the styling is the point. Heavier than the others; pick it deliberately. The whole document must be inline (no remote fonts, no CDN). |
| `show_url` | Point the user at a **live URL** — online doc, spec, article, or a running site (local dev server, staging) during end-to-end verification. Same-origin navigation works in-place; cross-origin links open in the default browser. Use this when you *want* network; use `show_html` when you want a fully self-contained design. |

## Iteration is the point

Pass a **stable, semantic `name`** the first time and reuse it. Same
name updates the existing panel in place; different name opens a new
tab. Pick `"architecture"`, `"billing-mock"`, `"q3-report"` —
something the user (and future-you) can recognize.

Tabs are cheap to open but visually noisy. Prefer updating in place
when you're iterating; only fan out when you're showing genuine
alternatives the user should compare side-by-side.

## Grouping tabs into a presentation

Three optional fields on every `show_*` call let you bundle related
panels into a single tabbed HUD with framing prose:

- **`group: "design-review"`** — panels sharing a `group` land in the
  same HUD with the same tab strip. Each distinct group spawns its
  own HUD with its own cascade origin. Without `group`, panels go
  into the session's default HUD as before. **`group` on update
  calls is ignored** — a `name` is sticky to whichever HUD it was
  first created in.
- **`description: "Bold serif hero, 90s editorial revival."`** —
  one-line framing for *this tab*. Shown in a banner above the
  rendered content while the tab is active. ≤256 bytes. Empty
  string clears.
- **`hud_description: "Three hero variants ranked best-to-worst."`** —
  paragraph framing the *whole HUD*. Stays visible across tab
  switches; last writer wins among calls sharing a `group`. ≤4 KB.
  Empty string clears.

Reach for `group` + `hud_description` when you're presenting a
multi-tab story (variants to compare, a deck of related diagrams,
a doc + its accompanying mockup). One ungrouped `show_*` is still
the right move when the panel is standalone.

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
- **`show_html` is network-blocked; `show_url` is the network tool.**
  `show_html` (inline document, `loadHTMLString` with `baseURL: nil`)
  has no network — no `<link>` to Google Fonts, no
  `<script src="https://...">`, no remote `<img>`. Inline everything
  (fonts via `@font-face data: URI`, images via `data:` URI, scripts
  inline). External requests silently fail. If you actually *want* to
  show the user something live on the web, that's `show_url`.
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
