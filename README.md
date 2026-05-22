# QuickShow

A macOS menu-bar app + MCP server that gives Claude (and other agents) a
visual output surface. Claude renders content — markdown reports, SVG
or Mermaid diagrams, images, full HTML designs — into a floating HUD
panel you can see and react to. Snapshots come back through the tool
response, so Claude *also* sees what it rendered.

Pair it with the design feedback loop and you draw on the panel, hit
**Send**, and Claude reads the annotated image back. The loop is tight
enough that conversational design iteration actually works.

> **Status: v0.1.1.** Apple-Silicon-only DMG, ad-hoc signed (see
> install notes below). Tracker: [`ROADMAP.md`](ROADMAP.md).

## What's in the box

- **Five render verbs.** `show_markdown`, `show_svg`, `show_mermaid`,
  `show_image`, `show_html`. Each opens or updates a HUD panel keyed
  on `name`, and returns a PNG snapshot of the rendered result.
- **Pan + zoom canvas.** WebView pinned to its natural document size;
  outer scroll view handles pan/zoom/smart-fit so wide content stays
  legible without truncation.
- **Markup feedback loop.** `enable_markup_events` arms an NDJSON
  event log; the panel grows draw/undo/eraser/Send controls; press
  Send and Claude pulls the flattened PNG back via `get_markup`.
  Pickers for stroke color + weight live in the title bar.
- **Interactive panels.** Agent HTML can call
  `window.quickshow.emit({...})` to send structured events back to
  Claude (clicks, form submits, drag/drop). Arm with
  `enable_panel_events`; token-bucket throttled at 20 events/sec/panel.
- **Tabs + sessions.** Each Claude conversation gets its own HUD with
  a tab strip; closing a panel doesn't kill the others. Tear a tab
  out for a floating sub-window; reattach by dropping it back.
- **Claude-Space placement.** New panels open on the Space hosting
  the terminal that runs the Claude session, not whichever Space
  you're looking at. Configurable in Preferences.
- **Claude Code plugin.** Ships an MCP server config plus three
  skills: a foundational `quickshow` skill (how to use the tools),
  `frontend-design` (markup-driven design iteration), and `fun`
  (chess, tic-tac-toe, pictionary, click-demo — all rendered as
  interactive HUD panels).

## Install

### 1. QuickShow.app

Grab the latest DMG from
[Releases](https://github.com/zolat/mcp-quick-show/releases), open
it, and drag **QuickShow.app** into **Applications**.

The DMG is **Apple-Silicon only** and **ad-hoc signed** (no Developer
ID / notarization yet). On first launch Gatekeeper will refuse to
open it — right-click the app in Applications and choose **Open**,
or strip the quarantine attribute:

```sh
xattr -d com.apple.quarantine /Applications/QuickShow.app
```

After launch the QuickShow icon sits in the menu bar. No Dock entry
— this is intentional (`LSUIElement`).

**Recommended: enable "Launch at login"** in QuickShow's
Settings → General. From 0.2.0 onwards the MCP server runs inside
QuickShow.app (HTTP on `127.0.0.1:7890`), so Claude Code can only
reach it when the app is running. Launch-at-login means you don't
have to remember to start QuickShow before opening a Claude
terminal.

### 2. Claude Code plugin

This repo doubles as a Claude Code marketplace. From any project:

```sh
# Add the marketplace
/plugin marketplace add zolat/mcp-quick-show

# Install the plugin
/plugin install quickshow@mcp-quick-show
```

The plugin's `.mcp.json` points at `http://127.0.0.1:7890/mcp`,
the embedded MCP server inside the QuickShow.app process. **Make
sure QuickShow.app is running** (menu-bar icon visible) before
issuing tool calls — Claude Code will report "connection refused"
otherwise. Restart Claude Code after installing the plugin so the
HTTP transport handshake fires.

## Verify

In a Claude Code session with the plugin installed:

```
Render a quick markdown report on something and show it to me.
```

Claude calls `show_markdown`, a HUD panel pops up on your current
Space, and the screenshot comes back so Claude can react to it. From
there: ask it to draw something, design a landing page, or play
chess in the panel.

## Build from source

```sh
xcodegen generate                                        # rebuild .xcodeproj from project.yml
xcodebuild -scheme QuickShow -configuration Debug build  # fast dev build (sidecar runs from TS source)
xcodebuild -scheme QuickShow -configuration Release build # production build (sidecar compiled to binary)
```

```sh
cd sidecar && bun install && bun test                    # run the sidecar test suite
```

## Documentation

- [`ROADMAP.md`](ROADMAP.md) — what's shipped, what's next, what's in backlog
- [`PRD.md`](PRD.md) — original v0.1 product requirements
- [`docs/control-protocol.md`](docs/control-protocol.md) — wire protocol between sidecar and app
- [`docs/adding-a-renderer.md`](docs/adding-a-renderer.md) — three-file pattern for a new content type
- [`CLAUDE.md`](CLAUDE.md) — project notes for AI-agent sessions
