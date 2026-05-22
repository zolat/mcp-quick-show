# HTTP MCP Migration Spec

A spec for replacing QuickShow's stdio MCP sidecar with an HTTP MCP
server embedded directly in QuickShow.app, **and** for splitting
today's conflated "session" concept into two clean ones: **placement
identity** (server-derived from the connecting Claude's PID) and
**content identity** (Claude-set `group` field, persisted in Claude's
own memory).

This is a substantial refactor. Phase 1 is a de-risking PoC that
must answer three concrete proof-points before Phase 2 is greenlit.

The agent picking this up should read `CLAUDE.md`, `ROADMAP.md`,
`BACKLOG.md`, and `PRD.md` first, then spin up a worktree (`/feature
http-mcp-poc`) per the project's worktree rule for substantial work.

## Goal

End-state:

- **One process**: QuickShow.app, with the MCP server embedded
  inside it on a localhost port.
- **One language**: Swift. No separate `mcp-quick-show` binary, no
  TS sidecar, no TS↔Swift wire-protocol mirror.
- **Two cleanly separated identities** that today's `session_id`
  conflates:
  - **Placement identity** — server-derived from the connecting
    Claude process's PID via macOS `libproc` APIs. Opaque to
    Claude. Decides which Space / terminal a new HUD opens on.
    Same downstream pipeline as today's `.claudeSpace` placement
    from the connecting PID onward; only the *source* of the PID
    changes (libproc lookup over TCP instead of `hello.parent_pid`
    over Unix socket).
  - **Content identity** — Claude-set `group` field on every
    `show_*` call. Persisted in Claude's own conversation context
    and memory. Decides what counts as "the same body of work"
    across panel updates, sessions, and `claude --resume`. Today's
    optional `group` field becomes the canonical namespace; the
    implicit per-session namespace goes away.

## Why this exists

Three recurring problems in the `.claude/retros/archive/` log:

1. **Stale-binary cycle.** Every TS-side edit requires
   `tools/build-plugin.sh` to rebuild the bun binary AND a refresh
   of the cached plugin install at `~/.claude/plugins/cache/...`
   AND a `/restart` of Claude Code before the change takes effect.
   Three retros in May 2026 hit this class of bug. Partially
   mitigated by the `QUICKSHOW_DEV_SIDECAR=1` shim in commit
   `4636a88` (kills the rebuild step but the cache refresh + restart
   remain).
2. **Wire-protocol mirror discipline.** `sidecar/src/protocol.ts`
   and `QuickShow/Sources/Server/ControlProtocol.swift` must be
   edited in the same commit; recently extended to a third paired
   file (`sidecar/src/handlers/_groupingFields.ts`). Drift hazard
   grows linearly with shared concepts.
3. **Session allocator complexity.** `ControlServer.allocateSessionId`
   does live-FD contest checks because session IDs are *claims*
   (the sidecar discovers a conversation UUID via JSONL walking
   and presents it). Pure defensive engineering against a problem
   the placement/content split dissolves entirely.

Plus: the bun runtime is ~60 MB in every plugin distribution.

## End-state architecture

### Process / transport

- QuickShow.app embeds a Swift HTTP MCP server bound to
  `127.0.0.1:7890` (override via `QUICKSHOW_MCP_PORT`).
  Localhost-only. No remote binding ever.
- Plugin `.mcp.json`:
  `{"mcpServers": {"quickshow": {"type": "http", "url": "http://localhost:7890/mcp"}}}`.
  No binary spawned, no launcher, no `plugin/bin/`.
- MCP tool handlers live in Swift, calling the existing
  renderer/HUD/session code directly. No wire protocol. No socket.
- `sidecar/` directory deleted entirely. `tools/build-plugin.sh`
  and `tools/build-sidecar.sh` deleted.
- Auto-launch is replaced by "QuickShow.app must be running before
  MCP tools work." Prefs panel toggle for "Launch at login" via
  `SMAppService` (macOS 13+).

### Placement identity (server-derived)

One server port, many concurrent client connections, OS distinguishes
them via the 4-tuple `(server_ip, server_port, client_ip, client_ephemeral_port)`.
Resolution chain per connection:

1. `accept()` returns a per-connection FD.
2. `getpeername(fd)` gives the client's ephemeral port.
3. macOS `libproc.h` walk: `proc_listpids(PROC_ALL_PIDS, …)` →
   `proc_pidinfo(pid, PROC_PIDLISTFDS, …)` for each PID →
   `proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, …)` for each
   socket FD → match the local endpoint against the ephemeral port
   from step 2.
4. That gives you the connecting client PID (Claude Code, or a
   worker process Claude Code spawned).
5. From there: identical to today's `.claudeSpace` placement.
   `sysctl(KERN_PROC_PID)` ancestor walk → first ancestor-owned
   `kCGWindowLayer == 0` window via
   `CGWindowListCopyWindowInfo` → `CGSCopySpacesForWindows` →
   Space id.

Cache `{Mcp-Session-Id → (claude_pid, terminal_window_id, space_id)}`
for the lifetime of the MCP session — don't re-walk per request.

New code surface: a single file like
`QuickShow/Sources/Space/PeerPidResolver.swift` wrapping the libproc
C APIs (~100–150 lines of Swift). Downstream placement code in
`QuickShow/Sources/Space/CGSPrivate.swift` and the resolver chain in
the `.claudeSpace` policy are reused unchanged.

Headless / no-terminal fallback (SSH, CI, IDE-hosted Claude with no
terminal in the ancestor tree): existing fallback chain applies —
per-session cache → `CGSGetActiveSpace` → skip placement.

### Content identity (Claude-set `group`)

Every `show_*` tool call takes a `group` (string). `group` is the
canonical content namespace.

- Panel identity = `(group, name)`. Fully explicit. Two calls with
  the same `(group, name)` update the same panel; otherwise they
  create new panels.
- The implicit per-session namespace today's sidecar maintains is
  removed. There is no server-side concept of "which Claude owns
  this panel" — only "which group does this panel belong to".
- `events.ndjson` and artifact dirs move from
  `<sessionId>/events.ndjson` to `<group>/events.ndjson` (and
  `<group>/artifacts/<id>.png`). Path derivation lives in one
  place; update `MarkupPaths.swift`.
- `set_session_flag` becomes `set_group_flag` (or equivalent) —
  flags like `markup_events_armed` scope per-group, not per-session.

Claude is responsible for:

- Generating a meaningful `group` slug per body of work
  (`http-migration-spec`, `chess-game-2026-05-21-ab12`, etc.).
  Suffix with random/timestamp bits if collision is a risk.
- Persisting the group in conversation context and, for multi-turn
  bodies of work, in memory.
- Reusing it deliberately across `show_*` calls within the same
  body of work, and across `claude --resume` (read from memory).
- Deliberately sharing across parallel Claudes if collaboration is
  desired (use the same group by agreement).

Skill prose (in `plugin/skills/quickshow/SKILL.md`) tells Claude:
always set `group`; pick a meaningful slug; save it to memory if
this is a multi-turn body of work; on resume, read memory and reuse.

### Worked example

Scenario A — single Claude, resume across restart, same terminal:

```
# Terminal A:
claude
> render me a chart of X
  Claude generates group="data-viz-2026-05-21-ab12"
  Claude saves to memory: "data-viz body of work uses group 'data-viz-2026-05-21-ab12'"
  show_html(group="data-viz-2026-05-21-ab12", name="chart", body=…)
  Server: libproc → Claude PID 12345 → terminal A window → Space S1
  Panel opens on S1 in a new HUD tagged with group "data-viz-…"

# User exits Claude, comes back hours later in the same terminal:
claude --resume <uuid>
> update the chart with Y
  Claude reads memory: "uses group 'data-viz-2026-05-21-ab12'"
  show_html(group="data-viz-2026-05-21-ab12", name="chart", body=updated)
  Server: existing panel for (group, name) found → updated in place on S1
```

Scenario B — two parallel Claudes, isolated:

```
# Terminal A, Claude A:
> show me a heatmap
  Claude A generates group="exploration-A-2026-05-21-cd34"
  show_html(group="exploration-A-…", name="heatmap", body=…)
  Server: libproc → Claude A PID → terminal A → Space S1, opens panel on S1.

# Terminal B, Claude B (different conversation):
> show me a different heatmap
  Claude B generates group="exploration-B-2026-05-21-ef56"
  show_html(group="exploration-B-…", name="heatmap", body=…)
  Server: libproc → Claude B PID → terminal B → Space S2, opens panel on S2.

# Two distinct groups, two distinct HUDs, no collision.
```

Scenario C — two Claudes deliberately sharing:

```
# Both Claudes have been told (by user, or by skill convention)
# to use group="design-review-q2".
# Claude A opens panel "spec" in that group; Claude B updates it.
# Server: (group, name) match → same panel, both Claudes can read/write.
# Placement: panel lives wherever Claude A's terminal was when it was
# first created. Claude B's calls update it in place; no Space jump.
```

### Placement-vs-group tension

Open design call to make in Phase 2: when Claude B opens a *new* panel
in group X but group X's other panels live on Claude A's Space, does
the new panel join its group's HUD (group cohesion wins) or open on
Claude B's Space (caller placement wins)?

Default recommendation: **caller placement wins**. New panel opens
where the calling Claude is, even if it splits the group across
Spaces. Reasoning: the user can only see what's on their current
Space; opening a panel they can't see is worse than splitting a
group's panels across two HUDs. Document the trade-off; revisit if
real usage shows it's wrong.

## Phase 1 — PoC (de-risking, 1–2 days)

Build the minimum needed to answer three concrete proof-points
empirically. **Do not delete or touch any existing code in this
phase — the PoC must coexist with today's stdio sidecar.**

### Scope

- A standalone `PeerPidResolver.swift` that takes an accepted TCP
  socket FD and returns the connecting PID via libproc. Build it
  *first*, in isolation — the placement story falls apart if this
  doesn't work, and proving it doesn't require any MCP scaffolding
  at all (use a 30-line Swift TCP server + `curl` from a known PID
  as the test rig).
- `MCPHTTPServer` class in QuickShow.app, listening on a
  configurable port. Use `Network.framework` or a small embedded
  HTTP library. Avoid Vapor — too heavy.
- MCP `initialize` handshake per the Streamable HTTP transport
  spec. Use Context7 (`mcp__context7__resolve-library-id` →
  `query-docs`) to pull the current MCP spec; don't rely on
  training data, the Streamable HTTP transport is recent
  (2025-03-26 spec revision).
- Implement **one** tool: `show_html`. Take a `group` argument.
  Reuse `HTMLRenderer.swift` directly. Validate input, look up
  placement via `PeerPidResolver`, call the renderer.
- Emit one MCP server-initiated notification (try
  `notifications/message` or a custom type) a few seconds after a
  `show_html` call completes, to test proof-point #3 below.

### Three proof-points

#### P1 — Libproc PID resolution works

Stand up a tiny Swift TCP server. Connect with `curl` from a known
PID (`echo $$ ; curl http://localhost:…`). Verify the server's
libproc walk identifies the curl PID. Also verify from a forked
worker that the ancestor walk finds the originating shell.

- **Go criterion:** libproc lookup returns the right PID for direct
  curl, and ancestor walk handles a forked worker case.
- **Acceptable variants:** if libproc needs entitlements or has
  same-user restrictions, document them and confirm the QuickShow
  use case (both processes are the same user) works.
- **No-go:** if libproc requires privileged access or doesn't work
  for localhost TCP on macOS at all. Stop. Reconvene. (Very
  unlikely — `lsof -i` does this.)

#### P2 — Claude Code's HTTP MCP client works at all

Configure a throwaway Claude with the PoC server's URL. Verify the
`initialize` handshake completes, `show_html` is callable, and a
panel renders end-to-end. Verify `Mcp-Session-Id` is assigned and
visible server-side.

Also: spawn two `claude` processes concurrently against the same
server URL. Verify the server sees two distinct `Mcp-Session-Id`s
and two distinct connecting PIDs (via PeerPidResolver from P1),
with no cross-talk.

- **Go criterion:** basic HTTP MCP works in Claude Code, parallel
  Claudes are distinguishable at the connection level.
- **No-go:** if Claude Code's HTTP MCP client is broken, missing,
  or shares one connection across parallel conversations such that
  PIDs can't be distinguished. Stop. Reconvene. (Unlikely but
  worth proving.)

#### P3 — Push notifications are surfaceable

Have the PoC server emit an MCP server-initiated notification ~5s
after `show_html` returns. Observe what happens client-side:

- (a) Notification surfaces to Claude in a non-blocking way (like
  Claude Code's `Monitor` harness primitive does for `tail -F`
  output). → Best case. Phase 2 can replace `tail -F events.ndjson`
  with native MCP push for markup/panel events.
- (b) Notification arrives but isn't surfaced to Claude usefully.
  → Acceptable. Phase 2 keeps `tail -F events.ndjson` + `Monitor`
  for the event channels exactly as today; HTTP migration loses
  nothing relative to current state.
- (c) Notification is silently dropped or breaks something. →
  Acceptable too. Same fallback as (b).

Not a go/no-go gate. Only affects whether the event-channel code
gets simpler in Phase 2.

### Deliverables

- `PeerPidResolver.swift` (production-ready, lands in main repo
  even if Phase 2 doesn't proceed — it's useful on its own).
- `MCPHTTPServer` class, gated behind a debug flag or off-by-default
  env var so it doesn't affect normal users.
- Test record of each proof-point (commands run, server logs,
  client behaviour observed).
- `HTTP_MIGRATION_POC_REPORT.md` at the repo root summarising
  empirical findings and recommending Phase 2 go/no-go with a
  one-paragraph rationale.

### Out of scope for Phase 1

- Migrating any tool other than `show_html`.
- Touching the existing stdio sidecar.
- Changing `.mcp.json` for end users.
- Auto-launch UX, prefs panel changes, login items.
- Renaming `session_id` → `placement_id` (cosmetic; defer).
- Updating skill prose to require `group`.
- Shipping anything to end users.

## Phase 2 — Full migration (only if PoC says go, ~2 weeks)

### Steps in order

1. **Migrate MCP tools to Swift, one at a time.** Each
   `sidecar/src/handlers/*.ts` becomes a Swift handler under
   `QuickShow/Sources/MCP/`. Each handler validates input, calls
   the existing renderer/session/markup code directly. Commit per
   handler.
2. **Make `group` canonical.**
   - On the Swift side: panel identity becomes `(group, name)`.
     Server-side bookkeeping for `<sessionId>` namespace is removed.
   - `MarkupPaths.swift`: events/artifacts paths re-root from
     `<sessionId>/` to `<group>/`.
   - `set_session_flag` becomes `set_group_flag` (or whatever
     ergonomic name fits).
   - `events.ndjson` lines tagged with `group` instead of `session_id`.
3. **Update skills.** `plugin/skills/quickshow/SKILL.md` (and
   adjacent skills that drive `show_*`): require `group` on every
   call, document slug conventions, document the memory-persistence
   pattern for multi-turn bodies of work. Verify the change feels
   natural in practice (drive the chess skill, the design skill,
   etc. against the new model).
4. **Switch plugin distribution.** Update `plugin/.mcp.json` to
   point at the HTTP endpoint. Bump `plugin/.claude-plugin/plugin.json`
   and `.claude-plugin/marketplace.json` to 0.2.0. Update README
   with "Launch at login" guidance.
5. **Add login-item toggle.** Prefs panel gains "Launch QuickShow
   at login" checkbox using `SMAppService`.
6. **Delete the sidecar.** Remove `sidecar/`, `plugin/bin/`,
   `plugin/launcher/`, `tools/build-plugin.sh`,
   `tools/build-sidecar.sh`. Update `CLAUDE.md` repo-topology
   block. Strip the wire-protocol mirror discipline section. Strip
   `set_session_flag` references. Update the session_id anchoring
   section to describe the new placement/content split.
7. **Audit the Unix-socket layer.** `ControlServer` /
   `ControlProtocol.swift` may still be useful for app-internal
   needs (e.g. menu-bar-triggered HUDs, the Capture Screen flow).
   Either keep as an internal-only API or rip out if unused.

### Acceptance for Phase 2

- All existing MCP tools work end-to-end through HTTP, verified
  against a live Claude session for each tool.
- All `bun test` tests have been ported to XCTest (or deleted if
  testing TS-only behaviour that no longer exists).
- Multi-Claude isolation verified by spawning two `claude`
  processes and running tools with distinct groups from each.
- Multi-Claude *collaboration* verified by having two `claude`
  processes deliberately share a group and update each other's
  panels.
- Placement on the right Space verified by exercising at least:
  same-terminal-resume (Scenario A above), parallel-terminal
  (Scenario B), IDE-hosted (VS Code if available).
- The DMG / plugin distribution installs cleanly and works for an
  end user who's never run QuickShow before.

## Constraints (both phases)

- **Don't break end users mid-migration.** Phase 1 must not change
  anything that ships to end users. Phase 2 ships as a major
  version bump (0.2.0) with release notes that explain the
  `group`-required model and how to migrate skills that drove
  `show_*` without a group.
- **Don't touch the v0.1.1 release branch.** All work lives on a
  worktree branch and merges to `main` only when Phase 2 is
  complete.
- **Wire-protocol mirror still applies during the transition.**
  If Phase 2 touches `protocol.ts` or `ControlProtocol.swift`
  while the sidecar still exists, keep them in lockstep per the
  existing CLAUDE.md rule.
- **Content identity (`group`) is load-bearing.** Don't ship Phase
  2 with the implicit-session-namespace fallback "for
  compatibility" — it'd defeat the simplification. Either
  `group` is required, or it's auto-defaulted to a meaningful
  value, with no quiet collisions.
- **Placement identity is opaque to Claude.** Don't leak it into
  MCP tool schemas or responses. The whole point of the split is
  that Claude doesn't think about placement at all.

## Non-goals

- Switching the GUI app to a different framework or language.
- Cross-platform (Windows/Linux) support — QuickShow is
  macOS-only.
- Replacing the WebView-based renderer architecture.
- Developer-ID signing / notarization (separate BACKLOG item).
- Apple Silicon / Intel universal binary (separate BACKLOG item).
- Preserving today's "conversation UUID as session anchor"
  behaviour. The split intentionally drops it; content identity
  via `group` + Claude memory is the replacement.

## Suggested approach for the agent picking this up

1. Read `CLAUDE.md`, `ROADMAP.md`, `BACKLOG.md`, `PRD.md`.
2. Spin up a worktree: `/feature http-mcp-poc`.
3. Append a new phase to `ROADMAP.md`:
   `Phase X — HTTP MCP server (PoC)`, mark `← current`.
4. Build `PeerPidResolver` first, in isolation (P1). If it
   doesn't work, nothing else matters. ~30 minutes.
5. Read `sidecar/src/index.ts`, `sidecar/src/handlers/html.ts`,
   `sidecar/src/handlers/_groupingFields.ts`, and
   `QuickShow/Sources/Renderers/HTMLRenderer.swift` to understand
   the existing end-to-end flow.
6. Pull current MCP spec docs via Context7.
7. Build the PoC. Answer the three proof-points. Write the
   report.
8. **Stop at the report.** Phase 1 ends at the decision point.
   Don't auto-continue into Phase 2 without explicit user approval.

## References

- `CLAUDE.md` — project conventions (worktree rule, wire-protocol
  mirror, session-id anchoring details, logging convention, HUD
  Space placement). The session-id anchoring section will need
  rewriting in Phase 2.
- `docs/control-protocol.md` — current Unix-socket wire protocol
  reference. Becomes obsolete in Phase 2.
- `docs/adding-a-renderer.md` — three-file pattern for content
  types. Swift-side MCP handlers in Phase 2 will resemble this
  shape, minus the wire-protocol pairing.
- `sidecar/src/index.ts` — current MCP server bootstrap (replaced
  in Phase 2).
- `sidecar/src/handlers/html.ts` — current `show_html` handler
  (replaced in Phase 1).
- `sidecar/src/handlers/_groupingFields.ts` — current `group`
  field validator. The shape of validation moves to the Swift
  handler; `group` semantics expand from "optional tab grouping"
  to "canonical content namespace".
- `QuickShow/Sources/Server/ControlServer.swift` — current
  Unix-socket server. Audited / removed in Phase 2.
- `QuickShow/Sources/Sessions/SessionManager.swift` — session-state
  ownership. Refactored in Phase 2 to be group-keyed instead of
  session-keyed.
- `QuickShow/Sources/Space/` — Space placement code. The
  `.claudeSpace` pipeline is reused from "have a PID" onward; only
  the source of the PID changes (libproc lookup vs `hello.parent_pid`).
- `QuickShow/Sources/Events/MarkupPaths.swift` — events / artifacts
  path derivation. Re-rooted in Phase 2 to use `group` instead of
  `sessionId`.
- `QuickShow/Sources/Renderers/HTMLRenderer.swift` — example
  renderer the PoC invokes directly.
- `plugin/.mcp.json` — current MCP server registration.
- `plugin/skills/quickshow/SKILL.md` — skill prose updated in
  Phase 2 to require `group`.
- `plugin/launcher/mcp-quick-show` — the dev-mode stdio shim added
  in commit `4636a88`; becomes obsolete after Phase 2.
- `.claude/retros/auto-retro-2026-05-21-200336.md` (Notes section)
  — context on why the stale-binary cycle triggered this proposal.

## Open feedback for the agent

If during Phase 1 you discover any of the following, stop and
escalate to the user:

- P1 fails (libproc lookup doesn't work or requires privileges
  that defeat the architecture).
- P2 fails (Claude Code's HTTP MCP client unusable, or parallel
  Claudes share one connection / one PID such that they can't be
  distinguished server-side).
- A Swift MCP HTTP server requires materially more than 1–2 days
  to stand up (e.g. you can't find a working HTTP server library
  and end up needing to write a full HTTP/1.1 parser).
- The libproc lookup works but is so slow it noticeably impacts
  per-request latency (mitigation: aggressive caching per session,
  but if even one walk takes >100ms it's worth flagging).
- Anything else that materially changes the cost/benefit of Phase 2.

The point of Phase 1 is to learn cheaply. Surfacing surprises is
the desired outcome, not failure.
