# QuickShow — Claude project notes

This file is read by Claude Code at session start. It captures stable
knowledge about the project so a fresh session (yours, mine, a sibling
running in parallel) can be productive immediately.

Companion docs:
- `ROADMAP.md` — phase pointer. Read first. v0.1 is complete; new
  work lives outside the original phase list (markup feedback loop,
  HTML renderer, design skill).
- `BACKLOG.md` — unscheduled post-v0.1 ideas. Agent-ready outlines;
  move into ROADMAP.md as a phase when picking one up.
- `PRD.md` — full v0.1 PRD (what + how).
- `~/.claude/plans/mcp-quick-show-v01.md` — long-form plan with the
  *why* behind decisions.
- `docs/control-protocol.md` — wire-protocol reference (parallel to
  PipAnything's `docs/agent-control.md`).
- `docs/adding-a-renderer.md` — three-file pattern for adding a new
  content type (sidecar handler + app renderer + HTML template).

## What this app is

A macOS menu-bar app + TypeScript MCP sidecar that lets agents render
content (markdown, SVG, mermaid, image, HTML) into floating HUD panels
and *see* the rendered result via a screenshot returned through the
MCP tool response.

Beyond render-and-screenshot, the app also supports a **markup
feedback loop**: the user can draw on a panel and Send the annotated
snapshot back to the agent (see "Markup feedback loop" below).

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

In **Debug** builds the sidecar runs from TS source (fast iteration);
the `bun build --compile` step in `tools/build-sidecar.sh` only fires
for **Release**, dropping a standalone `mcp-quick-show` binary into
`QuickShow.app/Contents/Resources/`.

Sidecar dev commands:
```sh
cd sidecar
bun install
bun test                                                  # bun:test suite
bun run typecheck                                         # tsc --noEmit
QUICKSHOW_SOCKET_PATH=/tmp/qs.sock bun run src/cli/ping.ts
```

`.xcodeproj` is **gitignored** — regenerate from `project.yml` after a clone.

Headless verification env vars:
- `QUICKSHOW_SOCKET_PATH` — override control-socket path so multiple
  test instances can run in parallel.
- `QUICKSHOW_NO_AUTOLAUNCH=1` — sidecar skips `open -g` so tests can
  drive a pre-launched app.
- `QUICKSHOW_AUTO_PANEL=1` — on launch, open a HUD with fixture
  markdown for smoke verification.
- `QUICKSHOW_APP_PATH=/path/to/QuickShow.app` — override sidecar's
  app-bundle discovery (default: walk up from execPath, then
  `/Applications`).
- `QUICKSHOW_EVENTS_DIR=/tmp/qs-events` — override the markup events
  + artifacts base dir (default `~/Library/Caches/QuickShow/events/`).
  Used by tests so they don't clobber a real session's log.

## Repo topology

```
mcp-quick-show/
├── project.yml                  xcodegen spec; single .app target
├── tools/
│   ├── build-sidecar.sh         bun build --compile + copy into .app (Release only)
│   ├── copy-resources.sh        copies templates/ + libs/ + scripts/ into bundle
│   └── make-dmg.sh              build + signed-DMG packaging
├── sidecar/                     TypeScript MCP server
│   ├── package.json
│   ├── tests/                   bun:test suite (handlers, socket, paths, markup)
│   └── src/
│       ├── index.ts             MCP bootstrap; routes upsert + raw handlers
│       ├── protocol.ts          wire types (paired with Swift)
│       ├── socket.ts            NDJSON Unix-socket client
│       ├── session.ts           session UUID + markup-paths derivation
│       ├── pathResolver.ts      ~, MIME, size-cap chokepoint
│       ├── autolaunch.ts        locate + open -g the .app bundle
│       ├── handlers/            content-type + raw handlers
│       │   ├── registry.ts      upsert-style + raw-call registries
│       │   ├── markdown.ts svg.ts mermaid.ts image.ts html.ts
│       │   ├── enableMarkupEvents.ts   arms markup push channel
│       │   └── getMarkup.ts            fetches a marked-up artifact PNG
│       └── cli/                 ping.ts + verify-phase*.ts smoke scripts
├── docs/
│   ├── control-protocol.md      wire-protocol reference
│   └── adding-a-renderer.md     three-file pattern for new content types
├── .claude-plugin/
│   └── marketplace.json         declares this repo as a single-plugin marketplace
├── plugin/                      Claude Code plugin tree (distribution)
│   ├── .claude-plugin/plugin.json
│   ├── .mcp.json                quickshow → ${CLAUDE_PLUGIN_ROOT}/bin/mcp-quick-show
│   ├── bin/                     compiled sidecar binary (gitignored; built by tools/build-plugin.sh)
│   ├── skills/quickshow/        foundational "how to use QuickShow" skill
│   ├── skills/frontend-design/  bold-aesthetic design + markup loop
│   └── skills/tic-tac-toe/      demo skill (markup-driven gameplay)
├── QuickShow/                   Swift app
│   ├── Info.plist               LSUIElement
│   ├── Resources/
│   │   ├── templates/           markdown.html / svg.html / mermaid.html / theme.css
│   │   ├── libs/                marked / mermaid / DOMPurify (bundled, inlined)
│   │   └── scripts/             markup-canvas.js (in-DOM stroke capture)
│   └── Sources/
│       ├── App/                 QuickShowApp (@main), AppDelegate
│       ├── Server/              ControlServer / ControlProtocol / ControlHandlers
│       ├── Sessions/            SessionManager — session_id → HUD, reconnect
│       ├── HUD/                 HUDWindow, TabStripView, TitleBarOverlay,
│       │                        ResizeHandle, ZoomableCanvasScrollView, MarkupStroke
│       ├── Renderers/           PanelRenderer + WebViewPanelRenderer +
│       │                        Markdown/SVG/Mermaid/Image/HTML + RendererRegistry
│       ├── Snapshot/            SnapshotService (PNG capture)
│       ├── Events/              EventLogWriter + MarkupPaths (NDJSON event log)
│       ├── Promote/             PromoteToWindowController (HUD → standard window)
│       └── Settings/            Settings + SettingsWindow
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

Current verbs (sidecar → app): `hello`, `ping`, `upsert`, `close`,
`list`, `inspect`, `set_session_flag`. Responses: `ok`,
`render_error`, `protocol_error`.

## Adding a new content type

Three files + two registration lines, all documented in
`docs/adding-a-renderer.md`:

1. `sidecar/src/handlers/<type>.ts` — registers a `ContentTypeHandler`
   (toolName, schema, `validate()`).
2. `QuickShow/Sources/Renderers/<Type>Renderer.swift` — subclass
   `WebViewPanelRenderer` (or implement `PanelRenderer` directly for
   non-WebView).
3. `QuickShow/Resources/templates/<type>.html` — template with
   `<!--QS_*-->` placeholders for inlined bundled libs and a
   `window.__quickshow_render(body)` entry point.

Then add one import line in `sidecar/src/index.ts` and one
`registry.register(...)` line in
`QuickShow/Sources/Renderers/RendererRegistry.swift`.

## Markup feedback loop

Lets a user draw on a HUD panel and Send the annotated snapshot back
to the agent. Two MCP tools (`enable_markup_events` and `get_markup`)
plus a tail-based push channel:

- `enable_markup_events()` flips a per-session `markup_events_armed`
  flag (via `set_session_flag`) and returns a `Monitor`/`tail -F`
  command the agent runs on the events log.
- The HUD's in-DOM canvas (`Resources/scripts/markup-canvas.js`,
  driven by `ZoomableCanvasScrollView`) captures strokes inside the
  WebView. Press **Send** → app composites a flattened PNG, writes
  it as `<artifact-uuid>.png`, and appends a `markup_sent` NDJSON
  line to the events log. Press **Close** → `markup_dismissed` line,
  no artifact.
- `get_markup(artifact_id)` reads the PNG off disk and returns it as
  an MCP image content block.

On-disk layout (override via `QUICKSHOW_EVENTS_DIR`):
```
~/Library/Caches/QuickShow/events/<sessionId>/
├── events.ndjson                 # one event per line
└── artifacts/<artifact-id>.png   # flattened markup snapshots
```

Path derivation lives in `sidecar/src/session.ts` and
`QuickShow/Sources/Events/MarkupPaths.swift` — these are also paired;
keep them in lockstep.

The `skills/quickshow-design` skill is the canonical consumer: render
HTML → arm events → wait for `markup_sent` → fetch + iterate.

## Logging convention

- Swift: all NSLog lines start with `QuickShow: ` (parallel to
  PipAnything's `PiPanything: `).
- Sidecar: all `console.error` lines start with `[mcp-quick-show] ` so
  they're greppable in MCP-server stderr captured by Claude Code.

## Notes for next session

- Check `ROADMAP.md` first — v0.1 is shipped, so new work is
  out-of-band; slot it intentionally rather than absorbing into a
  finished phase.
- Wire-protocol mirror discipline: *don't drift*. Same rule applies to
  the markup-paths pair (`session.ts` ↔ `MarkupPaths.swift`).
- Lift `OverlayWindow` / `ResizeHandle` / tab UI from PipAnything;
  don't reinvent.
- The user runs multiple parallel agent sessions. Multi-sidecar
  coordination (`SessionManager`'s session_id → HUD mapping, per-session
  events dir) is the load-bearing piece — don't regress it.
