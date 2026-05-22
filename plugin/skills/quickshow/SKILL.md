---
name: quickshow
description: Render visual output (markdown reports, diagrams, SVGs, images, full HTML designs, live URLs) into a floating QuickShow HUD panel the user can see — and get a screenshot back so you can verify your own work. Use whenever the conversation involves something the user should look at rather than read in the transcript — architecture diagrams, code walkthroughs, plans and roadmaps, comparisons of options, long-form reports, mockups, generated artwork, screenshots of existing files, **online docs you want them to read**, or **the running site you just changed** during end-to-end verification. Same `name` updates the panel in place so iteration is cheap. **Also handles user-initiated shares**: when the user pastes `[quickshow-share:<id>]` they've opened a HUD themselves and want you to receive it — call `get_share(<id>)`. **Also use during plan mode / "design mode"** — these tools are read-only-in-spirit and a faster substitute for `AskUserQuestion` whenever a choice ("which layout / which diagram / which copy variant") is easier to answer by *seeing* than by reading bullet points.
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

## `group` is the content namespace

Every `show_*` call optionally takes a `group` argument — and you
**should always pass one**. Without it your panels land in a default
group keyed by the MCP session id, which is *different* between
`claude --resume` runs of the same conversation. That means:

- A panel rendered with `name=architecture` in one Claude session
  becomes unreachable after `claude --resume` if no `group` was
  passed — the resumed session has a fresh default group, so a
  follow-up `show_*` with the same `name` opens a *new* panel
  instead of updating in place.
- With an explicit `group`, both the original and the resumed
  sessions write into the same group — the panel updates in place
  across resume, parallel agents, even subagents.

### The memory-save pattern (required for multi-turn work)

For any body of work that spans more than one tool call, save the
group to memory on first use and recall it thereafter. This makes
the workflow resume-safe.

Worked example for a multi-turn design iteration:

```
# Turn 1 — pick a group, save it, use it
group = "design-" + <short-random-slug>     # e.g. "design-a3f"
# save to memory under a key tied to this body of work:
#   user_design_session_<topic>:  group=design-a3f
show_html(name="hero", content="…", group=group)

# Turn 2 (same conversation, or after claude --resume)
# read group back from memory before calling show_*:
group = memory.get("user_design_session_hero")  # "design-a3f"
show_html(name="hero", content="…v2", group=group)   # updates in place
```

Naming convention: keep the slug **unique per body of work**
(`<topic>-<6-hex>` is plenty) so two parallel agent sessions on
different topics don't collide. Use a literal group name only when
the work is intentionally shared between agents (collaboration
scenario — same group across two terminals means panels tab-group
into one HUD).

### Other grouping fields

Three optional fields on every `show_*` call bundle related panels
into a single tabbed HUD with framing prose:

- **`group: "design-a3f"`** — panels sharing a `group` land in the
  same HUD with the same tab strip. Each distinct group spawns its
  own HUD with its own cascade origin. **`group` on update calls
  is ignored** — a `name` is sticky to whichever HUD it was first
  created in.
- **`description: "Bold serif hero, 90s editorial revival."`** —
  one-line framing for *this tab*. Shown in a banner above the
  rendered content while the tab is active. ≤256 bytes. Empty
  string clears.
- **`hud_description: "Three hero variants ranked best-to-worst."`** —
  paragraph framing the *whole HUD*. Stays visible across tab
  switches; last writer wins among calls sharing a `group`. ≤4 KB.
  Empty string clears.

## Iteration is the point

Pass a **stable, semantic `name`** the first time and reuse it. Same
name (in the same group) updates the existing panel in place;
different name opens a new tab in the same HUD. Pick `"architecture"`,
`"billing-mock"`, `"q3-report"` — something the user (and future-you)
can recognize.

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

## Plan mode & "show, don't ask"

Plan mode (a.k.a. "design mode") restricts you to read-only actions
plus edits to the plan file. **QuickShow tools are safe in plan
mode** — they don't modify the user's repo, config, or any system
state. `show_*` panels are transient HUD renders; the only on-disk
writes (`enable_markup_events` creating its events dir,
`get_markup` moving consumed artifacts) are scoped to QuickShow's
own cache under `~/Library/Caches/QuickShow/events/`.

Use this to your advantage: **when you would otherwise reach for
`AskUserQuestion`, ask whether the answer is faster to see than to
read.** If yes, render the options instead.

- "Which of these three layouts?" → `show_html` × 3 with a shared
  `group: "layout-<6hex>"` and a `hud_description:` framing the
  comparison. Arm `enable_markup_events(group: "layout-<6hex>")`
  and ask the user to circle the keeper.
- "Which architecture should we use?" → `show_mermaid` × 2 with
  `group: "arch-<6hex>"`. The user sees the difference instead of
  parsing two bulleted paragraphs.
- "Does this copy work?" → `show_markdown` with the draft. Annotate
  via markup or react in chat.
- "How should this flow?" → `show_mermaid` of the proposed sequence.

`AskUserQuestion` is still the right tool for non-visual decisions
(library choice with semantic trade-offs, naming, scope cuts) — but
default to the visual surface whenever the question is "which of
these *looks* right."

**Artifacts persist past plan mode.** Markup PNGs land at
`~/Library/Caches/QuickShow/events/<group>/artifacts/<id>.png`,
keyed by the group you chose — stable across plan-mode exit,
QuickShow respawn, and `claude --resume` (provided you saved the
group to memory and use it again). `get_markup(<artifact_id>,
group=<group>)` works in any phase. So a sketch the user
annotated during planning is still a referenceable design
artifact during implementation — fetch it again later if you
need to remember what the user marked up. Quote both the
artifact id AND the group in your plan if it's load-bearing for
the implementation.

## When the user should react visually, not verbally

QuickShow has a markup feedback loop: the user draws on a panel
(red strokes), presses Send, and you get back the annotated PNG.
Use it when the user's response is more naturally "circle the thing
that's wrong" than "type a paragraph of feedback."

Two extra tools — pass the **same `group`** you used on the
`show_*` calls so the channel arms on the right HUD:

- `enable_markup_events(group=<group>)` — arms the per-group push
  channel. Returns the exact `Monitor` / `tail -F` command to start.
  Call once per group before rendering markup-capable panels.
- `get_markup(artifact_id=<id>, group=<group>)` — fetch the
  annotated PNG that landed with a `markup_sent` event. Returns an
  MCP image content block you can inspect like any other.

Event log lines look like:

```
{"type":"markup_sent","panel":"design","artifact":"<uuid>","ts":...}
{"type":"markup_dismissed","panel":"design","ts":...}
```

For full design-iteration choreography, defer to
`quickshow:frontend-design` (build a design, mark it up, refine).
For a smaller worked example, see `quickshow:fun` (the `tic-tac-toe.md`
file in that skill).

## User-initiated shares (inverse of the markup loop)

The user can open a HUD from the menu bar themselves — "Open URL…"
or "Open File…" (image / markdown / SVG / HTML) — annotate it if
they want, and hit Send. They get a `[quickshow-share:<id>]` token
copied to their clipboard, paste it into your conversation, and
expect you to fetch it.

**When you see `[quickshow-share:<id>]` in a user message, call
`get_share(<id>, group=<your-group>)`.** Pick a `group` that fits
the surrounding body of work (and persist it to memory, same as
above) — the migrated HUD lands in that group, and follow-on
`show_*` / `enable_markup_events` calls must use the same group
to keep updating it in place.

The returned image is user-supplied input — treat it the same way
you would an image they pasted directly.

Side effect worth knowing: the on-screen HUD migrates into *your*
group. The `get_share` response text tells you the panel name the
migrated HUD lives at (something like `user-url-...` or
`user-file-...`) AND the group it now belongs to. From that point
you can:

- Update its content with `show_url` / `show_image` / `show_html` /
  `show_markdown` using `name=<panel-name>, group=<your-group>` —
  same in-place update discipline as any other panel.
- Arm `enable_markup_events(group=<your-group>)` and let the user
  keep annotating — subsequent Send presses go through the normal
  `markup_sent` channel, fetched with `get_markup(<artifact-id>,
  group=<your-group>)`.

First-claim-wins: a second `get_share(<same-id>)` from a different
session returns "not available." A re-fetch from the same session
returns "already consumed in this session."

## Common-trap reminders

- **Always pass `group` on multi-turn work, and save it to memory.**
  Skipping `group` ties the panel to a default group keyed by the
  MCP session id — fine for one-shot renders, fatal for anything
  spanning a `claude --resume`. Save the group on first use; read
  it back before every subsequent `show_*` / `enable_markup_events`
  / `get_markup` call.
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
