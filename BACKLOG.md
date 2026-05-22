# Backlog

Post-v0.1 capability ideas not yet on `ROADMAP.md`. Each entry is an
outline an agent can pick up and plan from. Move into ROADMAP.md as a
phase when scheduling.

For rot, regressions, missing tests, and diagnostic gaps in already-
shipped code, see `TECH_DEBT.md` instead.

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
