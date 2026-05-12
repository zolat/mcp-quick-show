# quickshow-design

A Claude Code skill that turns the QuickShow MCP server into a tight
design-iteration loop: Claude renders a self-contained HTML/CSS design
into a floating HUD panel, arms the markup-events feedback channel,
and iterates based on the annotations you draw on top of the result.

## Prerequisites

- **QuickShow.app** built and installed (one-time `xcodegen generate` +
  `xcodebuild` from the repo root, then drag the `QuickShow.app`
  bundle into `/Applications`).
- **The `mcp-quick-show` MCP server** wired into your Claude Code MCP
  config. The sidecar autolaunches the app on first call.

## Install

```sh
cp -r skills/quickshow-design ~/.claude/skills/
```

Restart Claude Code (or `/clear`) to pick up the new skill.

## Use

In any Claude Code session, invoke the skill with a design brief:

```
/quickshow-design Design a landing page hero for a sustainable
coffee co-op — editorial aesthetic, system serif.
```

What happens:

1. Claude generates a self-contained HTML/CSS document.
2. A floating HUD panel appears on your screen with the rendered
   design.
3. Claude calls `enable_markup_events()` and starts watching for
   markup events.
4. The HUD's title bar gets two new buttons:
   - **✏︎** — toggle markup-draw mode. Cursor turns into a crosshair;
     draw red strokes over the design to annotate.
   - **✓** — send the current state (design + your strokes) back to
     Claude as a PNG.
5. Claude reads your annotated PNG, iterates, and re-renders.

## Constraints to know about

The `show_html` renderer accepts any HTML you'd put on a webpage —
**except** that network requests are blocked. No Google Fonts via
`<link>`, no CDN scripts, no remote images. Inline everything:

- Fonts: `@font-face { src: url('data:font/woff2;base64,…'); }`
- Images: `data:image/png;base64,…` URIs or omit them.
- Scripts and styles: inline `<style>` and `<script>` blocks.

The skill prompt drills this into Claude with examples, but if you
notice missing fonts in a render, that's the usual cause — ask Claude
to inline the font (or fall back to a system stack).
