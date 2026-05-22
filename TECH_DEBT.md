# Tech Debt

Known rot, regressions, missing tests, and diagnostic gaps in shipped
code. Distinct from `BACKLOG.md` (new capabilities) and `ROADMAP.md`
(active phase work). Items are ordered by priority — top is next.

Each entry is an agent-ready outline. Move into `ROADMAP.md` as a
phase when scheduling, same convention as `BACKLOG.md`.

---

## P0 — HUDs not opening in Claude's Space

The `hudSpacePolicy = .claudeSpace` placement (CLAUDE.md "HUD Space
placement") is not landing panels on the Space that hosts the
Claude-session terminal. The whole CGS-private + triple-call
machinery in `ensurePrimaryHud` was built for exactly this; if it's
silently no-oping the regression is high-impact and user-facing
(every `show_*` call yanks the user's attention to a different
Space, or fails to surface at all).

Diagnostic starting points, in order:

1. Confirm `CGSPrivate.isAvailable` is still true on the current
   macOS — symbol drift on a new OS version would flip the whole
   `SpaceResolver` chain into a no-op and we'd never know.
2. Walk `SpaceResolver`'s resolution chain with a fresh session:
   does `parent_pid` arrive on `hello`? does the ancestor-PID walk
   via `sysctl(KERN_PROC_PID)` find a terminal-owned window? does
   `CGSCopySpacesForWindows` return a sane Space id?
3. Check whether the `.fullScreenAuxiliary` drop on
   `HUDWindow.collectionBehavior` is still in effect for
   `.claudeSpace` — Stage Manager / fullscreen interactions are
   the known antagonist.
4. The double-after-`makeKeyAndOrderFront` call is empirically
   required (see CLAUDE.md). Verify both calls still fire and
   neither has been refactored away.

Decide repro surface before fixing: a simple `show_html` from a
Terminal.app session living on Space 2 while the user looks at
Space 1 is the canonical case. Diagnostic NSLog data from the v0.2
ship commit can be re-enabled if the symptom isn't obvious from a
single repro.

## P1 — Reconcile `ControlRequest` type drift; turn typecheck green

Surfaced cleanly by the 2026-05-19 tsconfig flip
(`allowImportingTsExtensions: true`) which cleared the TS5097
cascade. What remains is ~22 real type errors: call sites pass
`session` / `session_id` fields that `ControlRequest` in
`sidecar/src/protocol.ts` doesn't model. Pair with
`QuickShow/Sources/Server/ControlProtocol.swift` per the wire-protocol
mirror discipline. Affected files: `handshake.ts`,
`enableMarkupEvents.ts`, `enablePanelEvents.ts`, `index.ts`,
`verify-url.ts`, `verify-topbar.ts`, `verify-tab-groups.ts`. Add
`bun run typecheck` to `.github/workflows/ci.yml` once green so it
can't regress silently again. Drop the "partially red" annotation
from CLAUDE.md's "Sidecar dev commands" block as the last step.

## P2 — `tools/verify-parallel-sessions.sh` regression test

Belt-and-braces test locking in the conversation-UUID session
anchoring (see CLAUDE.md "session_id is anchored to the Claude
conversation UUID"). Spawn two sidecars with the same fake cwd
via `QUICKSHOW_SOCKET_PATH` overrides and assert they get distinct
`session_id`s from the app's allocator. The fix shipped; this test
exists to make a future drift loud.

## P2 — Renderer-swap leaves panel blank until user zooms

Surfaced during Phase 2.7 E2E Scenario 3. Sequence: a `show_url`
panel is updated in place by a `show_markdown` call with the same
`(name, group)` — Claude rendered example.com, then was asked to
"replace this with the markdown version of the same site". HUD
stayed put, tab strip / title correct, but the content area was
**blank**. One scroll-wheel zoom tick reveals fully-rendered
markdown. So the renderer ran and the WebView is holding the
content — the failure is layout / magnification on first paint.

Likely cause: the same-name-different-type branch of
`SessionManager.upsert` (`QuickShow/Sources/Sessions/SessionManager.swift`
≈ lines 318–336) removes the old renderer's view and installs a
fresh `ZoomableCanvasScrollView` via auto-layout pinned to
`contentHost`'s edges. `WebViewPanelRenderer.applyCanvasSize`
(`Renderers/WebViewPanelRenderer.swift:594-604`) then fires
`scrollView.smartFit()` once `renderComplete` resolves —
**but the outer scroll view's auto-layout pass may not have run
yet**, so `contentView.bounds.width` is 0 and the
`magnify(toFit:)` calc collapses to ~minMagnification. The first
wheel-zoom re-enters `setMagnification` after layout has settled,
which is why the content snaps back. Novel-name (fresh HUD)
creates don't bite because the whole HUD is being sized in the
same pass.

Cleanest fix: in `applyCanvasSize`, call
`scrollView.layoutSubtreeIfNeeded()` (or
`scrollView.superview?.layoutSubtreeIfNeeded()`) right before the
`if !hasFittedOnce { scrollView.smartFit() ... }` block. That
forces auto-layout to size the scroll view before the
container-width-dependent magnification calc runs. Verify with a
URL → markdown swap on the same panel; the content should be
visible on first paint without a zoom nudge.

Falsifiable: if the fix above doesn't resolve, the layout hypothesis
is wrong — fall back to instrumenting `contentView.bounds` at the
exact moment of `smartFit()` and trace from there.

Severity is medium: no data loss, no crash, trivial workaround
(zoom). But `show_url → show_markdown` / `show_html → show_markdown`
on a claimed user-share are normal flows, and users without the
workaround see the feature as broken. Log evidence + full repro
notes in `/tmp/qs-e2e.log` around 2026-05-22 21:14:54 (claim) →
21:16:37 (markdown POST) on the worktree run.

## P2 — `QUICKSHOW_TEST_PANEL_EVENT` synthetic-click smoke shim

Mirror of the existing `QUICKSHOW_TEST_MARKUP` env-var test hook:
when set, the app injects a synthetic click event into the first
rendered WebView once `renderComplete` fires, so the panel-event
smoke verifier exercises the real onclick → `quickshow.emit` →
`events.ndjson` path rather than the current
`addEventListener("load", …)` auto-emit shortcut. Belongs in
`AppDelegate` next to the other `QUICKSHOW_TEST_*` hooks; the
smoke side lives in a new `sidecar/src/cli/verify-panel-event.ts`
peer to `verify-markup.ts`.

## P2 — Orphan-grace badge doesn't render on the HUD's title bar

Surfaced in Phase 2.7 E2E Scenario 7. The orphan-grace cascade
fires correctly end-to-end (idle-sweep → drop → start orphan
timer → 60s expiry → `setSessionEnded(true)`), confirmed by the
log line:

```
21:42:19 QuickShow: group subagent-test orphan grace expired —
                    badge on 1 HUD(s)
```

But the user-facing badge does NOT appear on the HUD's title bar.
Verified via screenshot of the affected `subagent-test` HUD
post-expiry: title bar reads `repo-status` + snapshot icon +
spacer + close X. No `● session ended` text between title and
snapshot icon (which is where it should appear, per the
`idleContents` stack ordering in `TitleBarOverlay.swift:342-344`).
Nothing in the log between the expiry and the screenshot clears
the badge — no `reattached (orphan badge cleared)` line, no
write to the group.

Code chain that ran but didn't visibly land:
- `SessionManager.startOrphanTimer` task body
  (`Sessions/SessionManager.swift:220-230`) fires
  `hud.window.setSessionEnded(true)` on each HUD in the group.
- `HUDWindow.setSessionEnded` (`HUD/HUDWindow.swift:441-443`)
  forwards to `titleBar.setSessionEnded(true)`.
- `TitleBarOverlay.setSessionEnded`
  (`HUD/TitleBarOverlay.swift:481-484`) sets
  `badgeView.isHidden = false` and
  `badgeView.stringValue = "● session ended"`.

The badge view is wired into `idleContents` stack with
`detachesHiddenViews = false`, so the layout slot should always
exist; toggling `isHidden = false` should fill it. But nothing
appears.

Hypotheses, ranked:

1. **Layout race**: same family as the renderer-swap blank
   panel (other P2). `badgeView` toggles `isHidden` on the main
   thread but the parent stack view doesn't relayout in the same
   pass. A subsequent layout pass (window resize, mode toggle,
   first interaction) would reveal it — worth testing. Fix:
   call `titleBar.layoutSubtreeIfNeeded()` or
   `idleContents.layoutSubtreeIfNeeded()` after the
   isHidden/stringValue assignment.
2. **Drawing race**: badge view's `needsDisplay` not set after
   `stringValue` change. NSTextField usually invalidates on
   stringValue write, but worth verifying — try
   `badgeView.needsDisplay = true` after the assignment.
3. **`detachesHiddenViews` doesn't behave as assumed**: the
   stack may not allocate the badge's slot when initially
   hidden, then refuse to grow when unhidden. Less likely with
   the documented `detachesHiddenViews = false`, but if the
   initial state was actually `detachesHiddenViews = true` at
   some construction path, this would explain it.

Reproducer (manual): launch app, render any panel, wait for
its session's idle-sweep + orphan-grace cascade
(`QUICKSHOW_MCP_IDLE_SECONDS=15 QUICKSHOW_RECONNECT_GRACE_SECONDS=5`
in env on launch shrinks this to ~20s). Confirm via log that
`badge on N HUD(s)` fires, then visually inspect the HUD's
title bar — badge should be visible. Currently it isn't.

Severity: P2. The orphan-state plumbing works (state.orphaned is
true, snapshots / re-renders that read this flag will get the
right answer). The user-visible signal is broken — they don't
know their Claude session is dead until they try to interact and
see nothing happen.

## P3 — Claude Code `/exit` doesn't send `DELETE /mcp` → 6-min badge delay

Surfaced in Phase 2.7 E2E Scenario 7. The router's DELETE handler
(`QuickShow/Sources/MCP/MCPSessionRouter.swift:121-124`) is correct:
on a DELETE that returns 200, the session is dropped immediately,
which calls `onSessionRemoved` → `mcpSessionDisconnected` →
`startOrphanTimer` (60s) → badge. The whole chain works (verified
by the test-only `sidecarDisconnected` smoke and by the
idle-sweep path which goes through the same `dropSession`).

But **Claude Code's `/exit` does not actually issue
`DELETE /mcp`** on the HTTP MCP session. Across the entire E2E
test run (50+ minutes, multiple `/exit` invocations), zero
DELETE requests landed on `/mcp`. Sessions only get cleaned up
via the 5-minute idle-sweep fallback. So the user-visible flow
from `/exit` to "session ended" badge is:

- `/exit` at T+0 → no DELETE sent
- T+300s → `QUICKSHOW_MCP_IDLE_SECONDS` idle-sweep drops the
  session, triggers orphan-grace start
- T+360s → orphan-grace expires, badge appears

That's a 6-minute delay where the HUD looks live but is actually
talking to a dead session. The UX expectation is much faster
feedback ("session you closed → HUD shows it ended within a
minute").

Two options, in order of preference:

1. **Get Claude Code to send DELETE on `/exit`** (and on Ctrl+C
   / window-close, ideally). That's the spec-compliant behaviour
   per MCP Streamable HTTP — the client is supposed to issue
   DELETE to release the session id. Worth raising upstream
   with the Claude Code team. Until that lands we're stuck with
   the fallback.
2. **Shrink the idle window**. Drop `QUICKSHOW_MCP_IDLE_SECONDS`
   default from 300s to something like 60s, so the fallback
   triggers within ~2 minutes (60s idle + 60s grace) instead of
   6. Trade-off: a long-running session that genuinely doesn't
   call any quickshow tools for 60s would get swept incorrectly,
   which then forces a re-`initialize` round-trip on the next
   tool call. Probably acceptable since heartbeat GETs from the
   SDK's keep-alive should reset `lastAccessedAt` (verify before
   shipping), but worth a careful read of the SDK's polling
   cadence first.

Not Phase 2.7 blocking — the cascade itself works once it
triggers. Filed for the next maintenance pass.

## P3 — `os_log` migration for protocol-layer Swift logs

Today's NSLog output is redacted as `<private>` in `log show`
without an installed logging profile, which hurts mid-incident
diagnosis (see the 2026-05-17 stale-binary hang). Switch
`QuickShow:`-prefixed log calls to `os_log` with `%{public}@`
formatters and a dedicated subsystem so
`log show --predicate 'subsystem == "com.tomzola.QuickShow"'`
carries real content. Lighter alternative if the migration feels
heavy: document the logging-profile install steps inline in
CLAUDE.md's "Logging convention" section.
