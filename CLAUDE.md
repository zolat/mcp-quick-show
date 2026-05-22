# QuickShow — Claude project notes

This file is read by Claude Code at session start. It captures stable
knowledge about the project so a fresh session (yours, mine, a sibling
running in parallel) can be productive immediately.

Companion docs:
- `ROADMAP.md` — phase pointer. Read first.
- `BACKLOG.md` — unscheduled post-v0.2 ideas. Agent-ready outlines;
  move into ROADMAP.md as a phase when picking one up.
- `PRD.md` — full v0.1 PRD (what + how).
- `~/.claude/plans/mcp-quick-show-v01.md` — long-form plan with the
  *why* behind decisions.
- `HTTP_MIGRATION.md` + `HTTP_MIGRATION_POC_REPORT.md` — 0.2.0
  migration that moved the MCP server from a TypeScript stdio
  sidecar into the Swift app (HTTP transport, in-process).
- `docs/adding-a-renderer.md` — pattern for adding a new content
  type (Swift renderer + HTML template + tool handler).

## What this app is

A macOS menu-bar app with an embedded HTTP MCP server. Lets agents
render content (markdown, SVG, mermaid, image, HTML, URL) into
floating HUD panels and *see* the rendered result via a screenshot
returned through the MCP tool response.

Beyond render-and-screenshot, the app also supports a **markup
feedback loop**: the user can draw on a panel and Send the annotated
snapshot back to the agent (see "Markup feedback loop" below).

The MCP server speaks the Streamable HTTP transport (spec
2025-11-25) on `http://127.0.0.1:7890/mcp`, with a sibling NDJSON
endpoint at `/markup-events` for the per-group live event stream.
QuickShow.app must be running for the Claude Code plugin to reach
it — recommend Launch-at-login in Settings.

Sibling project `~/projects/PipAnything` is the architectural
ancestor (also a Mac menu-bar HUD app). Lifts UI patterns
wholesale — `OverlayWindow`, `ResizeHandle`, the `feat/tabs` work
from `PiPanything-tabs`.

## Build / run

```sh
xcodegen generate                                       # rebuild .xcodeproj from project.yml
xcodebuild -scheme QuickShow -configuration Debug build
APP=$(xcodebuild -showBuildSettings -scheme QuickShow 2>/dev/null \
  | awk -F' = ' '/^[[:space:]]+BUILT_PRODUCTS_DIR = / {print $2}')
"$APP/QuickShow.app/Contents/MacOS/QuickShow"
```

Fast wire smoke (build + drive initialize/tools-list/show_html):

```sh
tools/smoke-http-mcp.sh        # build first
tools/smoke-http-mcp.sh skip   # reuse existing .app
```

`.xcodeproj` is **gitignored** — regenerate from `project.yml` after a clone.

Headless verification env vars:
- `QUICKSHOW_MCP_HTTP=0` — opt out of starting the HTTP MCP server
  (for integration tests that don't touch the wire).
- `QUICKSHOW_MCP_PORT=7891` — override port so multiple test
  instances can run in parallel against the same machine.
- `QUICKSHOW_MCP_IDLE_SECONDS=10` — shrink the cleanup-loop idle
  timeout so liveness/orphan tests don't have to wait 5 minutes.
- `QUICKSHOW_RECONNECT_GRACE_SECONDS=2` — shrink the orphan-grace
  badge timer for the same tests.
- `QUICKSHOW_AUTO_PANEL=1` — on launch, open a HUD with fixture
  markdown for smoke verification.
- `QUICKSHOW_EVENTS_DIR=/tmp/qs-events` — override the markup events
  + artifacts base dir (default `~/Library/Caches/QuickShow/events/`).
  Used by tests so they don't clobber a real group's log.
- `QUICKSHOW_HUD_SPACE_POLICY_OVERRIDE` — `userSpace` / `claudeSpace`
  / `allSpaces` (see "HUD Space placement" below).

## Repo topology

```
mcp-quick-show/
├── project.yml                  xcodegen spec; single .app target
├── tools/
│   ├── copy-resources.sh        copies templates/ + libs/ + scripts/ into bundle
│   ├── make-dmg.sh              build + signed-DMG packaging
│   └── smoke-http-mcp.sh        build + drive initialize/tools-list/show_html
├── docs/
│   └── adding-a-renderer.md     pattern for new content types
├── .claude-plugin/
│   └── marketplace.json         declares this repo as a single-plugin marketplace
├── plugin/                      Claude Code plugin tree (distribution)
│   ├── .claude-plugin/plugin.json
│   ├── .mcp.json                {"type":"http","url":"http://127.0.0.1:7890/mcp"}
│   ├── skills/quickshow/         foundational "how to use QuickShow" skill
│   ├── skills/frontend-design/   bold-aesthetic design + markup loop
│   └── skills/fun/               router skill — one SKILL.md + sibling
│       │                         instruction files (chess.md, tic-tac-toe.md,
│       │                         click-demo.md, pictionary.md)
│       └── chess_helper.py       python-chess wrapper (board state, legal
│                                 moves, HTML render) used by fun/chess.md
├── QuickShow/                   Swift app
│   ├── Info.plist               LSUIElement
│   ├── Resources/
│   │   ├── templates/           markdown.html / svg.html / mermaid.html / theme.css
│   │   ├── libs/                marked / mermaid / DOMPurify (bundled, inlined)
│   │   └── scripts/             markup-canvas.js (in-DOM stroke capture),
│   │                            quickshow-bridge.js (window.quickshow.emit shim)
│   └── Sources/
│       ├── App/                 QuickShowApp (@main), AppDelegate
│       ├── MCP/                 MCPHTTPServer / MCPHTTPParser / MCPSessionRouter /
│       │                        MCPToolHandlers / MCPToolValidation /
│       │                        MarkupEventsStream
│       ├── Sessions/            SessionManager — group → HUD, orphan-grace
│       ├── HUD/                 HUDWindow, TabStripView, TitleBarOverlay,
│       │                        ResizeHandle, ZoomableCanvasScrollView, MarkupStroke
│       ├── Renderers/           PanelRenderer + WebViewPanelRenderer +
│       │                        Markdown/SVG/Mermaid/Image/HTML/URL + RendererRegistry
│       ├── Snapshot/            SnapshotService (PNG capture)
│       ├── Events/              EventLogWriter + MarkupPaths (NDJSON event log)
│       │                        + PanelEventThrottle (per-panel token bucket)
│       ├── Space/               PeerPidResolver (libproc) + SpaceResolver + CGSPrivate
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

## Worktrees for substantial work

All substantial work happens in a git worktree, not the main
checkout. Use `/feature` to spin one up; it isolates the change,
keeps `main` clean, and lets parallel agent sessions on this repo
not stomp on each other. Trivial edits (typo, one-line tweak,
docs-only) can go straight on `main`; anything that involves
multi-file changes, new code, refactors, or that you'd want to
verify end-to-end → worktree. Merge back to `main` after the work
is verified and the user approves.

## Group is the canonical content namespace

Phase 2 (0.2.0) moved panel storage from "per MCP session" to "per
group". Each `show_*` tool takes an optional `group` arg; when
omitted, the handler defaults it to the MCP session id so old
behaviour is preserved for one-shot renders. Skills opt into a
named group when work spans multiple turns — that group is the
identity that survives `claude --resume`.

Storage shape:
- `SessionManager.groups: [String: GroupState]` — keyed by group.
- `GroupState` holds the HUD list, flags, events writer, and
  `lastWriterMcpSession` (last MCP session that wrote into this
  group). The latter drives orphan-grace.
- `MCPSessionRouter.SessionState` tracks the MCP session itself —
  Server, transport, claudePid, lastAccessedAt. Orthogonal to
  GroupState.

Liveness signals:
- DELETE on `/mcp` → router drops the session immediately.
- Cleanup loop (60s tick) → drops any session idle past
  `QUICKSHOW_MCP_IDLE_SECONDS` (default 5 min).
- Both call `onSessionRemoved`, which walks groups for a matching
  `lastWriterMcpSession` and starts an orphan-grace timer
  (`QUICKSHOW_RECONNECT_GRACE_SECONDS`, default 60s).

User-share migration: each user-initiated HUD ("Open URL…",
"Open File…") spawns a `user-share-<random>` group via
`SessionManager.userSharesGroupPrefix`. `claim_share` walks those
groups for the matching `sourceHudId` and migrates the HUD into
the Claude-specified `targetGroup`.

## Adding a new content type

Documented in `docs/adding-a-renderer.md`:

1. `QuickShow/Sources/Renderers/<Type>Renderer.swift` — subclass
   `WebViewPanelRenderer` (or implement `PanelRenderer` directly
   for non-WebView).
2. `QuickShow/Resources/templates/<type>.html` — template with
   `<!--QS_*-->` placeholders for inlined bundled libs and a
   `window.__quickshow_render(body)` entry point.
3. Add a tool handler in
   `QuickShow/Sources/MCP/MCPToolHandlers.swift` (validate args
   via the `ToolValidation` helpers, dispatch through
   `SessionManager.upsert`).

Then add one `registry.register(...)` line in
`QuickShow/Sources/Renderers/RendererRegistry.swift` and one
`tools` entry in `MCPToolHandlers.register(...)`.

## Markup feedback loop

Lets a user draw on a HUD panel and Send the annotated snapshot back
to the agent. Two MCP tools (`enable_markup_events` and `get_markup`)
plus a tail-based push channel:

- `enable_markup_events(group)` flips a per-group
  `markup_events_armed` flag and returns a `curl -sN` Monitor
  command pointed at `/markup-events` (NDJSON push channel, lives
  outside the SDK's `/mcp` route because the SDK transport
  enforces a single SSE per session and Claude Code's client
  claims that slot).
- The HUD's in-DOM canvas (`Resources/scripts/markup-canvas.js`,
  driven by `ZoomableCanvasScrollView`) captures strokes inside
  the WebView. Press **Send** → app composites a flattened PNG,
  writes it as `<artifact-uuid>.png`, and appends a `markup_sent`
  NDJSON line to the events log. Press **Close** →
  `markup_dismissed` line, no artifact.
- `get_markup(artifact_id, group)` reads the PNG off disk and
  returns it as an MCP image content block.

On-disk layout (override via `QUICKSHOW_EVENTS_DIR`):
```
~/Library/Caches/QuickShow/events/<group>/
├── events.ndjson                 # one event per line
└── artifacts/<artifact-id>.png   # flattened markup snapshots
```

Path derivation lives in `QuickShow/Sources/Events/MarkupPaths.swift`.

The `plugin/skills/frontend-design` skill is the canonical
consumer: render HTML → arm events → wait for `markup_sent` →
fetch + iterate. `plugin/skills/quickshow` documents the wider
"reach for it when…" surface and the memory-save pattern for
group-aware multi-turn work.

## Panel event channel

Sibling of the markup loop. Lets agent-supplied HTML emit structured
events back to Claude — turning `show_html` panels into real
two-way UIs (click-to-act, form submission, drag/drop) instead of
PNG-with-arrows markup.

- `enable_panel_events(group)` flips `panel_events_armed` on the
  group and returns a `tail -F` Monitor command pointed at the
  group's `events.ndjson`. Independent of `enable_markup_events`:
  arm one, the other, or both — all events share the group's
  events log.
- A third script-message channel — `panelEvent`, peer of
  `renderComplete` and `markupStroke` — on every WebView. Wired in
  `WebViewPanelRenderer.makeView()`.
- `QuickShow/Resources/scripts/quickshow-bridge.js` is injected as a
  `WKUserScript` at `.atDocumentStart` so `window.quickshow.emit`
  is defined before agent inline scripts run. Works for both
  `loadHTMLString`-driven `show_html` panels and template-based
  renderers (markdown / svg / mermaid / image).
- Persistence is gated twice:
  1. `groupState.flags["panel_events_armed"]?.asBool` — symmetric
     with how the Send button is gated.
  2. `PanelEventThrottle` (`QuickShow/Sources/Events/`): token
     bucket, capacity 20 events/sec/panel. Excess emits drop and a
     1Hz `panel_event_dropped {panel, dropped}` summary line lands
     in the log when drops occurred. No drops → no summary.
- Line shapes (`events.ndjson`):
  ```json
  {"type":"panel_event","panel":"<name>","payload":<json>,"ts":<ms>}
  {"type":"panel_event_dropped","panel":"<name>","dropped":<n>,"ts":<ms>}
  ```
  `payload` is whatever the page passed; semantics live in the
  skill + the rendered HTML, not in the app or sidecar.
- Pointer-events caveat: while the user is in markup draw mode the
  in-DOM canvas swallows clicks, so `quickshow.emit` only fires
  when the user is *not* drawing. Same trade-off the markup loop
  has lived with.

Canonical consumer: `plugin/skills/fun/click-demo.md` (inside the
`fun` router skill) — minimal HTML page, one button, one emit, one
re-render.

## HUD Space placement

`Settings.hudSpacePolicy` (replaces v0.1's `pinHudsToCurrentSpace`
bool) is a three-way enum that controls where new HUDs open across
macOS Spaces. v0.2 default is `.claudeSpace` — panels open on the
Space hosting the terminal that runs the Claude session, not the
Space the user is currently looking at.

The placement uses private CGS APIs (`CGSMoveWindowsToManagedSpace`
et al.), wrapped in `QuickShow/Sources/Space/CGSPrivate.swift` via
`dlopen` + `dlsym`. Notarization is fine; App Store distribution
isn't (the project ships via DMG, so this is acceptable). Symbol
missing on a future macOS → `CGSPrivate.isAvailable` flips false →
`SpaceResolver` no-ops and the OS picks the Space.

Resolution chain (per group, on **first HUD create only**):
1. Walk up the process tree from `parentPid` (libproc-resolved
   from the Claude Code MCP client's socket on first
   `initialize`, stashed on the GroupState by `registerGroup`)
   using `sysctl(KERN_PROC_PID)` to collect ancestor PIDs.
2. Enumerate `CGWindowListCopyWindowInfo` and pick the first
   ancestor-owned window with `kCGWindowLayer == 0` (a normal
   terminal window — `Terminal.app`, iTerm2, Ghostty, WezTerm,
   Alacritty, etc., no hardcoded names).
3. `CGSCopySpacesForWindows` → Space id.
4. Fallback chain: per-group `lastResolvedSpaceID` cache →
   `CGSGetActiveSpace` → skip placement.

The placement is called **three times** in `ensurePrimaryHud`:
before `makeKeyAndOrderFront`, immediately after, and again from
the next main-queue tick. The double-after-call is empirically
required: AppKit's `makeKeyAndOrderFront` resets the window's
Space to the active one after we've moved it. The second call
catches that. Diagnostic NSLog data lives in the v0.2 ship commit
if you ever need to re-verify the race.

`HUDWindow.collectionBehavior` drops `.fullScreenAuxiliary` for
`.claudeSpace` — that flag couples a window to whatever Space
hosts the current fullscreen/Stage Manager presentation and
fights `CGSMoveWindowsToManagedSpace`. `.userSpace` keeps the
v0.1 `.fullScreenAuxiliary`; `.allSpaces` keeps the v0.1
`[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`.

Tear-out HUDs are NOT moved — they spawn under the cursor during
a user-initiated drag, so they're already where the user wants
them. The placement only applies to the primary HUD's birth.

`registerGroup(_:parentPid:)` retains the parent_pid on the
`GroupState`. A fresh `initialize` from a new MCP session
(e.g. `claude --resume` from a different terminal) refreshes it
through the same path.

Test override: `QUICKSHOW_HUD_SPACE_POLICY_OVERRIDE` accepts the
raw enum string (`userSpace`, `claudeSpace`, `allSpaces`).

## Logging convention

All NSLog lines start with `QuickShow: ` (parallel to PipAnything's
`PiPanything: `).

## Notes for next session

- Check `ROADMAP.md` first.
- The user runs multiple parallel agent sessions. Per-group state
  (`groups[]`) is the load-bearing isolation; per-MCP-session
  state (`MCPSessionRouter.sessions`) is orthogonal and only used
  for liveness + placement.
- SourceKit indexer in this Swift project produces persistent
  false-positive "Cannot find type X in scope" diagnostics for
  same-module symbols (especially right after a `project.yml`
  change or new `.swift` file). Trust `xcodebuild` as the compile
  oracle; treat in-IDE / SourceKit output as advisory. Re-run
  `xcodegen generate` if the indexer is wildly stale.
- For cryptic mid-session MCP errors, probe the running app via
  `curl http://127.0.0.1:7890/mcp` with a hand-rolled `initialize`
  frame to confirm what the live process speaks, before assuming
  a wire bug. The smoke script (`tools/smoke-http-mcp.sh`) is the
  canonical 10s sanity check.
- Lift `OverlayWindow` / `ResizeHandle` / tab UI from PipAnything;
  don't reinvent.
