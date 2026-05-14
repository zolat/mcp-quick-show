# QuickShow plugin for Claude Code

Renders visual content (markdown, SVG, Mermaid, images, HTML) into
floating macOS HUD panels and returns a screenshot so the agent can
see what it just made. Pairs with a markup feedback loop: the user
draws on the panel, presses Send, the agent reads the annotated PNG
and iterates.

## What you get

**MCP tools** (registered as `mcp__quickshow__*`):

| Tool | When to reach for it |
| --- | --- |
| `show_markdown` | Long-form report the user should *see*, not dig out of the transcript. |
| `show_mermaid` | Architecture, flow, sequence, state diagrams. |
| `show_svg` | Inline visualizations, hand-drawn schematics, annotated images. |
| `show_image` | Surface an existing PNG/JPEG file on disk. |
| `show_html` | Full designs that need CSS/JS/layout (landing pages, dashboards). |
| `enable_markup_events` | Arm the markup push channel for the session. |
| `get_markup` | Fetch an annotated panel snapshot by artifact id. |

**Skills**:

- `quickshow:quickshow` — foundational guidance on which tool to use
  when. Auto-invoked for tasks involving diagrams, long-form output,
  or visual designs.
- `quickshow:frontend-design` — distinctive, production-grade frontend
  design rendered through QuickShow with a tight annotation
  feedback loop. Adapted from Anthropic's frontend-design skill.
- `quickshow:tic-tac-toe` — play tic-tac-toe with Claude in a HUD
  panel. The user marks their move on the rendered board; Claude
  reads the annotation and plays back. Fun demo of the feedback loop.

## Prerequisites

1. **`QuickShow.app`** installed at `/Applications/QuickShow.app` (or
   anywhere — set `QUICKSHOW_APP_PATH` to the bundle path). The
   sidecar auto-launches it on first MCP call. Build from source:

   ```sh
   cd ~/projects/mcp-quick-show
   xcodegen generate
   xcodebuild -scheme QuickShow -configuration Release build
   ```

2. **`bun`** on `PATH` — only required for building the plugin
   sidecar binary. Not required at run time once the binary is built.

## Build the bundled sidecar

The MCP server binary is gitignored; build it before first install:

```sh
./tools/build-plugin.sh
```

This drops `plugin/bin/mcp-quick-show` (a standalone macOS arm64
binary, no runtime dependencies). The plugin's `.mcp.json` points
Claude Code at it via `${CLAUDE_PLUGIN_ROOT}`.

## Install locally

The repo root contains a `.claude-plugin/marketplace.json` describing
this directory as a single-plugin marketplace. Register it once, then
install:

```text
/plugin marketplace add /Users/zolat/projects/mcp-quick-show
/plugin install quickshow@mcp-quick-show
```

Restart Claude Code or `/clear`. Run `/mcp` — you should see
`quickshow` listed with the seven tools.

`/plugin update quickshow@mcp-quick-show` re-reads from the source
tree if you edit the plugin in place.

## Smoke test

In a fresh Claude Code session:

- "Render a Mermaid diagram of a producer-consumer queue." → expect
  `show_mermaid` and a HUD panel.
- "Design a brutalist landing page for a Mars-tourism startup." →
  expect `show_html` + `enable_markup_events` and a HUD with the
  page; draw on it and press Send.
- "Play tic-tac-toe with me." → expect a 3×3 SVG board; draw an X in
  a cell and press Send.

## Where things land

| Path | Purpose |
| --- | --- |
| `~/Library/Application Support/QuickShow/control.sock` | Unix socket the sidecar uses to talk to the app. |
| `~/Library/Caches/QuickShow/events/<session>/events.ndjson` | NDJSON log of `markup_sent` / `markup_dismissed` events. |
| `~/Library/Caches/QuickShow/events/<session>/artifacts/<id>.png` | Flattened markup snapshots, fetched by `get_markup`. |

Override via env vars: `QUICKSHOW_SOCKET_PATH`, `QUICKSHOW_EVENTS_DIR`,
`QUICKSHOW_APP_PATH`, `QUICKSHOW_NO_AUTOLAUNCH=1`.

## Project home

Source, issues, and roadmap: https://github.com/zolat/mcp-quick-show
(or wherever the canonical repo lives).
