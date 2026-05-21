import Cocoa
import Foundation
import MCP

// MCPToolHandlers — Phase 1 PoC tool registration. Exposes a single
// tool, `show_html`, mirroring `sidecar/src/handlers/html.ts`'s
// schema and validation rules so a Claude that previously drove the
// stdio sidecar can drive the HTTP server with no behavior change.
//
// Reuses `SessionManager.upsert(...)` directly — no wire protocol,
// no NDJSON, no socket. The MCP session id (assigned by the SDK)
// maps 1:1 to the existing `sessionId` argument; the libproc-
// resolved Claude PID (stashed by the router) flows in via
// `registerSession(_:parentPid:)` so `.claudeSpace` placement
// reuses unchanged from "have a PID" onward.

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

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [showHTML])
        }

        // CallTool handler — runs off the main actor by default,
        // hops back via `await` when calling @MainActor methods on
        // sessionManager / router. mcpSessionID is captured by
        // value; sessionManager + router are class references.
        let sm = sessionManager
        let rt = router
        let sid = mcpSessionID
        await server.withMethodHandler(CallTool.self) { params in
            guard params.name == showHTML.name else {
                return CallTool.Result(
                    content: [.text(text: "unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
            let args = params.arguments ?? [:]
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
