import Cocoa
import Foundation
import MCP

// MCPToolHandlers — Phase 1.5 tool registration. Exposes three tools
// that together cover the QuickShow render+markup feedback loop:
//
//   - `show_html`           — render HTML into a HUD panel (mirror of
//                             sidecar/src/handlers/html.ts)
//   - `enable_markup_events` — arm the per-session markup push channel
//                              + return the `Monitor` tail incantation
//                              (mirror of sidecar/src/handlers/enableMarkupEvents.ts)
//   - `get_markup`          — read a marked-up artifact PNG by id and
//                             return it as an MCP image content block
//                             (mirror of sidecar/src/handlers/getMarkup.ts)
//
// Reuses `SessionManager`, `MarkupPaths`, and the renderer/HUD pipeline
// directly — no wire protocol, no NDJSON, no socket. The MCP session id
// (assigned by the SDK) maps 1:1 to the existing `sessionId` argument;
// the libproc-resolved Claude PID (stashed by the router) flows in via
// `registerSession(_:parentPid:)` so `.claudeSpace` placement reuses
// unchanged from "have a PID" onward.

@MainActor
enum MCPToolHandlers {

    // Schema caps — kept in lockstep with sidecar/_groupingFields.ts
    // and sidecar/html.ts. Byte caps are UTF-8 bytes via
    // `Data(_.utf8).count` so multibyte content respects the cap.
    static let groupMaxBytes = 256
    static let descriptionMaxBytes = 256
    static let hudDescriptionMaxBytes = 4 * 1024
    static let inlineMaxBytes = 10 * 1024 * 1024
    static let widthMin: Double = 100
    static let widthMax: Double = 4096

    /// Register tools/list + tools/call on the per-session Server,
    /// capturing the (sessionManager, router, mcpSessionId) trio.
    /// The router is needed to look up the libproc-resolved claudePid
    /// at call time (lookup, not capture, so it stays current).
    static func register(
        on server: Server,
        mcpSessionID: String,
        sessionManager: SessionManager,
        router: MCPSessionRouter
    ) async {
        let showHTML = showHTMLTool()
        let enableMarkup = enableMarkupEventsTool()
        let getMarkup = getMarkupTool()
        let tools: [Tool] = [showHTML, enableMarkup, getMarkup]

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: tools)
        }

        // CallTool handler — runs off the main actor by default,
        // hops back via `await` when calling @MainActor methods on
        // sessionManager / router. mcpSessionID is captured by
        // value; sessionManager + router are class references.
        let sm = sessionManager
        let rt = router
        let sid = mcpSessionID
        await server.withMethodHandler(CallTool.self) { params in
            let args = params.arguments ?? [:]
            switch params.name {
            case showHTML.name:
                return await Self.handleShowHTML(args: args, sm: sm, rt: rt, sid: sid)
            case enableMarkup.name:
                return await Self.handleEnableMarkupEvents(sm: sm, sid: sid)
            case getMarkup.name:
                return await Self.handleGetMarkup(args: args, sid: sid)
            default:
                return CallTool.Result(
                    content: [.text(text: "unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
        }
    }

    // MARK: - show_html dispatch

    private static func handleShowHTML(
        args: [String: Value],
        sm: SessionManager,
        rt: MCPSessionRouter,
        sid: String
    ) async -> CallTool.Result {
        do {
            let normalized = try ShowHTMLArgs.validate(args)
            let claudePid = await rt.claudePidFor(sessionID: sid)
            let (result, snapshot) = try await Self.dispatch(
                sm: sm,
                sessionID: sid,
                claudePid: claudePid,
                args: normalized
            )

            var content: [Tool.Content] = [
                .text(
                    text: "Rendered '\(normalized.name)' (html) — \(result.width)×\(result.height).",
                    annotations: nil,
                    _meta: nil
                )
            ]
            if normalized.returnScreenshot {
                content.append(.image(
                    data: snapshot.base64EncodedString(),
                    mimeType: "image/png",
                    annotations: nil,
                    _meta: nil
                ))
            }
            // P3: 5s after a successful show_html, push a
            // notifications/message to the session's SSE stream.
            // Tests whether Claude Code surfaces server-initiated
            // notifications. Detached so it doesn't block the
            // tool response; captures `sid`, `rt`, panel name
            // by value.
            let panelName = normalized.name
            Task.detached {
                try? await Task.sleep(for: .seconds(5))
                await Self.firePushTest(router: rt, sessionID: sid, panelName: panelName)
            }
            return CallTool.Result(content: content)
        } catch let err as ShowHTMLArgs.ValidationError {
            return CallTool.Result(
                content: [.text(text: "invalid arguments: \(err.message)", annotations: nil, _meta: nil)],
                isError: true
            )
        } catch {
            return CallTool.Result(
                content: [.text(text: "render error: \(error.localizedDescription)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    // MARK: - enable_markup_events dispatch

    private static func handleEnableMarkupEvents(
        sm: SessionManager,
        sid: String
    ) async -> CallTool.Result {
        let logPath: URL
        do {
            logPath = try MarkupPaths.ensureDirs(sid)
        } catch {
            return CallTool.Result(
                content: [.text(
                    text: "failed to prepare markup dirs: \(error.localizedDescription)",
                    annotations: nil, _meta: nil
                )],
                isError: true
            )
        }
        await MainActor.run {
            sm.setFlag(sessionId: sid, key: "markup_events_armed", value: .bool(true))
            // Idempotent — the existing flag-changed Notification fires
            // whether or not the value actually changed; HUDs that
            // already booted observe the change via that channel.
        }
        let text = [
            "Markup events armed for this session.",
            "",
            "To receive notifications when the user presses Send (or closes without sending), start a Monitor:",
            "",
            "  command: `tail -n 0 -F \(logPath.path)`",
            "  persistent: true",
            "  description: \"QuickShow markup events\"",
            "",
            "Each notification will be one NDJSON line.",
            "  - `{\"type\":\"markup_sent\",\"panel\":\"<name>\",\"artifact\":\"<id>\",...}` → call `get_markup(artifact_id: \"<id>\")` to fetch the PNG.",
            "  - `{\"type\":\"markup_dismissed\",\"panel\":\"<name>\",...}` → the user closed the panel without sending. No artifact.",
            "",
            "This call is idempotent — calling again returns the same instructions and leaves the flag armed.",
        ].joined(separator: "\n")
        return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
    }

    // MARK: - get_markup dispatch

    private static let artifactIDPattern: NSRegularExpression = {
        // 8-4-4-4-12 hex, case-insensitive — matches both sidecar (lowercase)
        // and Swift (UUID().uuidString → uppercase) artifact ids.
        try! NSRegularExpression(
            pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            options: [.caseInsensitive]
        )
    }()

    private static func handleGetMarkup(
        args: [String: Value],
        sid: String
    ) async -> CallTool.Result {
        guard let v = args["artifact_id"], let artifactID = v.stringValue else {
            return CallTool.Result(
                content: [.text(
                    text: "invalid artifact_id (must be a UUID like '550e8400-e29b-41d4-a716-446655440000')",
                    annotations: nil, _meta: nil
                )],
                isError: true
            )
        }
        let range = NSRange(artifactID.startIndex..., in: artifactID)
        if artifactIDPattern.firstMatch(in: artifactID, options: [], range: range) == nil {
            return CallTool.Result(
                content: [.text(
                    text: "invalid artifact_id (must be a UUID like '550e8400-e29b-41d4-a716-446655440000')",
                    annotations: nil, _meta: nil
                )],
                isError: true
            )
        }

        let live = MarkupPaths.artifact(sid, id: artifactID)
        let consumedDir = MarkupPaths.artifactsDir(sid).appendingPathComponent(".consumed", isDirectory: true)
        let consumed = consumedDir.appendingPathComponent("\(artifactID).png", isDirectory: false)
        let fm = FileManager.default

        let source: URL
        if fm.fileExists(atPath: live.path) {
            source = live
        } else if fm.fileExists(atPath: consumed.path) {
            return CallTool.Result(
                content: [.text(
                    text: "artifact \(artifactID) was already consumed in this session",
                    annotations: nil, _meta: nil
                )],
                isError: true
            )
        } else {
            return CallTool.Result(
                content: [.text(
                    text: "no artifact named '\(artifactID)' for this session",
                    annotations: nil, _meta: nil
                )],
                isError: true
            )
        }

        let bytes: Data
        do {
            bytes = try Data(contentsOf: source)
        } catch {
            return CallTool.Result(
                content: [.text(
                    text: "failed to read artifact: \(error.localizedDescription)",
                    annotations: nil, _meta: nil
                )],
                isError: true
            )
        }

        // Best-effort: move to .consumed/ so a second get_markup for the
        // same id returns "already consumed". Failure here is non-fatal
        // — we still hand the bytes back.
        do {
            try fm.createDirectory(at: consumedDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fm.removeItem(at: consumed)
            try fm.moveItem(at: source, to: consumed)
        } catch {
            NSLog("QuickShow: get_markup move-to-consumed failed for \(artifactID): \(error)")
        }

        return CallTool.Result(content: [
            .text(text: "markup artifact \(artifactID) (\(bytes.count) bytes)", annotations: nil, _meta: nil),
            .image(data: bytes.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil),
        ])
    }

    // MARK: - P3 push test

    /// Send a `notifications/message` to the given session, ~5s
    /// after `show_html`. The SDK's transport routes server-initiated
    /// notifications onto the session's standalone GET SSE stream
    /// (or its event-store backlog if no GET is open). NSLogs both
    /// outcomes so the proof-point test rig can grep for them.
    @Sendable
    private static func firePushTest(
        router: MCPSessionRouter,
        sessionID: String,
        panelName: String
    ) async {
        guard let server = await router.serverFor(sessionID: sessionID) else {
            await MainActor.run {
                NSLog("QuickShow: P3 push session_gone session=\(sessionID)")
            }
            return
        }
        let msg = Message<LogMessageNotification>(
            method: LogMessageNotification.name,
            params: LogMessageNotification.Parameters(
                level: .info,
                logger: "quickshow.poc",
                data: .object([
                    "event": .string("delayed_push_p3"),
                    "panel": .string(panelName),
                    "session": .string(sessionID),
                    "ts_ms": .int(Int(Date().timeIntervalSince1970 * 1000)),
                ])
            )
        )
        do {
            try await server.notify(msg)
            await MainActor.run {
                NSLog("QuickShow: P3 push SENT session=\(sessionID) panel=\(panelName)")
            }
        } catch {
            await MainActor.run {
                NSLog("QuickShow: P3 push FAILED session=\(sessionID) error=\(error)")
            }
        }
    }

    // MARK: - SessionManager dispatch

    @MainActor
    private static func dispatch(
        sm: SessionManager,
        sessionID: String,
        claudePid: pid_t?,
        args: ShowHTMLArgs
    ) async throws -> (RenderResult, Data) {
        // registerSession is idempotent; we call it before every
        // upsert so a claudePid arriving after the session was
        // created (theoretical — the router stashes it on create)
        // still lands on SessionState.parentPid before the first
        // .claudeSpace placement.
        sm.registerSession(sessionID, parentPid: claudePid)
        return try await sm.upsert(
            sessionId: sessionID,
            name: args.name,
            contentType: "html",
            form: "inline",
            body: args.content,
            width: args.width.map { Double($0) },
            group: args.group,
            description: args.description,
            hudDescription: args.hudDescription
        )
    }

    // MARK: - Tool definition

    private static func showHTMLTool() -> Tool {
        let inputSchema: Value = .object([
            "type": .string("object"),
            "required": .array([.string("name"), .string("content")]),
            "properties": .object([
                "name": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Stable, human-readable slot name (e.g. 'design', 'hero-v2'). Same name updates the existing panel; different name opens a new tab."
                    ),
                ]),
                "content": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Complete, self-contained HTML document (up to 10 MB). Must be a full <html>...</html> with all CSS/JS/fonts/images inlined."
                    ),
                ]),
                "width": .object([
                    "type": .string("number"),
                    "description": .string(
                        "Optional canvas width in points (typically 320–2400). Sizes the WebView's CSS viewport before the page lays out, so responsive designs render at this width."
                    ),
                ]),
                "return_screenshot": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "If true (default), the tool response includes a PNG screenshot of the rendered panel."
                    ),
                    "default": .bool(true),
                ]),
                "group": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Optional grouping key. Panels sharing a `group` are rendered as tabs in the same floating HUD."
                    ),
                ]),
                "description": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Optional short framing line for THIS tab, shown in the panel's description banner above the rendered content. Plain text, ≤256 bytes."
                    ),
                ]),
                "hud_description": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Optional framing paragraph for the whole HUD, shown above the per-tab description. Plain text, ≤4 KB."
                    ),
                ]),
            ]),
        ])

        return Tool(
            name: "show_html",
            description:
                "Render a complete, self-contained HTML document in a floating HUD panel on the user's "
                + "screen, and return a PNG screenshot of the rendered output. Use this for interactive "
                + "design demos, dashboards, and other rich UI that needs CSS + JS. Calling again with "
                + "the same `name` updates the existing panel in place; a different `name` opens a new "
                + "tab. REQUIREMENTS: provide a full <html>...</html> document. Inline ALL styles and "
                + "scripts. Do NOT reference external CDNs.",
            inputSchema: inputSchema
        )
    }

    private static func enableMarkupEventsTool() -> Tool {
        let inputSchema: Value = .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
        return Tool(
            name: "enable_markup_events",
            description:
                "Arm the markup push channel for this session. After calling this, "
                + "the HUD's Send button is enabled on markup-capable panels, and a "
                + "user pressing Send (or closing without sending) emits a one-line "
                + "NDJSON event to a per-session log file. Call this ONCE per session "
                + "before rendering markup-capable panels. The tool response tells you "
                + "the exact `Monitor` command to start watching the events log — when "
                + "you see a `markup_sent` line, call `get_markup(artifact_id)` to "
                + "fetch the image. When you see `markup_dismissed`, the user closed "
                + "the panel without marking up. Idempotent.",
            inputSchema: inputSchema
        )
    }

    private static func getMarkupTool() -> Tool {
        let inputSchema: Value = .object([
            "type": .string("object"),
            "required": .array([.string("artifact_id")]),
            "properties": .object([
                "artifact_id": .object([
                    "type": .string("string"),
                    "description": .string(
                        "UUID of the artifact, copied verbatim from the `artifact` field of a `markup_sent` event line."
                    ),
                ]),
            ]),
        ])
        return Tool(
            name: "get_markup",
            description:
                "Fetch a marked-up panel artifact by id and return it as an image. "
                + "Call this after the Monitor (armed via `enable_markup_events`) "
                + "emits a `markup_sent` line — the `artifact` field on that line is "
                + "the id to pass here. The artifact is moved to a `.consumed/` "
                + "subfolder on success so it's clear which markups have been "
                + "processed. Returns an MCP image (PNG) the model can inspect.",
            inputSchema: inputSchema
        )
    }
}

// MARK: - Args validation

struct ShowHTMLArgs: Sendable {
    let name: String
    let content: String
    let width: Int?
    let returnScreenshot: Bool
    // Empty string vs missing matters: empty → clear, missing → leave alone.
    let group: String?
    let description: String?
    let hudDescription: String?

    struct ValidationError: Error, Sendable {
        let message: String
    }

    static func validate(_ args: [String: Value]) throws -> ShowHTMLArgs {
        guard let nameVal = args["name"], let name = nameVal.stringValue, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ValidationError(message: "`name` must be a non-empty string")
        }
        guard let contentVal = args["content"], let content = contentVal.stringValue, !content.isEmpty else {
            throw ValidationError(message: "`content` must be a non-empty HTML string")
        }
        let contentBytes = Data(content.utf8).count
        if contentBytes > MCPToolHandlers.inlineMaxBytes {
            throw ValidationError(message: "inline content too large: \(contentBytes) bytes > 10 MB cap")
        }

        var width: Int? = nil
        if let widthVal = args["width"], !widthVal.isNull {
            let asDouble: Double? = widthVal.doubleValue ?? widthVal.intValue.map { Double($0) }
            guard let w = asDouble, w.isFinite, w >= MCPToolHandlers.widthMin, w <= MCPToolHandlers.widthMax else {
                throw ValidationError(message: "`width` must be a finite number between 100 and 4096 points")
            }
            width = Int(w.rounded())
        }

        let returnScreenshot: Bool
        if let rsv = args["return_screenshot"], let b = rsv.boolValue {
            returnScreenshot = b
        } else {
            returnScreenshot = true
        }

        let group = try parseBytesCapped(args, key: "group", cap: MCPToolHandlers.groupMaxBytes)
        let description = try parseBytesCapped(args, key: "description", cap: MCPToolHandlers.descriptionMaxBytes)
        let hudDescription = try parseBytesCapped(args, key: "hud_description", cap: MCPToolHandlers.hudDescriptionMaxBytes)

        return ShowHTMLArgs(
            name: name,
            content: content,
            width: width,
            returnScreenshot: returnScreenshot,
            group: group,
            description: description,
            hudDescription: hudDescription
        )
    }

    /// Parse an optional string field with a UTF-8 byte cap. Returns
    /// nil when the field is absent (so the caller preserves
    /// "missing means leave-alone" semantics vs "empty means clear").
    private static func parseBytesCapped(_ args: [String: Value], key: String, cap: Int) throws -> String? {
        guard let v = args[key] else { return nil }
        if v.isNull { return nil }
        guard let s = v.stringValue else {
            throw ValidationError(message: "`\(key)` must be a string when present")
        }
        let bytes = Data(s.utf8).count
        if bytes > cap {
            throw ValidationError(message: "`\(key)` too large: \(bytes) bytes > \(cap) byte cap")
        }
        return s
    }
}
