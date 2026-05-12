---
status: drafted
updated: 2026-05-12
---

> **Tracking convention.** User stories below use the task-list format (`1. [ ] ...`) and are ticked off as work lands. Implementation Decisions and Testing Decisions are amended in place, not tracked with checkboxes. Update the `status:` and `updated:` fields above as the PRD progresses.

# QuickShow / mcp-quick-show — v0.1 PRD

## Problem Statement

When working with agentic dev tools (Claude Code in particular), the agent often produces or works with content that is far easier to *understand visually* than as text — architecture diagrams, rendered markdown reports, generated SVGs, screenshots of running systems. Today this content arrives as raw text in the chat transcript (a Mermaid spec the agent wants the user to look at), gets dumped to a file the human has to manually open, or simply isn't surfaced at all.

A second, equally important problem: the agent has **no way to render its own visual work and see what it produced**. It can't iterate on a generated diagram because it has no visual feedback. It can't catch that an SVG it generated is malformed. It can't confirm a markdown report it drafted formats the way it intended. The agent is blind to its own visual output.

The result: visual artifacts that should sit alongside the agent's work end up either hidden, manually inspected, or quietly wrong — and the iteration loop on visual output is broken.

## Solution

**QuickShow** — a macOS menu-bar app paired with an MCP server (`mcp-quick-show`) that lets agents render content into floating HUD panels and *see* the rendered result.

The agent calls an MCP tool (e.g. `show_mermaid("architecture", "graph LR; A-->B")`). A small floating HUD appears in the corner of the user's screen — visible across all macOS Spaces including fullscreen apps. The MCP tool response includes a PNG screenshot of the rendered panel, so the agent verifies the output and iterates (`show_mermaid("architecture", improved_spec)` updates the same panel in place).

The user sees the same panel — can drag, resize, close it, or promote it to a standard titled window. Multiple panels live in a tab strip; tabs can be torn out into separate HUDs. Multiple parallel Claude Code sessions each get their own HUD, so visual output stays grouped per agent session.

Initial supported content types: rendered Markdown, Mermaid diagrams, SVG (inline), raster images (by file path). The architecture is designed so adding a fifth content type later costs three small files (one sidecar handler, one app renderer, two registration lines).

## User Stories

### Agent (MCP client) stories

1. [ ] As an agent, I want to render a markdown string in a floating panel, so that the user can read a long-form report I produced without me having to dump it into the chat transcript.
2. [ ] As an agent, I want to render a markdown file by passing its path, so that I don't waste tokens streaming the file's contents through a tool call when the file is already on disk.
3. [ ] As an agent, I want to render a Mermaid diagram from a definition string, so that I can visualize architecture, flows, or relationships I'm reasoning about.
4. [ ] As an agent, I want to render an inline SVG, so that I can produce custom visualizations (annotated images, generated illustrations, hand-drawn diagrams) without going through a third-party renderer.
5. [ ] As an agent, I want to display an existing image file by path, so that I can surface screenshots, generated assets, or any image I've produced or received.
6. [ ] As an agent, I want every render call to return a screenshot of the rendered panel by default, so that I can verify the output was correct without asking the user.
7. [ ] As an agent, I want to opt out of the screenshot return on a per-call basis, so that I can save tokens when I'm rendering content the user will look at and I don't need to inspect.
8. [ ] As an agent, I want to address panels by a stable human-readable name I choose, so that I don't have to track opaque IDs across tool calls.
9. [ ] As an agent, I want a second call with the same name to update the existing panel in place, so that I can iterate on a diagram (`v1` → `v2` → `v3`) without leaving stale panels behind.
10. [ ] As an agent, I want a second call with a *different* name to open a new panel, so that I can show alternatives side-by-side when needed.
11. [ ] As an agent, I want to close a panel by name when I'm done with it, so that I can clean up after myself.
12. [ ] As an agent, I want to list the panels currently open in my session, so that I can reconcile state ("close everything starting with `debug-`") or check what the user already has on screen.
13. [ ] As an agent, I want to re-snapshot an existing panel without re-sending its content, so that I can check a panel I rendered earlier in the conversation.
14. [ ] As an agent, when my render fails (Mermaid syntax error, malformed SVG, missing image), I want a structured error response that includes both the human-readable error text and a screenshot of the in-panel error UI, so that I can fix the problem on the next attempt without guessing.
15. [ ] As an agent, when I update a panel and the new content is broken, I want the panel to *show the error* (not the previous successful render), so that I'm not misled into thinking my update succeeded.
16. [ ] As an agent, when my session ends and I reconnect within a short window (transient socket drop), I want my existing panels to reattach automatically, so that my visual context survives the blip.
17. [ ] As an agent in one parallel session, I want my panels to be isolated from other agent sessions' panels, so that name collisions (`notes` in session A vs session B) don't clobber each other.

### Human user stories

18. [ ] As a developer, I want to install QuickShow as a single .app, so that I don't have to manage a separate Node package or sidecar binary.
19. [ ] As a developer, I want a one-click "Connect to Claude Code" button after install, so that I don't have to manually edit MCP config files.
20. [ ] As a developer, I want a copyable MCP config snippet for other clients (Cursor, Continue, Claude Desktop), so that I can use QuickShow outside Claude Code.
21. [ ] As a developer running multiple parallel Claude Code sessions, I want each session's panels grouped in their own HUD, so that I can tell at a glance which agent produced which visual output.
22. [ ] As a developer, I want HUD panels to stay visible when I switch into a fullscreen IDE or terminal, so that I can keep referring to a diagram or report while working in another app.
23. [ ] As a developer, I want to drag a HUD anywhere on screen, so that I can position it where it doesn't cover what I'm working on.
24. [ ] As a developer, I want to resize a HUD from its bottom-right corner, so that I can scale a panel up to read or down to keep my workspace clear.
25. [ ] As a developer, when I have multiple panels in one HUD, I want a tab strip to switch between them, so that I keep one window's worth of screen real estate.
26. [ ] As a developer, I want the tab strip to auto-reveal on hover and stay out of the way otherwise, so that the chrome doesn't compete with the content.
27. [ ] As a developer, I want to drag a tab out of a HUD to spawn it as its own floating panel, so that I can compare two panels from the same agent side-by-side.
28. [ ] As a developer, I want to right-click a tab and "promote to standard window," so that I can keep important panels around in regular Cmd-Tab-able window form.
29. [ ] As a developer, I want HUD content to follow my system appearance (light/dark), so that it doesn't feel like a foreign app.
30. [ ] As a developer, I want a small "snapshot" button on each panel, so that I can re-grab the rendered image to share with someone (drop into Slack, paste into a doc).
31. [ ] As a developer, when an agent session ends, I want its HUD to *stay visible* with a clear "session ended" indicator (instead of disappearing), so that I can keep reading the visual output the agent produced even after I close Claude Code.
32. [ ] As a developer, I want to close orphaned HUDs explicitly when I'm done with them, so that I'm in control of my workspace.
33. [ ] As a developer, I want a minimal preferences panel (launch at login, default opacity, initial size cap, MCP-config tools), so that I can tune the basics without it being a configuration overload.
34. [ ] As a developer, I want a Mermaid diagram with a syntax error to show *what went wrong and where* inside the panel, so that I can read the error and either fix it myself or paste it back to the agent.
35. [ ] As a developer, I want to be able to interact with a rendered panel (click links in markdown, click-to-zoom on a Mermaid diagram, copy code blocks), so that the rendered content is useful and not just static.

### Project / contributor stories

36. [ ] As a contributor adding a new content type (e.g. PlantUML, RevealJS, JSON tree), I want a documented three-file pattern for registering a new renderer, so that I'm not forced to touch the wire protocol or the multiplexing layer.
37. [ ] As a contributor, I want the wire protocol between sidecar and app to use a generic content envelope (with a `content_type` discriminator string), so that adding a new type doesn't require coordinated changes to a typed protocol.
38. [ ] As a contributor, I want a base `WebViewPanelRenderer` that handles WKWebView lifecycle, security config, JS bridge, and snapshotting, so that new WebView-based renderers are ~50 lines of template + injection.
39. [ ] As a contributor, I want the sidecar's tool registry to auto-build the MCP tool list from registered handlers, so that adding a tool doesn't require touching the MCP server bootstrap code.
40. [ ] As a contributor, I want clear separation between sidecar (validation, normalization, protocol) and app (rendering, presentation), so that I can change one half without breaking the other.

## Implementation Decisions

### Architecture overview

Two-binary system distributed as a single `.app`:

- **`QuickShow.app`** — macOS menu-bar app (LSUIElement). Owns the visual surface: HUD windows, tab strips, renderers, snapshots. Listens on a Unix domain socket.
- **`mcp-quick-show`** — TypeScript MCP server, compiled to a standalone executable via `bun build --compile`, bundled inside `QuickShow.app/Contents/Resources/`. Speaks MCP over stdio to the client (Claude Code, etc.); speaks NDJSON over the Unix socket to the app.

The sidecar is the canonical artifact users install; it autolaunches the app on first connect by walking from its own executable path up to the `.app` bundle and invoking `open -g`.

### Modules

**Sidecar (TypeScript):**

- **MCP server bootstrap.** Sets up stdio transport. Iterates the `ContentTypeHandler` registry to publish tools. Wires control verbs (`close`, `list`, `inspect`) directly. Shallow.
- **`ContentTypeHandler` registry.** Uniform shape `{ toolName, description, schema, validate(args) → PanelPayload }`. Each handler registers itself; the registry produces the MCP tool list. Deep — single point that all handlers conform to.
- **Content handlers** (one per type: `markdown`, `svg`, `image`, `mermaid`). Each defines a tool schema, performs input validation/normalization, and emits a normalized envelope. Shallow but uniform.
- **Path resolver.** Resolves `~`, normalizes relative paths against a known cwd, stats the file, sniffs MIME via magic bytes, enforces per-type size caps. Deep — single chokepoint for filesystem access.
- **Socket client.** Connects to the Unix socket at `~/Library/Application Support/QuickShow/control.sock`. NDJSON framing. Request/response correlation by message ID. Reconnect logic with exponential backoff on transient drops. Deep.
- **Session UUID store.** Persists a stable session UUID per MCP-server-config-hash at `~/Library/Application Support/QuickShow/sessions/<config-hash>.uuid`. Tiny.
- **Autolaunch helper.** Locates the bundled `.app` from `process.execPath`, opens it via `open -g`, polls the socket every 100 ms with a 5 s timeout. Deep.

**App (Swift / AppKit):**

- **`AppDelegate`.** Bootstrap. Owns the top-level orchestrators (`ControlServer`, `SessionManager`, `RendererRegistry`, `SettingsWindow`). Shallow glue.
- **`ControlServer` + `ControlProtocol` + `ControlHandlers`.** Unix-socket listener with NDJSON framing. `ControlProtocol` defines Codable wire types (paired with the sidecar's TS protocol; change-both-files-in-same-commit discipline). `ControlHandlers` dispatches each command on the main actor. Lifts shape from PipAnything's existing pattern. Deep.
- **`SessionManager`.** Maps `session_id → HUD`. Handles handshake, reconnect window (60 s same-UUID reattach), orphaning on disconnect with visual badge. State machine. Deep.
- **`HUDWindow`.** Borderless `NSWindow`, `.floating` level, `collectionBehavior` includes `.canJoinAllSpaces` and `.fullScreenAuxiliary`. Top-right cascade positioning per session (24 px offset per HUD). `isMovableByWindowBackground = true` for drag. Bottom-right resize grip subview (lifts from PipAnything's `ResizeHandle`). Initial size is content-aware (panel asks its renderer for natural dimensions after first `renderComplete`) capped at 800 × 1000 pt; user-resizable from then on. Default opacity 100 % (overridable globally in settings). Lifts from PipAnything's `OverlayWindow`.
- **`TabStripView` + `TabPillView`.** Tab UI, hover-reveal at top edge, drag-to-tear-out, right-click context menu. Tabs override `mouseDownCanMoveWindow = false` so clicks don't drag the window (PipAnything-learned trap). Lifts from PipAnything's `feat/tabs` work.

**Right-click menu surface (v0.1):**

- *Per-tab (right-click on a tab pill):* Close tab; Promote to standard window; Re-snapshot (saves a fresh PNG to `~/Downloads`).
- *Per-HUD (right-click on background):* Close all tabs; Opacity submenu (25 / 50 / 75 / 100 %); (auto-hide and click-through deferred — not in v0.1 menu).
- **`PanelRenderer` protocol + `RendererRegistry`.** Protocol: `static var typeKey: String`; `func makeView() → NSView`; `func update(view, payload) async throws`; `func snapshot(view) async throws → Data`. Registry maps `content_type` string → renderer class. Deep.
- **`WebViewPanelRenderer` base class.** Owns WKWebView with hardened config (CSP `default-src 'self'; connect-src 'none'; img-src 'self' file: data:`; no file/clipboard/geolocation; single `renderComplete` JS bridge handler). One `WKProcessPool` per session (cross-panel reads within a session impossible by construction; cross-session even more so). Loads a per-renderer HTML template with bundled libs. Implements snapshot via `WKWebView.takeSnapshot`. Hot-reloads theme on system appearance change. Deep.
- **`MarkdownRenderer` / `SVGRenderer` / `MermaidRenderer`.** Subclass `WebViewPanelRenderer`. Each provides an HTML template (loads `marked` / `mermaid.js` / inlines SVG with sanitization) and a JS injection function that takes the payload and triggers the render. Shallow (~50 lines each).
- **`ImageRenderer`.** Implements `PanelRenderer` directly with `NSImageView` (HiDPI handling, EXIF orientation, zoom/pan via `magnification`). Skips the WebView base. Shallow.
- **`SnapshotService`.** Wraps `WKWebView.takeSnapshot` for WebView renderers and `bitmapImageRepForCachingDisplayIn` for non-WebView renderers. Caps output at 1600×4000 px at 2× scale (downscales beyond). Returns PNG bytes. Deep.
- **`PromoteToWindowController`.** Manages `NSApplication.activationPolicy` (`.accessory ↔ .regular`) toggling — activates `.regular` while ≥1 promoted window exists, returns to `.accessory` when last closes. Detaches a tab from a HUD into a standard `NSWindow`. Deep.
- **`SettingsWindow`.** Minimal prefs UI: launch at login toggle, *global* default opacity slider (default 100 %; applied to newly-spawned HUDs), initial size cap width/height inputs (default 800 × 1000 pt), "Connect to Claude Code" button (writes the appropriate JSON snippet to `~/.claude.json` or shows it for copy), copyable MCP config snippet for other clients. Shallow.

**Shared discipline:**

- Wire-protocol types are mirrored: Swift `ControlProtocol.swift` ↔ TypeScript `protocol.ts`. Both files change in the same commit. PipAnything's CLAUDE.md pattern, replicated.

### MCP tool surface (v0.1)

| Tool | Args | Notes |
|---|---|---|
| `show_markdown` | `name: string`; exactly one of `{content: string, path: string}`; `return_screenshot?: bool = true` | `content` for inline, `path` to render a file without streaming bytes through the tool call. |
| `show_svg` | `name: string`; `content: string`; `return_screenshot?: bool = true` | Inline only in v0.1. |
| `show_image` | `name: string`; `path: string`; `return_screenshot?: bool = true` | Path only — no inline base64. Returns the image itself in the response, not a screenshot of the rendered panel. |
| `show_mermaid` | `name: string`; `definition: string`; `return_screenshot?: bool = true` | Inline mermaid spec. |
| `close` | `name: string` | Closes a panel in this session. |
| `list` | (no args) | Returns all panels in this session: `[{name, content_type, dimensions}]`. |
| `inspect` | `name: string` | Re-snapshots an existing panel without re-sending content. |

### Wire-protocol envelope

NDJSON over Unix socket. One JSON object per line. Two directions, request/response correlated by `id`.

Sidecar → app:
```json
{"id":"<msg-id>", "kind":"upsert", "session":"<uuid>", "name":"<slot>", "content_type":"markdown|svg|image|mermaid", "form":"inline|path", "body":"<text or path>"}
{"id":"<msg-id>", "kind":"close", "session":"<uuid>", "name":"<slot>"}
{"id":"<msg-id>", "kind":"list", "session":"<uuid>"}
{"id":"<msg-id>", "kind":"inspect", "session":"<uuid>", "name":"<slot>"}
{"id":"<msg-id>", "kind":"hello", "session_id":"<uuid>", "client":"claude-code"}
```

App → sidecar:
```json
{"id":"<msg-id>", "kind":"ok", "result":{"width":..., "height":..., "screenshot_b64":"..."}}
{"id":"<msg-id>", "kind":"render_error", "error":"...", "line":N, "screenshot_b64":"..."}
{"id":"<msg-id>", "kind":"protocol_error", "error":"..."}
```

### Behavioural decisions (locked)

- **Window model.** Hybrid: HUD by default (always-on-top, cross-Space, top-right cascade per session), promote-to-standard-window via right-click on a tab.
- **Multiplexing.** Per-session HUDs. Each MCP session's first `show_X` spawns its HUD. Subsequent calls add tabs. Tear-out spawns sibling HUDs in the same session. Promote moves a single tab into a standard `NSWindow`.
- **Naming.** Slots are upserted by name, scoped per session. Same name → in-place update. Different name → new tab. Latest-wins on rapid re-renders. If the user has closed a panel and the agent later calls `show("X", …)` with the same name, the panel **reopens** — the agent's purpose is to render visual answers, and the user can dismiss again if unwanted.
- **Lifecycle.** Sidecar disconnect → HUD orphans with "session ended" badge; same-UUID reconnect within 60 s reattaches. App quit kills all panels (no disk persistence in v0.1).
- **Iteration loop.** Every `show_X` returns a screenshot by default. `image` returns the image itself; other types return a snapshot of the rendered WKWebView. Async-safe via `renderComplete` JS bridge with 5 s timeout. Capped at 1600×4000 px 2× scale.
- **Failure feedback.** Three-tier: sidecar pre-flight (path/MIME/size) → app-side render error wrapped in styled in-DOM error panel → snapshot of error panel returned alongside structured error text. Update from valid → invalid shows the error, not the previous render.
- **Security (free-tier defenses, baked into Phase 1).** WKWebView CSP with `connect-src 'none'`. Mermaid `securityLevel: 'strict'`. `marked` sanitize + DOMPurify safe-HTML subset (preserve `<details>`, `<kbd>`, `<mark>`, basic table attrs). One JS bridge handler only. No file/clipboard/geolocation. `decidePolicyForNavigationAction` opens external links via `NSWorkspace`.
- **Size caps (loose, mistake-catching).** MD inline 10 MB; MD path 50 MB; SVG inline 50 MB; Mermaid 1 MB; Image 1 GB file with 32000² pixel downscale ceiling.
- **Theming.** Single bundled `theme.css` with CSS-variable light/dark themes driven by `prefers-color-scheme`. Renderer-specific styles layer on top.
- **Distribution.** App-bundled sidecar (`bun build --compile`) inside `Contents/Resources/`. Single `.app` install (DMG or Homebrew Cask). Ad-hoc signed in v0.1; Developer-ID + notarization deferred.
- **Activation policy.** App stays `.accessory` (LSUIElement) while only HUDs exist. Toggles to `.regular` when ≥1 promoted window exists, back to `.accessory` when last closes.

### Phasing (mirrored to ROADMAP.md at repo root)

- **Phase 0 — Scaffolding.** Repo skeleton, `xcodegen` `project.yml`, `bun` project, single `.app` target, menu-bar app boots, control server listens on socket, sidecar handshakes (no tools, no renderers, ping round-trip works).
- **Phase 1 — Markdown vertical slice.** End-to-end for one type. Lands all load-bearing abstractions: `show_markdown` tool, wire protocol, single-tab HUD window, `WebViewPanelRenderer` base + `MarkdownRenderer`, theme.css, free-tier security, `renderComplete` async bridge with 5 s timeout, snapshot capture → MCP image response, render-error path.
- **Phase 2 — Remaining renderers.** Add `SVG`, `Mermaid`, `Image`. Validates the three-file extensibility pattern by paying it back three times.
- **Phase 3 — Multiplexing.** Multi-tab HUD, tab strip with hover-reveal, per-session HUD scoping, cascade positioning, `list`/`close`/`inspect` tools, tear-out.
- **Phase 4 — Lifecycle.** Sidecar handshake with session UUID, orphan-on-disconnect with badge, 60 s reconnect window, multi-sidecar coordination test.
- **Phase 5 — Promote-to-window + UX polish.** Right-click → promote, `activationPolicy` toggling, settings panel.
- **Phase 6 — Distribution polish.** `bun build --compile` sidecar into `.app/Contents/Resources/`, one-click MCP config writer, ad-hoc-signed DMG.

## Testing Decisions

User selected **comprehensive** v0.1 coverage. No prior test infrastructure exists in the sibling `PipAnything` repo, so v0.1 establishes conventions fresh.

### What makes a good test in this codebase

- **Test external behaviour, not implementation.** Given an input message on the wire, assert what comes back. Given a payload to a renderer, assert the snapshot is non-empty and matches expected dimensions. Don't assert on private state, internal method calls, or class hierarchy.
- **Prefer integration over isolation when isolation costs significantly more.** A SessionManager test that uses a real in-memory socket pair is more valuable than one that mocks both ends; an end-to-end test that drives a real WKWebView with a stub template is more valuable than a unit test of a parser.
- **Tests should survive refactors.** A test that breaks because `MarkdownRenderer` got renamed to `MdRenderer` was a bad test. A test that breaks because `show_markdown(name, content)` started returning a different envelope shape was a good one.
- **No flaky tests in CI.** UI tests that depend on display server state (animation timing, screenshot pixel-comparison) are quarantined to a separate manual suite; CI runs only deterministic suites.
- **One assertion focus per test.** Tests with five unrelated assertions become hard to interpret on failure.

### Modules tested in v0.1 (comprehensive scope)

**Sidecar (Vitest or `bun test`):**

- **`ContentTypeHandler` registry.** Register handlers, assert MCP tool list shape, assert handler-not-found errors.
- **Path resolver.** Tilde expansion, relative resolution, missing-file errors, symlink handling, MIME sniffing on real fixture files (small PNG / JPEG / GIF / corrupt-PNG / not-an-image), size cap enforcement.
- **Each content handler's `validate()`.** Valid args produce envelope; invalid args throw with clear MCP-tool-error message; one-of (`content` xor `path`) enforced for markdown.
- **Session UUID store.** Generates UUID on first read, persists, returns same UUID on subsequent reads, handles missing parent dir.
- **Socket client framing.** Feed in NDJSON byte streams (split across reads, multiple messages per buffer, partial trailing message), assert correct decoding. Encode messages, assert byte-exact NDJSON output. Request/response correlation by `id` (out-of-order responses, multiple in-flight).
- **Autolaunch helper.** Given a fake `process.execPath` and a fake `open` shell-out, assert the resolved `.app` path and the polling loop behavior on connect-success / connect-timeout.

**App (XCTest):**

- **`ControlServer` + `ControlHandlers` (wire round-trip).** Bind to a temp socket; connect a test client; send synthetic `hello`/`upsert`/`close`/`list`/`inspect` NDJSON messages; assert correct response envelopes, including error envelopes for malformed input.
- **`SessionManager` (state machine).** Drive sequences of `connect → upsert → upsert → disconnect → reconnect-within-window → upsert → reconnect-outside-window`; assert HUD count, orphan badges, tab counts at each step.
- **`WebViewPanelRenderer` (with stub template).** Subclass with a stub HTML template that fires `renderComplete({ok:true, width:200, height:100})` immediately. Drive `update()`, await `snapshot()`, assert PNG decodes to a non-zero-byte image of expected dimensions. Then a stub that fires `{ok:false, error:"boom", line:3}`; assert `snapshot()` still returns bytes (the error UI screenshot) and the error info propagates.
- **`SnapshotService`.** Drive a `WKWebView` rendering known-size content; assert snapshot dimensions respect the 1600×4000 cap and 2× scale. Drive an `NSImageView` with a fixture image; assert the snapshot path returns the same bytes (within encode tolerance).
- **`PromoteToWindowController`.** Simulate promote/demote sequences; assert `activationPolicy` transitions (`.accessory` → `.regular` on first promote; back to `.accessory` after last demote); assert the promoted window has correct level (`.normal`, not `.floating`) and Cmd-Tab participation.

### Headless verification env vars (parallel to PipAnything's `PIP_*` family)

- `QUICKSHOW_AUTO_PANEL=1` — on launch, immediately open a HUD with a fixture markdown panel for smoke verification.
- `QUICKSHOW_SOCKET_PATH=/tmp/qs-test.sock` — override the control-socket path so multiple test instances can run in parallel.
- `QUICKSHOW_NO_AUTOLAUNCH=1` — sidecar skips the `open -g` step so tests can drive a pre-launched app.

### Prior art

- **No tests exist in PipAnything** — v0.1 is greenfield for test infrastructure.
- **Architectural prior art (callback-driven managers)** is reusable: PipAnything's `CaptureManager` exposes `onFirstFrame`, `onModeChange`, `onError` callbacks — same shape lets `SessionManager` and `WebViewPanelRenderer` be driven from tests by injecting fake event sources rather than mocking concrete dependencies.
- **PipAnything's CLAUDE.md "wire-protocol mirror" discipline** (Swift `ControlProtocol.swift` ↔ Rust `protocol.rs` change-together) is replicated here as a CI gate (lint script asserts both files contain the same set of `kind:` strings).

## Out of Scope

- **Cross-platform (Linux/Windows).** macOS only in v0.1. The HUD model is built on `NSWindow`/`WKWebView`; porting is a separate design exercise.
- **Capturing windows.** This is not PipAnything; the app does not interact with `ScreenCaptureKit`, AX windows, or anything that captures live external content. Static rendered content only.
- **Plugin runtime / third-party renderers.** Adding a content type requires a code change and a new build. No dynamic plugin loading from disk, no third-party-shipped renderers.
- **Disk persistence of panels across app quit.** App quit kills everything; orphan-and-reconnect handles transient disconnects only. Persistent panels are a v0.2 idea (would need an explicit `pin(name)` verb).
- **`show_html`** — arbitrary HTML rendering. Punted: opens a security design pass (relaxed CSP, fetch privileges, mixed content) that earns its own decision cycle.
- **MCP `resources` surface** (URI-addressable panel state for other tools to query). v0.2 idea; v0.1 is tools-only.
- **Drag-and-drop content into HUDs from the human side** (drop a Mermaid file from Finder onto the HUD to render it). Sidecar is the only producer in v0.1.
- **Click-through latch and *per-overlay* opacity slider** (PipAnything features — per-HUD opacity *picker* exists in v0.1, but a continuous per-overlay slider in the prefs is deferred). Less obviously valuable for static content; deferred unless demand emerges.
- **Auto-hide on source-app focus** (PipAnything feature). Dropped entirely — no concept of a "source app" here; the agent produces, not the window.
- **User-customizable themes.** Single bundled `theme.css` in v0.1. Theme picker is v0.2 if anyone asks.
- **Developer-ID signing + notarization.** Ad-hoc signed for v0.1 (works on the dev machine, Gatekeeper-blocked on others). Distribution-readiness is its own track.
- **App Store distribution.** Not a target. The activation-policy toggling, broad filesystem access via `show_image`, and bundled subprocess (the sidecar inside `Contents/Resources/`) all create App Review friction.
- **Sidecar published independently to npm.** v0.1 is app-bundled-only. Adding `npx mcp-quick-show` as a v0.2 polish is straightforward — the same sidecar binary, just with a path-discovery layer for finding the `.app`.

## Further Notes

### Why MCP-first naming

The `mcp-` prefix signals the primary interface: this is an agent-tooling app. The split between `QuickShow.app` (the GUI) and `mcp-quick-show` (the sidecar binary in MCP config) mirrors PipAnything's `PiPanything.app` / `pipanythingctl` split. Repo name stays `mcp-quick-show`.

### Repo topology

Mirrors PipAnything's monorepo layout:

```
mcp-quick-show/
├── project.yml                  xcodegen spec; single .app target
├── tools/
│   └── build-sidecar.sh         bun build --compile + copy into .app
├── sidecar/                     TypeScript MCP server
│   ├── package.json
│   └── src/
│       ├── index.ts             MCP bootstrap
│       ├── protocol.ts          wire types (paired with Swift ControlProtocol)
│       ├── handlers/            content-type handlers
│       └── ...
├── docs/
│   └── control-protocol.md      protocol reference (parallel to PipAnything's docs/agent-control.md)
├── QuickShow/                   Swift app
│   ├── Info.plist               LSUIElement, etc.
│   └── Sources/
│       ├── App/                 AppDelegate, bootstrap
│       ├── Server/              ControlServer / ControlProtocol / ControlHandlers
│       ├── Sessions/            SessionManager
│       ├── HUD/                 HUDWindow, TabStripView, TabPillView
│       ├── Renderers/           PanelRenderer, RendererRegistry, WebViewPanelRenderer, MarkdownRenderer, SVGRenderer, MermaidRenderer, ImageRenderer
│       ├── Snapshot/            SnapshotService
│       ├── Promote/             PromoteToWindowController
│       └── Settings/            SettingsWindow
├── tests/
│   ├── sidecar/                 bun test / Vitest
│   └── app/                     XCTest target
├── ROADMAP.md                   phase tracking (per CLAUDE.md convention)
├── PRD.md                       this document
├── CLAUDE.md                    project notes for agent sessions
└── README.md
```

### Logging convention

All NSLog lines start with `QuickShow: ` (parallel to PipAnything's `PiPanything: `). All sidecar `console.error` lines start with `[mcp-quick-show] ` so they're greppable in MCP-server stderr captured by Claude Code.

### Coordination across parallel agent sessions

The user runs multiple Claude Code sessions in parallel (per their CLAUDE.md). The control-server / multi-sidecar design naturally supports this: N sidecars (N sessions) all connect to the same Unix socket on the same app process. Each handshake brings a different `session_id`. The app's `SessionManager` multiplexes by session, so one session's `close("notes")` doesn't touch another session's `notes` slot.

### Long-form session plan

Companion plan with full grilling context lives at `~/.claude/plans/mcp-quick-show-v01.md`. Read that for the *why* behind any decision; this PRD is the *what* and *how*.
