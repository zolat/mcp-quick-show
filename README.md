# QuickShow / mcp-quick-show

A macOS menu-bar app + MCP server that lets AI agents render content
(markdown, SVG, mermaid diagrams, images) into floating HUD panels —
and *see* the rendered result via a screenshot returned through the
MCP tool response.

Status: **v0.1 in development.** See `ROADMAP.md` for the current
phase.

## Build

```sh
xcodegen generate
xcodebuild -scheme QuickShow -configuration Debug build

cd sidecar && bun install
```

## Documentation

- `PRD.md` — v0.1 product requirements doc
- `docs/control-protocol.md` — wire protocol between sidecar and app
- `CLAUDE.md` — project notes for AI-agent sessions
