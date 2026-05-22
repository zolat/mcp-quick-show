import Cocoa
import Foundation
import MCP

// MCPToolHandlers — Phase 2 tool registration.
//
// Mirrors `sidecar/src/handlers/*.ts` 1:1. Reuses `SessionManager`,
// `MarkupPaths`, and the renderer/HUD pipeline directly. The MCP
// session id (assigned by the SDK) is used only to default the
// `group` arg when callers omit it; storage is keyed by `group`. The
// libproc-resolved Claude PID flows in via the router stash and
// `registerGroup(_:parentPid:)` so `.claudeSpace` placement reuses
// unchanged from "have a PID" onward.

@MainActor
enum MCPToolHandlers {

    // Size caps (mirroring sidecar handlers exactly).
    static let inlineHTMLMaxBytes = 10 * 1024 * 1024  // html.ts
    static let inlineMarkdownMaxBytes = 10 * 1024 * 1024  // markdown.ts inline
    static let pathMarkdownMaxBytes = 50 * 1024 * 1024  // markdown.ts path
    static let inlineSVGMaxBytes = 50 * 1024 * 1024  // svg.ts
    static let inlineMermaidMaxBytes = 1 * 1024 * 1024  // mermaid.ts
    static let pathImageMaxBytes = 1024 * 1024 * 1024  // image.ts (1 GB)

    /// Register tools/list + tools/call on the per-session Server,
    /// capturing the (sessionManager, router, mcpSessionId, port) tuple.
    static func register(
        on server: Server,
        mcpSessionID: String,
        sessionManager: SessionManager,
        router: MCPSessionRouter,
        markupEvents: MarkupEventsStream,
        endpointPort: UInt16
    ) async {
        let tools: [Tool] = [
            showHTMLTool(),
            showMarkdownTool(),
            showSVGTool(),
            showMermaidTool(),
            showImageTool(),
            showURLTool(),
            enableMarkupEventsTool(),
            enablePanelEventsTool(),
            getMarkupTool(),
            getShareTool(),
        ]

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: tools)
        }

        let sm = sessionManager
        let rt = router
        let me = markupEvents
        let sid = mcpSessionID
        let port = endpointPort
        await server.withMethodHandler(CallTool.self) { params in
            let args = params.arguments ?? [:]
            switch params.name {
            case "show_html":
                return await Self.handleShowHTML(args: args, sm: sm, rt: rt, sid: sid)
            case "show_markdown":
                return await Self.handleShowMarkdown(args: args, sm: sm, rt: rt, sid: sid)
            case "show_svg":
                return await Self.handleShowSVG(args: args, sm: sm, rt: rt, sid: sid)
            case "show_mermaid":
                return await Self.handleShowMermaid(args: args, sm: sm, rt: rt, sid: sid)
            case "show_image":
                return await Self.handleShowImage(args: args, sm: sm, rt: rt, sid: sid)
            case "show_url":
                return await Self.handleShowURL(args: args, sm: sm, rt: rt, sid: sid)
            case "enable_markup_events":
                return await Self.handleEnableMarkupEvents(args: args, sm: sm, markupEvents: me, sid: sid, port: port)
            case "enable_panel_events":
                return await Self.handleEnablePanelEvents(args: args, sm: sm, sid: sid)
            case "get_markup":
                return await Self.handleGetMarkup(args: args, sid: sid)
            case "get_share":
                return await Self.handleGetShare(args: args, sm: sm, sid: sid)
            default:
                return CallTool.Result(
                    content: [.text(text: "unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
        }
    }

    // MARK: - Generic upsert dispatch

    /// Validated payload for any of the content-bearing show_* tools.
    /// `body` is the resolved string (inline content; for path-form
    /// markdown the file contents; for image the absolute path; for
    /// url the URL string).
    struct UpsertPayload: Sendable {
        let name: String
        let contentType: String  // matches RendererRegistry.typeKey
        let form: String         // "inline" / "path" / "url"
        let body: String
        let width: Int?
        let returnScreenshot: Bool
        let grouping: GroupingFields
    }

    private static func dispatch(
        sm: SessionManager,
        rt: MCPSessionRouter,
        sid: String,
        payload: UpsertPayload
    ) async throws -> (RenderResult, Data) {
        let claudePid = await rt.claudePidFor(sessionID: sid)
        // Resolve the group at the wire boundary so every downstream
        // call has a defined namespace. Omitted `group` means "this
        // MCP session's own group" (= mcpSessionId), preserving
        // today's per-session-default-HUD behaviour.
        let groupKey = payload.grouping.group ?? sid
        sm.registerGroup(groupKey, parentPid: claudePid)
        return try await sm.upsert(
            sessionId: sid,
            name: payload.name,
            contentType: payload.contentType,
            form: payload.form,
            body: payload.body,
            width: payload.width.map { Double($0) },
            group: groupKey,
            description: payload.grouping.description,
            hudDescription: payload.grouping.hudDescription
        )
    }

    private static func renderResultContent(
        payload: UpsertPayload,
        result: RenderResult,
        snapshot: Data,
        snapshotMime: String = "image/png"
    ) -> [Tool.Content] {
        var content: [Tool.Content] = [
            .text(
                text: "Rendered '\(payload.name)' (\(payload.contentType)) — \(result.width)×\(result.height).",
                annotations: nil,
                _meta: nil
            )
        ]
        if payload.returnScreenshot {
            content.append(.image(
                data: snapshot.base64EncodedString(),
                mimeType: snapshotMime,
                annotations: nil,
                _meta: nil
            ))
        }
        return content
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }

    // MARK: - show_html

    private static func handleShowHTML(
        args: [String: Value],
        sm: SessionManager,
        rt: MCPSessionRouter,
        sid: String
    ) async -> CallTool.Result {
        do {
            let name = try ToolValidation.parseName(args)
            guard let cv = args["content"], let content = cv.stringValue, !content.isEmpty else {
                throw ToolValidation.Error(message: "`content` must be a non-empty HTML string")
            }
            let bytes = Data(content.utf8).count
            if bytes > inlineHTMLMaxBytes {
                throw ToolValidation.Error(message: "inline content too large: \(bytes) bytes > 10 MB cap")
            }
            let payload = UpsertPayload(
                name: name,
                contentType: "html",
                form: "inline",
                body: content,
                width: try ToolValidation.parseWidth(args),
                returnScreenshot: ToolValidation.parseReturnScreenshot(args),
                grouping: try ToolValidation.parseGroupingFields(args)
            )
            let (result, snapshot) = try await dispatch(sm: sm, rt: rt, sid: sid, payload: payload)
            return CallTool.Result(content: renderResultContent(payload: payload, result: result, snapshot: snapshot))
        } catch let err as ToolValidation.Error {
            return errorResult("invalid arguments: \(err.message)")
        } catch {
            return errorResult("render error: \(error.localizedDescription)")
        }
    }

    // MARK: - show_markdown

    private static func handleShowMarkdown(
        args: [String: Value],
        sm: SessionManager,
        rt: MCPSessionRouter,
        sid: String
    ) async -> CallTool.Result {
        do {
            let name = try ToolValidation.parseName(args)
            let inline = args["content"]?.stringValue
            let pathArg = args["path"]?.stringValue
            let hasInline = (inline != nil)
            let hasPath = (pathArg != nil)
            if hasInline == hasPath {
                throw ToolValidation.Error(message: "exactly one of `content` or `path` must be provided")
            }
            let body: String
            if hasInline {
                let content = inline!
                let bytes = Data(content.utf8).count
                if bytes > inlineMarkdownMaxBytes {
                    throw ToolValidation.Error(message: "inline content too large: \(bytes) bytes > 10 MB cap")
                }
                body = content
            } else {
                let resolved: MCPPathResolver.Resolved
                do {
                    resolved = try MCPPathResolver.resolve(
                        pathArg!,
                        maxBytes: pathMarkdownMaxBytes,
                        allowedMimes: ["text/plain"]
                    )
                } catch let err as MCPPathResolver.Error {
                    throw ToolValidation.Error(message: err.message)
                }
                do {
                    body = try String(contentsOfFile: resolved.absolutePath, encoding: .utf8)
                } catch {
                    throw ToolValidation.Error(message: "failed to read \(resolved.absolutePath): \(error.localizedDescription)")
                }
            }
            let payload = UpsertPayload(
                name: name,
                contentType: "markdown",
                form: "inline",
                body: body,
                width: nil,
                returnScreenshot: ToolValidation.parseReturnScreenshot(args),
                grouping: try ToolValidation.parseGroupingFields(args)
            )
            let (result, snapshot) = try await dispatch(sm: sm, rt: rt, sid: sid, payload: payload)
            return CallTool.Result(content: renderResultContent(payload: payload, result: result, snapshot: snapshot))
        } catch let err as ToolValidation.Error {
            return errorResult("invalid arguments: \(err.message)")
        } catch {
            return errorResult("render error: \(error.localizedDescription)")
        }
    }

    // MARK: - show_svg

    private static func handleShowSVG(
        args: [String: Value],
        sm: SessionManager,
        rt: MCPSessionRouter,
        sid: String
    ) async -> CallTool.Result {
        do {
            let name = try ToolValidation.parseName(args)
            guard let cv = args["content"], let content = cv.stringValue,
                  !content.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                throw ToolValidation.Error(message: "`content` must be a non-empty SVG string")
            }
            let bytes = Data(content.utf8).count
            if bytes > inlineSVGMaxBytes {
                throw ToolValidation.Error(message: "SVG too large: \(bytes) bytes > 50 MB cap")
            }
            // Cheap pre-flight (matches sidecar). Actual <svg> presence
            // is enforced by the template's DOMPurify pass.
            if content.range(of: "<svg[\\s>]", options: [.regularExpression, .caseInsensitive]) == nil {
                throw ToolValidation.Error(message: "content does not contain an <svg> element")
            }
            let payload = UpsertPayload(
                name: name,
                contentType: "svg",
                form: "inline",
                body: content,
                width: nil,
                returnScreenshot: ToolValidation.parseReturnScreenshot(args),
                grouping: try ToolValidation.parseGroupingFields(args)
            )
            let (result, snapshot) = try await dispatch(sm: sm, rt: rt, sid: sid, payload: payload)
            return CallTool.Result(content: renderResultContent(payload: payload, result: result, snapshot: snapshot))
        } catch let err as ToolValidation.Error {
            return errorResult("invalid arguments: \(err.message)")
        } catch {
            return errorResult("render error: \(error.localizedDescription)")
        }
    }

    // MARK: - show_mermaid

    private static func handleShowMermaid(
        args: [String: Value],
        sm: SessionManager,
        rt: MCPSessionRouter,
        sid: String
    ) async -> CallTool.Result {
        do {
            let name = try ToolValidation.parseName(args)
            guard let dv = args["definition"], let definition = dv.stringValue,
                  !definition.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                throw ToolValidation.Error(message: "`definition` must be a non-empty string")
            }
            let bytes = Data(definition.utf8).count
            if bytes > inlineMermaidMaxBytes {
                throw ToolValidation.Error(message: "mermaid spec too large: \(bytes) bytes > 1 MB cap")
            }
            let payload = UpsertPayload(
                name: name,
                contentType: "mermaid",
                form: "inline",
                body: definition,
                width: nil,
                returnScreenshot: ToolValidation.parseReturnScreenshot(args),
                grouping: try ToolValidation.parseGroupingFields(args)
            )
            let (result, snapshot) = try await dispatch(sm: sm, rt: rt, sid: sid, payload: payload)
            return CallTool.Result(content: renderResultContent(payload: payload, result: result, snapshot: snapshot))
        } catch let err as ToolValidation.Error {
            return errorResult("invalid arguments: \(err.message)")
        } catch {
            return errorResult("render error: \(error.localizedDescription)")
        }
    }

    // MARK: - show_image

    private static func handleShowImage(
        args: [String: Value],
        sm: SessionManager,
        rt: MCPSessionRouter,
        sid: String
    ) async -> CallTool.Result {
        do {
            let name = try ToolValidation.parseName(args)
            guard let pv = args["path"], let pathArg = pv.stringValue,
                  !pathArg.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                throw ToolValidation.Error(message: "`path` must be a non-empty string")
            }
            let resolved: MCPPathResolver.Resolved
            do {
                resolved = try MCPPathResolver.resolve(
                    pathArg,
                    maxBytes: pathImageMaxBytes,
                    allowedMimes: ["image/png", "image/jpeg", "image/gif", "image/webp"]
                )
            } catch let err as MCPPathResolver.Error {
                throw ToolValidation.Error(message: err.message)
            }
            let payload = UpsertPayload(
                name: name,
                contentType: "image",
                form: "path",
                body: resolved.absolutePath,
                width: nil,
                returnScreenshot: ToolValidation.parseReturnScreenshot(args),
                grouping: try ToolValidation.parseGroupingFields(args)
            )
            let (result, snapshot) = try await dispatch(sm: sm, rt: rt, sid: sid, payload: payload)
            // PRD: show_image returns the image bytes themselves
            // (ImageRenderer.snapshot() caches and returns
            // lastImageData), not a screenshot of the panel.
            // MIME hardcoded to image/png for response parity with the
            // sidecar — the UI agent sniffs in practice.
            return CallTool.Result(content: renderResultContent(
                payload: payload, result: result, snapshot: snapshot
            ))
        } catch let err as ToolValidation.Error {
            return errorResult("invalid arguments: \(err.message)")
        } catch {
            return errorResult("render error: \(error.localizedDescription)")
        }
    }

    // MARK: - show_url

    private static func handleShowURL(
        args: [String: Value],
        sm: SessionManager,
        rt: MCPSessionRouter,
        sid: String
    ) async -> CallTool.Result {
        do {
            let name = try ToolValidation.parseName(args)
            guard let uv = args["url"], let urlStr = uv.stringValue,
                  !urlStr.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                throw ToolValidation.Error(message: "`url` must be a non-empty string")
            }
            guard let parsed = URL(string: urlStr) else {
                throw ToolValidation.Error(message: "`url` is not a valid URL: \(urlStr)")
            }
            let scheme = parsed.scheme?.lowercased() ?? ""
            guard scheme == "http" || scheme == "https" else {
                throw ToolValidation.Error(
                    message: "`url` must use http: or https: (got '\(scheme):')"
                )
            }
            let payload = UpsertPayload(
                name: name,
                contentType: "url",
                form: "url",
                body: parsed.absoluteString,
                width: try ToolValidation.parseWidth(args),
                returnScreenshot: ToolValidation.parseReturnScreenshot(args),
                grouping: try ToolValidation.parseGroupingFields(args)
            )
            let (result, snapshot) = try await dispatch(sm: sm, rt: rt, sid: sid, payload: payload)
            return CallTool.Result(content: renderResultContent(payload: payload, result: result, snapshot: snapshot))
        } catch let err as ToolValidation.Error {
            return errorResult("invalid arguments: \(err.message)")
        } catch {
            return errorResult("render error: \(error.localizedDescription)")
        }
    }

    // MARK: - enable_markup_events dispatch

    private static func handleEnableMarkupEvents(
        args: [String: Value],
        sm: SessionManager,
        markupEvents: MarkupEventsStream,
        sid: String,
        port: UInt16
    ) async -> CallTool.Result {
        let groupKey: String
        do {
            groupKey = try ToolValidation.parseBytesCapped(
                args, key: "group", cap: ToolValidation.groupMaxBytes
            ) ?? sid
        } catch let err as ToolValidation.Error {
            return errorResult("invalid arguments: \(err.message)")
        } catch {
            return errorResult("invalid arguments: \(error.localizedDescription)")
        }
        let logPath: URL
        do {
            logPath = try MarkupPaths.ensureDirs(groupKey)
        } catch {
            return errorResult("failed to prepare markup dirs: \(error.localizedDescription)")
        }
        let listenerConnected = await markupEvents.hasSubscriber(group: groupKey)
        await MainActor.run {
            sm.setFlag(group: groupKey, key: "markup_events_armed", value: .bool(true))
        }
        let monitorCommand = "curl -sN -H \"Mcp-Session-Id: \(groupKey)\" http://127.0.0.1:\(port)/markup-events | grep --line-buffered -v '\"type\":\"heartbeat\"'"

        var lines: [String] = []
        if !listenerConnected {
            lines += [
                "⚠️  No live markup-events consumer connected for this session.",
                "",
                "Markup events will be appended to the on-disk log (forensic), but no live notification will reach you until the Monitor below is running. Start the Monitor BEFORE the user begins drawing.",
                "",
            ]
        }
        lines += [
            "Markup events armed for this session.",
            "",
            "Recommended Monitor (off-MCP NDJSON stream — sidesteps the SDK's single-SSE-per-session limit, and the app knows you're listening):",
            "",
            "  command: `\(monitorCommand)`",
            "  persistent: true",
            "  description: \"QuickShow markup events\"",
            "",
            "Each notification is one JSON line:",
            "  - `{\"type\":\"markup_sent\",\"panel\":\"<name>\",\"artifact\":\"<id>\",...}` → call `get_markup(artifact_id: \"<id>\")` to fetch the PNG.",
            "  - `{\"type\":\"markup_dismissed\",\"panel\":\"<name>\",...}` → user closed the panel without sending.",
            "",
            "Forensic log (also written, useful for `claude --resume` or post-hoc inspection): \(logPath.path)",
            "",
            "This call is idempotent — calling again returns the same instructions and leaves the flag armed.",
        ]
        return CallTool.Result(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)])
    }

    // MARK: - enable_panel_events dispatch

    private static func handleEnablePanelEvents(
        args: [String: Value],
        sm: SessionManager,
        sid: String
    ) async -> CallTool.Result {
        let groupKey: String
        do {
            groupKey = try ToolValidation.parseBytesCapped(
                args, key: "group", cap: ToolValidation.groupMaxBytes
            ) ?? sid
        } catch let err as ToolValidation.Error {
            return errorResult("invalid arguments: \(err.message)")
        } catch {
            return errorResult("invalid arguments: \(error.localizedDescription)")
        }
        let logPath: URL
        do {
            logPath = try MarkupPaths.ensureDirs(groupKey)
        } catch {
            return errorResult("failed to prepare events dir: \(error.localizedDescription)")
        }
        await MainActor.run {
            sm.setFlag(group: groupKey, key: "panel_events_armed", value: .bool(true))
        }
        let text = [
            "Panel events armed for this session.",
            "",
            "To receive notifications when a `show_html` (or other WebView) panel calls `window.quickshow.emit(...)`, start a Monitor:",
            "",
            "  command: `tail -n 0 -F \(logPath.path)`",
            "  persistent: true",
            "  description: \"QuickShow panel events\"",
            "",
            "Each notification will be one NDJSON line.",
            "  - `{\"type\":\"panel_event\",\"panel\":\"<name>\",\"payload\":<json>,\"ts\":<ms>}` → the agent-defined payload your HTML emitted.",
            "  - `{\"type\":\"panel_event_dropped\",\"panel\":\"<name>\",\"dropped\":<n>,\"ts\":<ms>}` → the throttle (20 events/sec/panel) discarded `n` emits in the last second. Throttle the page if you see this.",
            "",
            "JS surface inside your panel HTML:",
            "  `window.quickshow.emit(payload)`  — payload is any JSON-serializable value (typically `{type, ...}`).",
            "",
            "If you also want markup feedback (user drawing on the panel + Send), call `enable_markup_events` too — the channels are independent and share this same log.",
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
            return errorResult("invalid artifact_id (must be a UUID like '550e8400-e29b-41d4-a716-446655440000')")
        }
        let range = NSRange(artifactID.startIndex..., in: artifactID)
        if artifactIDPattern.firstMatch(in: artifactID, options: [], range: range) == nil {
            return errorResult("invalid artifact_id (must be a UUID like '550e8400-e29b-41d4-a716-446655440000')")
        }
        let groupKey: String
        do {
            groupKey = try ToolValidation.parseBytesCapped(
                args, key: "group", cap: ToolValidation.groupMaxBytes
            ) ?? sid
        } catch let err as ToolValidation.Error {
            return errorResult("invalid arguments: \(err.message)")
        } catch {
            return errorResult("invalid arguments: \(error.localizedDescription)")
        }

        let live = MarkupPaths.artifact(groupKey, id: artifactID)
        let consumedDir = MarkupPaths.artifactsDir(groupKey).appendingPathComponent(".consumed", isDirectory: true)
        let consumed = consumedDir.appendingPathComponent("\(artifactID).png", isDirectory: false)
        let fm = FileManager.default

        let source: URL
        if fm.fileExists(atPath: live.path) {
            source = live
        } else if fm.fileExists(atPath: consumed.path) {
            return errorResult("artifact \(artifactID) was already consumed in this session")
        } else {
            return errorResult("no artifact named '\(artifactID)' for this session")
        }

        let bytes: Data
        do {
            bytes = try Data(contentsOf: source)
        } catch {
            return errorResult("failed to read artifact: \(error.localizedDescription)")
        }

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

    // MARK: - get_share dispatch

    /// Mirror of `ShareID.pattern` — 12 lowercase hex chars.
    private static let shareIDPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: "^[0-9a-f]{12}$", options: [])
    }()

    private static func handleGetShare(
        args: [String: Value],
        sm: SessionManager,
        sid: String
    ) async -> CallTool.Result {
        guard let v = args["id"], let id = v.stringValue else {
            return errorResult("invalid share id (must be a 12-char lowercase-hex string, e.g. 'a1b2c3d4e5f6')")
        }
        let range = NSRange(id.startIndex..., in: id)
        if shareIDPattern.firstMatch(in: id, options: [], range: range) == nil {
            return errorResult("invalid share id (must be a 12-char lowercase-hex string, e.g. 'a1b2c3d4e5f6')")
        }
        // `group` is accepted in the input schema today but not load-
        // bearing yet — it routes via the MCP session id in 2.1 and
        // flips to targetGroup in 2.2 once the canonical namespace
        // changes. Validate the cap so callers can't smuggle a 50KB
        // string through.
        _ = try? ToolValidation.parseBytesCapped(args, key: "group", cap: ToolValidation.groupMaxBytes)

        // .consumed/<id>.png fallback — same discipline as get_markup.
        let consumedDir = MarkupPaths.artifactsDir(sid).appendingPathComponent(".consumed", isDirectory: true)
        let consumed = consumedDir.appendingPathComponent("\(id).png", isDirectory: false)
        let fm = FileManager.default

        let claimed: SessionManager.ClaimedShare
        do {
            claimed = try sm.claimShare(shareID: id, targetSessionID: sid)
        } catch {
            // Same-session fallback (re-fetch after consume).
            if fm.fileExists(atPath: consumed.path) {
                return errorResult("share \(id) was already consumed in this session")
            }
            let reason = (error as? ControlError).map { ce -> String in
                if case let .invalidPayload(msg) = ce { return msg }
                return "\(ce)"
            } ?? error.localizedDescription
            return errorResult("share \(id) not available: \(reason)")
        }

        let live = MarkupPaths.artifact(sid, id: id)
        let bytes: Data
        do {
            bytes = try Data(contentsOf: live)
        } catch {
            return errorResult(
                "share \(id) was claimed (panel '\(claimed.panelName)', content '\(claimed.contentType)') but the image couldn't be read: \(error.localizedDescription)"
            )
        }

        do {
            try fm.createDirectory(at: consumedDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fm.removeItem(at: consumed)
            try fm.moveItem(at: live, to: consumed)
        } catch {
            NSLog("QuickShow: get_share move-to-consumed failed for \(id): \(error)")
        }

        let text =
            "QuickShow share \(id) attached (panel '\(claimed.panelName)', content '\(claimed.contentType)'). "
            + "The originating HUD is now in this session — call show_url / show_image / show_html / show_markdown "
            + "with name=\"\(claimed.panelName)\" to update it in place, or enable_markup_events to let the user "
            + "annotate it again. Image (\(bytes.count) bytes) follows."
        return CallTool.Result(content: [
            .text(text: text, annotations: nil, _meta: nil),
            .image(data: bytes.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil),
        ])
    }

    // MARK: - Tool definitions

    private static func showHTMLTool() -> Tool {
        var properties: [String: Value] = [
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
        ]
        for (k, v) in ToolValidation.groupingSchemaProps { properties[k] = v }
        return Tool(
            name: "show_html",
            description:
                "Render a complete, self-contained HTML document in a floating HUD panel on the user's "
                + "screen, and return a PNG screenshot of the rendered output. Use this for interactive "
                + "design demos, dashboards, and other rich UI that needs CSS + JS. Calling again with "
                + "the same `name` updates the existing panel in place; a different `name` opens a new "
                + "tab. REQUIREMENTS: provide a full <html>...</html> document. Inline ALL styles and "
                + "scripts. Do NOT reference external CDNs.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("name"), .string("content")]),
                "properties": .object(properties),
            ])
        )
    }

    private static func showMarkdownTool() -> Tool {
        var properties: [String: Value] = [
            "name": .object([
                "type": .string("string"),
                "description": .string(
                    "Stable, human-readable slot name (e.g. 'arch', 'plan-v2'). Same name updates the existing panel; different name opens a new one."
                ),
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string(
                    "Inline markdown text (up to 10 MB). Mutually exclusive with `path`."
                ),
            ]),
            "path": .object([
                "type": .string("string"),
                "description": .string(
                    "Filesystem path to a markdown file (up to 50 MB). Supports ~ and relative paths. Mutually exclusive with `content`."
                ),
            ]),
            "return_screenshot": .object([
                "type": .string("boolean"),
                "description": .string(
                    "If true (default), the tool response includes a PNG screenshot of the rendered panel. Set to false to save tokens when you don't need to verify the output."
                ),
                "default": .bool(true),
            ]),
        ]
        for (k, v) in ToolValidation.groupingSchemaProps { properties[k] = v }
        return Tool(
            name: "show_markdown",
            description:
                "Render a markdown string or file in a floating HUD panel on the user's screen, and "
                + "return a PNG screenshot of the rendered output. Use this to surface long-form reports, "
                + "summaries, or rendered docs visually instead of dumping text into the chat. Calling "
                + "again with the same `name` updates the existing panel in place; a different `name` "
                + "opens a new tab. Exactly one of `content` or `path` must be provided.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("name")]),
                "properties": .object(properties),
            ])
        )
    }

    private static func showSVGTool() -> Tool {
        var properties: [String: Value] = [
            "name": .object([
                "type": .string("string"),
                "description": .string("Stable, human-readable slot name. Same name updates in place."),
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string(
                    "Inline SVG markup (must contain an <svg> root element). Up to 50 MB."
                ),
            ]),
            "return_screenshot": .object([
                "type": .string("boolean"),
                "description": .string("If true (default), include a PNG snapshot in the response."),
                "default": .bool(true),
            ]),
        ]
        for (k, v) in ToolValidation.groupingSchemaProps { properties[k] = v }
        return Tool(
            name: "show_svg",
            description:
                "Render an inline SVG image in a floating HUD panel on the user's screen, and return "
                + "a PNG screenshot of the rendered output. Use this for hand-drawn or generated "
                + "vector visualizations, annotated diagrams, illustrations. The SVG is sanitized "
                + "(scripts, event handlers, foreignObject stripped). Same `name` updates the existing "
                + "panel in place.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("name"), .string("content")]),
                "properties": .object(properties),
            ])
        )
    }

    private static func showMermaidTool() -> Tool {
        var properties: [String: Value] = [
            "name": .object([
                "type": .string("string"),
                "description": .string("Stable slot name. Same name updates in place."),
            ]),
            "definition": .object([
                "type": .string("string"),
                "description": .string(
                    "Mermaid diagram source. Starts with the diagram type, e.g. 'flowchart LR\\nA-->B'."
                ),
            ]),
            "return_screenshot": .object([
                "type": .string("boolean"),
                "description": .string("If true (default), include a PNG snapshot."),
                "default": .bool(true),
            ]),
        ]
        for (k, v) in ToolValidation.groupingSchemaProps { properties[k] = v }
        return Tool(
            name: "show_mermaid",
            description:
                "Render a Mermaid diagram (flowchart, sequence, class, state, ER, gantt, …) in a "
                + "floating HUD panel on the user's screen, and return a PNG screenshot. Pass the "
                + "definition string starting with the diagram type (e.g. 'graph LR; A-->B'). On a "
                + "syntax error the response is a render_error with the parser's line number so you "
                + "can fix and retry. Same `name` updates the existing panel in place.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("name"), .string("definition")]),
                "properties": .object(properties),
            ])
        )
    }

    private static func showImageTool() -> Tool {
        var properties: [String: Value] = [
            "name": .object([
                "type": .string("string"),
                "description": .string("Stable slot name. Same name updates in place."),
            ]),
            "path": .object([
                "type": .string("string"),
                "description": .string(
                    "Filesystem path to an image file (PNG/JPEG/GIF/WebP). Supports ~ and relative paths."
                ),
            ]),
            "return_screenshot": .object([
                "type": .string("boolean"),
                "description": .string(
                    "If true (default), include the image bytes in the response. Set to false to save tokens when the agent doesn't need to inspect."
                ),
                "default": .bool(true),
            ]),
        ]
        for (k, v) in ToolValidation.groupingSchemaProps { properties[k] = v }
        return Tool(
            name: "show_image",
            description:
                "Display an existing image file (PNG, JPEG, GIF, WebP) in a floating HUD panel on "
                + "the user's screen. Path can be absolute, relative to cwd, or use `~`. The response "
                + "includes the image bytes (not a screenshot of the panel). Same `name` updates the "
                + "existing panel in place.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("name"), .string("path")]),
                "properties": .object(properties),
            ])
        )
    }

    private static func showURLTool() -> Tool {
        var properties: [String: Value] = [
            "name": .object([
                "type": .string("string"),
                "description": .string(
                    "Stable, human-readable slot name (e.g. 'spec', 'staging'). Same name reloads the existing panel; different name opens a new tab."
                ),
            ]),
            "url": .object([
                "type": .string("string"),
                "description": .string(
                    "Absolute http(s) URL to load. `file:`, `javascript:`, and `data:` URLs are rejected — use `show_html` for inline content or `show_image` for local files."
                ),
            ]),
            "width": .object([
                "type": .string("number"),
                "description": .string(
                    "Optional canvas width in points (100–4096). Sizes the WebView's CSS viewport before navigation, so responsive sites render at this width. If omitted, the default ~400pt viewport is used."
                ),
            ]),
            "return_screenshot": .object([
                "type": .string("boolean"),
                "description": .string(
                    "If true (default), the tool response includes a PNG screenshot of the loaded page. Set to false to save tokens when you don't need to verify."
                ),
                "default": .bool(true),
            ]),
        ]
        for (k, v) in ToolValidation.groupingSchemaProps { properties[k] = v }
        return Tool(
            name: "show_url",
            description:
                "Load a live URL in a floating HUD panel on the user's screen, and return "
                + "a PNG screenshot of the rendered page. Use this to point the user at an "
                + "online document, spec, or article you want them to read, or to show them "
                + "a running site (local dev server, staging URL) during end-to-end "
                + "verification. Calling again with the same `name` reloads the panel with "
                + "the new URL; a different `name` opens a new tab. Same-origin navigation "
                + "works in-place (the user can click around); cross-origin links open in "
                + "the default browser. Only http(s) URLs are accepted. "
                + "Pair with `enable_markup_events` to let the user circle what's wrong on "
                + "a real page.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("name"), .string("url")]),
                "properties": .object(properties),
            ])
        )
    }

    private static func enableMarkupEventsTool() -> Tool {
        return Tool(
            name: "enable_markup_events",
            description:
                "Arm the markup push channel for a group. After calling this, the HUD's "
                + "Send button is enabled on markup-capable panels in that group, and a "
                + "user pressing Send (or closing without sending) emits a one-line "
                + "NDJSON event to the group's events log. Call this ONCE per group "
                + "before rendering markup-capable panels into it. The tool response tells "
                + "you the exact `Monitor` command to start watching the events log — "
                + "when you see a `markup_sent` line, call `get_markup(artifact_id, group)` "
                + "to fetch the image. When you see `markup_dismissed`, the user closed "
                + "the panel without marking up. Idempotent. Pass the same `group` you "
                + "use on `show_*` calls; if omitted, defaults to your MCP session's group.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "group": .object([
                        "type": .string("string"),
                        "description": .string(
                            "The group whose markup channel to arm. If omitted, defaults to this MCP session's own group. ≤256 bytes."
                        ),
                    ]),
                ]),
            ])
        )
    }

    private static func enablePanelEventsTool() -> Tool {
        return Tool(
            name: "enable_panel_events",
            description:
                "Arm the panel-event push channel for a group. After calling this, agent "
                + "HTML rendered via `show_html` (or any WebView panel) in that group "
                + "can call `window.quickshow.emit(payload)` and the payload lands as a "
                + "one-line NDJSON event in the group's events log. Call this ONCE per "
                + "group before rendering interactive panels into it. The tool response "
                + "tells you the exact `Monitor` command to start watching the events "
                + "log — react to `panel_event` lines (your free-form payload, "
                + "agent-defined semantics) and `panel_event_dropped` lines (throttle "
                + "warning, ≥1 event/sec was discarded). Independent of "
                + "`enable_markup_events`; arm either, both, or neither. Idempotent. "
                + "Pass the same `group` you use on `show_*` calls; if omitted, defaults "
                + "to your MCP session's group.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "group": .object([
                        "type": .string("string"),
                        "description": .string(
                            "The group whose panel-events channel to arm. If omitted, defaults to this MCP session's own group. ≤256 bytes."
                        ),
                    ]),
                ]),
            ])
        )
    }

    private static func getShareTool() -> Tool {
        return Tool(
            name: "get_share",
            description:
                "Fetch a user-initiated QuickShow share by id and return it as an image. "
                + "Call this when you see a `[quickshow-share:<id>]` token in a user message — "
                + "the user has selected (and possibly annotated) content in a QuickShow window "
                + "and wants you to receive it. The returned image is user-supplied input; treat "
                + "it the same way you'd treat an image the user pasted directly. "
                + "Side effect: the on-screen HUD migrates into this session, so you can keep "
                + "working with it — call `show_*` with the panel name (returned in the "
                + "response text) to update its content, or `enable_markup_events` to let the "
                + "user draw on it again. First-claim-wins: a second `get_share` of the same id "
                + "from a different session returns an error.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("id")]),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string(
                            "12-char lowercase-hex share id, copied verbatim from the `[quickshow-share:<id>]` token the user pasted."
                        ),
                    ]),
                    "group": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Optional grouping key for where the migrated HUD should land. If omitted, the HUD lands in the session's default HUD. ≤256 bytes."
                        ),
                    ]),
                ]),
            ])
        )
    }

    private static func getMarkupTool() -> Tool {
        return Tool(
            name: "get_markup",
            description:
                "Fetch a marked-up panel artifact by id and return it as an image. "
                + "Call this after the Monitor (armed via `enable_markup_events`) "
                + "emits a `markup_sent` line — the `artifact` field on that line is "
                + "the id to pass here. The artifact is moved to a `.consumed/` "
                + "subfolder on success so it's clear which markups have been "
                + "processed. Returns an MCP image (PNG) the model can inspect. "
                + "Pass the same `group` you used on `enable_markup_events`; if omitted, "
                + "defaults to this MCP session's group.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("artifact_id")]),
                "properties": .object([
                    "artifact_id": .object([
                        "type": .string("string"),
                        "description": .string(
                            "UUID of the artifact, copied verbatim from the `artifact` field of a `markup_sent` event line."
                        ),
                    ]),
                    "group": .object([
                        "type": .string("string"),
                        "description": .string(
                            "The group the artifact lives under. If omitted, defaults to this MCP session's own group. ≤256 bytes."
                        ),
                    ]),
                ]),
            ])
        )
    }
}
