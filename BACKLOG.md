# Backlog

Post-v0.1 ideas not yet on `ROADMAP.md`. Each entry is an outline an agent can pick up and plan from. Move into ROADMAP.md as a phase when scheduling.

## Reconcile `ControlRequest` type drift; turn typecheck green

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

## `os_log` migration for protocol-layer Swift logs

Today's NSLog output is redacted as `<private>` in `log show`
without an installed logging profile, which hurts mid-incident
diagnosis (see the 2026-05-17 stale-binary hang). Switch
`QuickShow:`-prefixed log calls to `os_log` with `%{public}@`
formatters and a dedicated subsystem so
`log show --predicate 'subsystem == "com.tomzola.QuickShow"'`
carries real content. Lighter alternative if the migration feels
heavy: document the logging-profile install steps inline in
CLAUDE.md's "Logging convention" section.

## `QUICKSHOW_TEST_PANEL_EVENT` synthetic-click smoke shim

Mirror of the existing `QUICKSHOW_TEST_MARKUP` env-var test hook:
when set, the app injects a synthetic click event into the first
rendered WebView once `renderComplete` fires, so the panel-event
smoke verifier exercises the real onclick → `quickshow.emit` →
`events.ndjson` path rather than the current
`addEventListener("load", …)` auto-emit shortcut. Belongs in
`AppDelegate` next to the other `QUICKSHOW_TEST_*` hooks; the
smoke side lives in a new `sidecar/src/cli/verify-panel-event.ts`
peer to `verify-markup.ts`.

## `tools/verify-parallel-sessions.sh` regression test

Belt-and-braces test locking in the conversation-UUID session
anchoring (see CLAUDE.md "session_id is anchored to the Claude
conversation UUID"). Spawn two sidecars with the same fake cwd
via `QUICKSHOW_SOCKET_PATH` overrides and assert they get distinct
`session_id`s from the app's allocator. The fix shipped; this test
exists to make a future drift loud.

## `list_markup_events` polling tool for cross-agent support

Non-blocking MCP tool `list_markup_events(session_id, since?)`
that reads the session's `events.ndjson` and returns the slice
since the given cursor. Lets Codex and other agents without
Claude Code's `Monitor`/`tail -F` primitive observe markup +
panel events. View-only — they poll, they don't get pushed at,
they don't block (per the 2026-05-14 retro's decision). Sidecar
implementation only; no app-side change. Question worth deciding
before picking up: does this graduate to a phase, or stay
backlog until a non-Claude agent actually needs it?
