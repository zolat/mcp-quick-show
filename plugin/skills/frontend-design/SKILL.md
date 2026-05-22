---
name: frontend-design
description: Create distinctive, production-grade frontend interfaces — rendered live in a floating QuickShow HUD panel and refined through a tight markup feedback loop. Use when the user asks for a landing page, hero, dashboard, web component, marketing site, brand portal, identity sketch, or any visual design they want to see and react to rather than describe. Generates creative, polished code that avoids generic AI aesthetics. Works inside Claude Code's plan mode — the render → markup → re-render loop is the natural way to converge on a design *before* writing any implementation code.
---

This skill turns Claude into a designer with a tight feedback loop:
render → user annotates → re-render. The point is for the user to
*see and draw on* what they're shown, not chat about it. Implement
real working HTML/CSS/JS with exceptional attention to aesthetic
detail and creative choices — and ship it through QuickShow so the
user can react visually.

The creative-direction guidance below is adapted from Anthropic's
`frontend-design` skill (`~/.claude/plugins/.../frontend-design/`).
The QuickShow rendering surface and feedback loop are this skill's
addition.

## The loop

1. **Pick a `group` and save it to memory.** Every call below uses
   the same `group` — pick a unique slug for this design session
   (e.g. `"design-a3f"`, `"coffee-coop-<6hex>"`) and **save it to
   memory immediately** so a follow-up `claude --resume` reads it
   back instead of generating a fresh one. See the
   `quickshow/SKILL.md` "memory-save pattern" section.
2. **Decide the aesthetic direction up front.** See "Design
   thinking" below.
3. **Generate a self-contained HTML document.** Inline everything —
   styles, scripts, fonts, images. The QuickShow renderer blocks
   network requests by design; no remote CDN, fonts, or images will
   resolve.
4. **Render via `show_html(name=…, group=<your-group>, width=…)`.**
   Pick a `name` you'll reuse for the life of this design session
   (e.g. `"design"`, `"coffee-coop-hero"`). Set `width` to match
   the design's intended canvas: 1280 for desktop, 800 for narrower
   content, 375 for mobile mocks. Without `width`, the canvas
   defaults to ~400pt — too narrow for most designs.
5. **Arm feedback once.** Call `enable_markup_events(group=<your-
   group>)` at the start of the session. The response includes the
   exact `Monitor` / `tail -F` command — **start it** so markup
   events stream as notifications.
6. **Wait for the user.** They'll either:
   - **Send (✓):** approving the current state, or marking it up.
     A `markup_sent` event lands with an `artifact` UUID.
   - **Close (×):** walking away. A `markup_dismissed` event lands.
   - **Type chat feedback:** react as usual.
7. **On `markup_sent`:** call `get_markup(artifact_id=<id>,
   group=<your-group>)`. Inspect the annotated image literally —
   red strokes are the user's marks (circles, arrows, scribbles,
   X-outs). Read them, decide what they mean, and iterate with
   another `show_html(name=…, group=<your-group>, …)` call against
   the same `name` + `group`. Write **one sentence** describing
   what you changed.
8. **On `markup_dismissed`:** ask what direction the user wants
   next.

## Plan-mode usage

This loop is plan-mode-safe and the artifacts persist post-plan —
see the **"Plan mode & 'show, don't ask'"** section in
`quickshow/SKILL.md` for the rationale, the substitution patterns
versus `AskUserQuestion`, and the on-disk artifact path. Specific
to the design loop: if a particular `markup_sent` annotation is
load-bearing for the implementation, quote both its `artifact_id`
AND the `group` in your plan so future-you can refetch it with
`get_markup(<id>, group=<group>)` after plan mode ends.

## Design thinking

Before coding, commit to a BOLD aesthetic direction:

- **Purpose** — what problem does this interface solve, for whom?
- **Tone** — pick an extreme and commit: brutally minimal,
  maximalist chaos, retro-futuristic, organic, luxury,
  playful/toy-like, editorial, brutalist/raw, art deco, soft/pastel,
  industrial/utilitarian, anti-design. There are many flavors —
  pick one true to the subject, don't blend.
- **Constraints** — technical, accessibility, performance.
- **Differentiation** — what makes this UNFORGETTABLE? What's the
  one thing someone will remember a week later?

**CRITICAL**: choose a clear conceptual direction and execute it
with precision. Bold maximalism and refined minimalism both
work — the key is *intentionality*, not intensity.

If the brief is open-ended, decide based on the subject and tell the
user up front which direction you're trying. Don't average across
options.

## Frontend aesthetics guidelines

- **Typography** — distinctive, characterful font choices that
  elevate the design. Pair a strong display face with a refined
  body face. Avoid the generic stack (Inter, Roboto, Arial, system
  defaults *unless the design specifically calls for them*). System
  serifs (Georgia, Times New Roman, Iowan Old Style, New York) and
  display sans (Helvetica Neue, SF Pro Display) are fair game on
  macOS. For something specific, inline a font via `@font-face {
  src: url('data:font/woff2;base64,...'); }`.
- **Color & theme** — cohesive aesthetic, CSS variables for
  consistency. **Dominant colors with sharp accents outperform
  timid, evenly-distributed palettes.**
- **Motion** — animations for effects and micro-interactions. CSS-
  only when possible. One well-orchestrated page load with
  staggered reveals creates more delight than scattered
  micro-interactions. Surprise on hover and scroll.
- **Spatial composition** — unexpected layouts. Asymmetry. Overlap.
  Diagonal flow. Grid-breaking elements. Generous negative space OR
  controlled density.
- **Backgrounds & visual details** — atmosphere and depth over flat
  fills. Gradient meshes, noise textures, geometric patterns,
  layered transparencies, dramatic shadows, decorative borders,
  custom cursors, grain overlays.
- **Real content, not lorem ipsum.** Write the copy the design
  needs.

NEVER use generic AI-generated aesthetics — overused fonts (Inter,
Roboto, Arial), cliched color schemes (purple gradients on white),
predictable layouts, cookie-cutter components. Vary across
generations: different fonts, different palettes, different
aesthetics. **Never converge on common choices** (Space Grotesk,
for example) across runs.

**Match implementation complexity to the aesthetic vision.**
Maximalist designs need elaborate code with extensive animations
and effects. Minimalist designs need restraint, precision, and
attention to spacing, typography, and subtle detail. Elegance comes
from executing the vision well, not from holding back.

Claude is capable of extraordinary creative work. Don't hold back.

## Starter shape (adapt the aesthetic; don't ship verbatim)

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>…</title>
  <style>
    :root { --ink: #0a0a0a; --paper: #f6f4ee; --accent: #d83a2c; }
    html, body { margin: 0; padding: 0;
                 background: var(--paper); color: var(--ink);
                 font-family: -apple-system, "Helvetica Neue", system-ui, sans-serif;
                 font-feature-settings: "ss01", "case"; }
    /* … real design styles here … */
  </style>
</head>
<body>
  <!-- Real layout, real copy, real hierarchy. -->
  <script>
    // Optional. Inline only. No external imports.
  </script>
</body>
</html>
```

## QuickShow constraints (restated for emphasis)

- **No remote anything.** No `<link>` to Google Fonts, no Tailwind
  CDN, no jsdelivr, no unpkg, no remote `<img>`. Network requests
  silently fail.
- **Inline fonts** via `@font-face { src: url('data:font/woff2;base64,...'); }`.
- **Inline SVG** for icons; `data:image/png;base64,...` for raster.
- **Width budget** — set the `width` argument on `show_html` to
  match the design canvas (typically 800–1600). The HUD adds pan +
  zoom around it.
- **No alerts/confirms/prompts** in scripts — they freeze the
  WebView.

## Worked-example briefs

If the user gives you an open-ended ask:

- **"Brand identity portal for a sustainable coffee co-op."**
  Editorial, lots of whitespace, one strong serif, hand-drawn icons
  (inline SVG).
- **"Onboarding flow for a CLI tool's web companion."** Monospaced
  display type, terminal-inspired palette, big numbered steps, a
  code block styled like a code block.
- **"Mars-tourism landing page, brutalist aesthetic."** Anti-design
  grid, oversized Helvetica, raw rules, single accent, copy that
  takes itself seriously.
- **"Dashboard mock for an indie SaaS — billing summary view."**
  Restrained, Swiss-aligned numerals, faux data that looks
  plausible, no skeumorphic chrome.

## Etiquette

- **Don't narrate the HTML.** Render it. The user wants to *see*,
  not read code.
- **One sentence per iteration** describing what you changed. The
  user already sees the result.
- **Treat a `markup_sent` with no annotations as "approved
  as-is"** — confirm and offer next steps.
- **If a mark is genuinely ambiguous** (circle around an empty area
  with no obvious target), ask what they meant rather than guess
  wildly.
