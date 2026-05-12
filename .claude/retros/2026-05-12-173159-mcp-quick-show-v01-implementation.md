# Retro: 2026-05-12 17:31
Session: be07f564-3a77-44be-894f-fe63ded7437c
Topic: mcp-quick-show-v01-implementation
Branch: main
CWD: /Users/zolat/projects/mcp-quick-show
Duration: ~90 min
Key files: QuickShow/Sources/Renderers/WebViewPanelRenderer.swift, QuickShow/Sources/Sessions/SessionManager.swift, QuickShow/Sources/HUD/HUDWindow.swift, sidecar/src/index.ts, sidecar/src/socket.ts, sidecar/src/handlers/*, tools/copy-resources.sh, tools/build-sidecar.sh, project.yml

## Context
Built all 7 phases of the QuickShow / mcp-quick-show v0.1 PRD from a greenfield repo: macOS menu-bar app (Swift/AppKit) + TypeScript MCP sidecar that renders markdown/SVG/mermaid/images into floating HUD panels and returns PNGs through MCP tool responses. Lifted heavily from sibling project PipAnything per the PRD's "don't reinvent" directive. Shipped a working DMG.

## Learnings
- `WKWebView.loadHTMLString(_, baseURL:)` with a `file://` baseURL does NOT let inline `<script src="libs/x.js">` resolve to sibling files — cross-origin file:// blocks subresource loads silently. Inline the libs into the template at Swift load time instead.
- xcodegen's `type: folder` + `buildPhase: resources` failed mysteriously (build error "The file 'Resources' couldn't be opened"). A `postCompileScripts` rsync was more reliable and preserves directory structure for `Bundle.url(forResource:withExtension:subdirectory:)`.
- `MainActor.assumeIsolated { }` is the right shim for WK delegate methods that are protocol-`nonisolated` but documented to run on the main thread. The Task-hop pattern compiles but loses sync semantics needed for `decisionHandler` calls.
- `bun build --compile` produces a ~60 MB standalone arm64 binary that works inside `.app/Contents/Resources/` with no Node runtime needed.

## Dead ends
- First WKWebView attempt with `baseURL=templates/` and `<link rel=stylesheet>` / `<script src>` — silently hung at upsert because the page loaded but the libs didn't, so `window.__quickshow_render` was undefined. Symptom was a hang, not an error. Fix was inlining; could also have been "set `allowFileAccessFromFileURLs` via private API" but inlining is robust.

## Conventions and decisions
- `verify-phaseN.ts` end-to-end smoke pattern (one per phase) — drives the running app over the real socket with assertions. Faster signal than XCTest for a Swift app under active dev.
- `QUICKSHOW_TEST_*=1` env-var hooks in AppDelegate that run a programmatic flow and log via NSLog, then a shell test greps the log. Mirrors PipAnything's `PIP_TEST_*` pattern.
- Wire-protocol mirror discipline: Swift `ControlProtocol.swift` ↔ TypeScript `protocol.ts` changed together each commit.

## What would have helped at the start
- Knowing the WKWebView file:// cross-origin subresource trap upfront would have saved 10 min of "why does my renderComplete bridge never fire?" debugging.
- `timeout` not being on macOS by default — used `kill -0 $PID` loops instead. Worth a one-liner shell helper in the tools/ dir for future tests.

## Capability gaps
- Gap: Couldn't drive right-click / mouse events from automation to test the context menus + opacity submenu end-to-end.
  - Workaround: Programmatic selector invocation via env-var test hook (TEST_PROMOTE). Compiled-and-looks-right for the others.
  - Suggested unblock: XCUITest target for the app, or a minimal AppleScript/CGEvent harness wrapped in a shell helper.
- Gap: SourceKit linter constantly false-positive on cross-file symbol resolution before xcodegen regenerated the project, drowning out real diagnostics.
  - Workaround: Treated SourceKit output as advisory; trusted `xcodebuild` output for real errors.
  - Suggested unblock: Run `xcodegen generate` automatically when project.yml or new .swift files appear (xcodegen has a `--watch` mode worth wrapping in a hook).
