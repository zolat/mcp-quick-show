# QuickShow — Claude project notes

This file is read by Claude Code at session start. It captures stable
knowledge about the project so a fresh session (yours, mine, a sibling
running in parallel) can be productive immediately.

Companion docs:
- `ROADMAP.md` — phase pointer. Read first.
- `PRD.md` — full v0.1 PRD (what + how).
- `~/.claude/plans/mcp-quick-show-v01.md` — long-form plan with the
  *why* behind decisions.
- `docs/control-protocol.md` — wire-protocol reference (parallel to
  PipAnything's `docs/agent-control.md`).

## What this app is

A macOS menu-bar app + TypeScript MCP sidecar that lets agents render
content (markdown, SVG, mermaid, images) into floating HUD panels and
*see* the rendered result via a screenshot returned through the MCP
tool response.

Sibling project `~/projects/PipAnything` is the architectural ancestor
(also a Mac menu-bar HUD app with a sidecar binary). Lifts a lot of
patterns wholesale — especially `ControlServer`, `OverlayWindow`,
`ResizeHandle`, and the `feat/tabs` work from `PiPanything-tabs`.

## Build / run

```sh
xcodegen generate                                       # rebuild .xcodeproj from project.yml
xcodebuild -scheme QuickShow -configuration Debug build
APP=$(xcodebuild -showBuildSettings -scheme QuickShow 2>/dev/null \
  | awk -F' = ' '/^[[:space:]]+BUILT_PRODUCTS_DIR = / {print $2}')
"$APP/QuickShow.app/Contents/MacOS/QuickShow"
```

Sidecar (TS) runs from source in Debug:
```sh
cd sidecar && bun install
QUICKSHOW_SOCKET_PATH=/tmp/qs.sock bun run src/cli/ping.ts
```

`.xcodeproj` is **gitignored** — regenerate from `project.yml` after a clone.

Headless verification env vars:
- `QUICKSHOW_SOCKET_PATH` — override control-socket path so multiple
  test instances can run in parallel.
- `QUICKSHOW_NO_AUTOLAUNCH=1` — sidecar skips `open -g` so tests can
  drive a pre-launched app.
- `QUICKSHOW_AUTO_PANEL=1` — (Phase 1+) on launch, open a HUD with
  fixture markdown for smoke verification.
- `QUICKSHOW_APP_PATH=/path/to/QuickShow.app` — override sidecar's
  app-bundle discovery (default: walk up from execPath, then
  `/Applications`).

## Repo topology

```
mcp-quick-show/
├── project.yml                  xcodegen spec; single .app target
├── tools/build-sidecar.sh       bun build --compile + copy into .app
├── sidecar/                     TypeScript MCP server
│   ├── package.json
│   └── src/
│       ├── index.ts             MCP bootstrap
│       ├── protocol.ts          wire types (paired with Swift)
│       ├── socket.ts            NDJSON Unix-socket client
│       ├── session.ts           session UUID store
│       ├── autolaunch.ts        locate + open -g the .app bundle
│       ├── handlers/            (Phase 1+) content-type handlers
│       └── cli/ping.ts          standalone ping client for verification
├── docs/control-protocol.md     wire-protocol reference
├── QuickShow/                   Swift app
│   ├── Info.plist               LSUIElement
│   └── Sources/
│       ├── App/                 QuickShowApp (@main), AppDelegate
│       ├── Server/              ControlServer / ControlProtocol / ControlHandlers
│       ├── (Phase 1+) HUD/      HUDWindow, TabStripView
│       ├── (Phase 1+) Renderers/ PanelRenderer + WebViewPanelRenderer + Markdown/SVG/Mermaid/Image
│       └── (Phase 1+) Snapshot/ SnapshotService
├── ROADMAP.md                   phase pointer
├── PRD.md
├── CLAUDE.md                    this file
└── README.md
```

## Shipping

Direct push to `main`. No PRs, no feature branches — commit on
`main`, `git push origin main`. Force-push is not allowed (use
`git filter-repo` + a fresh push only for one-time history fixes
agreed with the human).

## Wire-protocol mirror discipline

`QuickShow/Sources/Server/ControlProtocol.swift` and
`sidecar/src/protocol.ts` are paired. **Change both in the same
commit.** Borrowed from PipAnything's CLAUDE.md.

## Logging convention

- Swift: all NSLog lines start with `QuickShow: ` (parallel to
  PipAnything's `PiPanything: `).
- Sidecar: all `console.error` lines start with `[mcp-quick-show] ` so
  they're greppable in MCP-server stderr captured by Claude Code.

## Notes for next session

- Check `ROADMAP.md` first.
- Wire-protocol mirror discipline: *don't drift*.
- Lift `OverlayWindow` / `ResizeHandle` / tab UI from PipAnything;
  don't reinvent.
- The user runs multiple parallel agent sessions. The multi-sidecar
  coordination *must* work day-1 of Phase 4 because they'll exercise it
  immediately.
