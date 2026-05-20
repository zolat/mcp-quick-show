import Cocoa
import UniformTypeIdentifiers

/// Menu-bar action handlers for user-initiated HUDs. Owns the
/// "Open URL…" prompt, the "Open File…" picker, and the
/// "New Sketch Pad" submenu; all three feed into
/// `SessionManager.userUpsert(...)`, which routes the content into
/// the reserved `userWindowsSessionID` session.
///
/// Lives as an `@MainActor` `NSObject` (rather than as static
/// extensions on AppDelegate) so the menu items can target it
/// directly via the standard NSMenuItem target/action plumbing — and
/// so a future "Paste URL" / drag-drop entry point has somewhere to
/// hang off without bloating AppDelegate further.
@MainActor
final class UserOpenActions: NSObject {
    weak var sessionManager: SessionManager?

    /// Maximum size for text-content files we read inline in Swift
    /// (markdown / svg / html). Matches the sidecar handlers' caps so a
    /// user-picked file behaves the same as a tool-call with the same
    /// content size. Image files are passed by path and the renderer
    /// reads them through `SizeCap` directly.
    private static let inlineFileCapBytes = 10 * 1024 * 1024  // 10 MB

    /// Sketch-pad dimension bounds — match the `show_html` `width`
    /// cap (`sidecar/src/handlers/html.ts`) so a user-spawned canvas
    /// can never demand more pixel real-estate than an agent could.
    private static let sketchPadMinDim = 100
    private static let sketchPadMaxDim = 4096

    /// Open a URL the user types into a modal prompt. Validates http(s);
    /// rejects javascript:, data:, file: at the same layer the sidecar's
    /// `show_url` does so menu + tool path have a single contract.
    @objc func openURL(_ sender: Any?) {
        guard let manager = sessionManager else { return }
        let alert = NSAlert()
        alert.messageText = "Open URL"
        alert.informativeText = "Loads a live page in a HUD panel."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        // Generic shape hint rather than a concrete URL — a literal
        // "https://example.com" placeholder reads as if it were
        // entered text and confuses people about whether they need to
        // clear it before typing their own URL.
        field.placeholderString = "https:// or http:// URL"
        alert.accessoryView = field
        // Focus the field after the alert is on-screen so the user can
        // paste/type immediately.
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(field)
        }
        let resp = alert.runModal()
        guard resp == .alertFirstButtonReturn else { return }
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        guard let url = validatedHTTPURL(raw) else {
            presentError(
                "Invalid URL",
                "Enter a complete http:// or https:// URL. (Got: \(raw))"
            )
            return
        }
        let panelName = "user-url-\(ShareID.mint())"
        Task { @MainActor in
            do {
                // No `displayName` for URL panels — the full URL is
                // usually too long for the description banner. The
                // panel name + the loaded page chrome are enough.
                _ = try await manager.userUpsert(
                    name: panelName,
                    contentType: "url",
                    form: "url",
                    body: url.absoluteString,
                    displayName: nil
                )
            } catch {
                presentError("Couldn't open URL", String(describing: error))
            }
        }
    }

    /// Run NSOpenPanel filtered to supported file types, auto-route by
    /// extension, and feed the result into `userUpsert`. Unsupported
    /// extensions trip an NSAlert.
    @objc func openFile(_ sender: Any?) {
        guard let manager = sessionManager else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Pick an image, markdown, SVG, or HTML file"
        panel.prompt = "Open"
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = supportedContentTypes
        } else {
            panel.allowedFileTypes = Array(Self.supportedExtensions)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ext = url.pathExtension.lowercased()
        let displayName = url.lastPathComponent
        let panelName = "user-file-\(ShareID.mint())"

        switch routedContentType(for: ext) {
        case .image:
            Task { @MainActor in
                do {
                    _ = try await manager.userUpsert(
                        name: panelName,
                        contentType: "image",
                        form: "path",
                        body: url.path,
                        displayName: displayName
                    )
                } catch {
                    presentError("Couldn't open image", String(describing: error))
                }
            }

        case .markdown, .svg, .html:
            let contentType = routedContentType(for: ext)!
            do {
                let body = try readInlineText(at: url)
                Task { @MainActor in
                    do {
                        _ = try await manager.userUpsert(
                            name: panelName,
                            contentType: contentType.wireValue,
                            form: "inline",
                            body: body,
                            displayName: displayName
                        )
                    } catch {
                        self.presentError(
                            "Couldn't render \(contentType.wireValue)",
                            String(describing: error)
                        )
                    }
                }
            } catch let err as FileReadError {
                presentError("Couldn't read file", err.message)
            } catch {
                presentError("Couldn't read file", String(describing: error))
            }

        case .none:
            presentError(
                "Unsupported file type",
                "QuickShow can't open .\(ext) files. Try .png, .jpg, .gif, .webp, .md, .svg, or .html."
            )
        }
    }

    // MARK: - Screen capture

    /// Invoke macOS's native interactive screenshot UI
    /// (`/usr/sbin/screencapture -i -U -x <tmp>`) and route the
    /// captured PNG into a markup-enabled HUD via the same
    /// `userUpsert(contentType: "image", form: "path", …)` path
    /// `openFile` uses for picked images. Cancellation (Esc / non-zero
    /// exit / missing or empty output) is a silent no-op — same shape
    /// as dismissing NSOpenPanel.
    @objc func captureScreen(_ sender: Any?) {
        guard let manager = sessionManager else { return }
        let tmpPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("QuickShow-capture-\(ShareID.mint()).png")

        let proc = Process()
        proc.launchPath = "/usr/sbin/screencapture"
        // -i  interactive selection (Esc cancels, spacebar → window mode)
        // -U  show the ⌘⇧5-style floating toolbar
        // -x  silence the shutter sound
        proc.arguments = ["-i", "-U", "-x", tmpPath]
        proc.terminationHandler = { [weak self] terminated in
            let status = terminated.terminationStatus
            DispatchQueue.main.async {
                self?.handleCaptureResult(
                    status: status,
                    outputPath: tmpPath,
                    manager: manager
                )
            }
        }
        do {
            try proc.run()
        } catch {
            presentError("Couldn't start screen capture",
                         String(describing: error))
        }
    }

    /// Main-actor finaliser for `captureScreen`. Treats every failure
    /// mode (cancel, missing file, zero bytes) as a silent no-op and
    /// removes any zero-byte residue screencapture might have left.
    @MainActor
    private func handleCaptureResult(status: Int32,
                                     outputPath: String,
                                     manager: SessionManager) {
        let fm = FileManager.default
        let attrs = (try? fm.attributesOfItem(atPath: outputPath)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard status == 0,
              fm.fileExists(atPath: outputPath),
              size > 0 else {
            if fm.fileExists(atPath: outputPath) {
                try? fm.removeItem(atPath: outputPath)
            }
            return
        }

        let panelName = "user-capture-\(ShareID.mint())"
        Task { @MainActor in
            do {
                _ = try await manager.userUpsert(
                    name: panelName,
                    contentType: "image",
                    form: "path",
                    body: outputPath,
                    displayName: nil,
                    autoEnterDrawMode: true
                )
            } catch {
                self.presentError("Couldn't open capture",
                                  String(describing: error))
            }
        }
    }

    // MARK: - Routing

    private enum RoutedType: String {
        case image
        case markdown
        case svg
        case html

        var wireValue: String {
            switch self {
            case .image:    return "image"
            case .markdown: return "markdown"
            case .svg:      return "svg"
            case .html:     return "html"
            }
        }
    }

    private func routedContentType(for ext: String) -> RoutedType? {
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp":
            return .image
        case "md", "markdown":
            return .markdown
        case "svg":
            return .svg
        case "html", "htm":
            return .html
        default:
            return nil
        }
    }

    private static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp",
        "md", "markdown",
        "svg",
        "html", "htm",
    ]

    @available(macOS 11.0, *)
    private var supportedContentTypes: [UTType] {
        var types: [UTType] = [
            .png, .jpeg, .gif,
        ]
        if let webp = UTType("org.webmproject.webp") { types.append(webp) }
        // Markdown gets a sibling UTI on macOS 12+; fall back to a
        // dynamic UTI built from the extension when the system doesn't
        // declare one (older releases).
        if let md = UTType("net.daringfireball.markdown") {
            types.append(md)
        } else if let md = UTType(filenameExtension: "md") {
            types.append(md)
        }
        types.append(.svg)
        types.append(.html)
        return types
    }

    // MARK: - File reading

    private struct FileReadError: Error {
        let message: String
    }

    private func readInlineText(at url: URL) throws -> String {
        let fm = FileManager.default
        let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if size > Self.inlineFileCapBytes {
            throw FileReadError(message:
                "File is \(size) bytes — bigger than the \(Self.inlineFileCapBytes / (1024 * 1024)) MB cap for inline rendering.")
        }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                throw FileReadError(message:
                    "File is not valid UTF-8. QuickShow only renders text-based content (markdown / svg / html) as UTF-8.")
            }
            return text
        } catch let err as FileReadError {
            throw err
        } catch {
            throw FileReadError(message: error.localizedDescription)
        }
    }

    // MARK: - URL validation

    private func validatedHTTPURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        guard scheme == "http" || scheme == "https" else {
            return nil
        }
        guard let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    // MARK: - Sketch Pad

    @objc func openSketchPadSquare(_ sender: Any?) {
        openSketchPad(width: 1024, height: 1024)
    }

    @objc func openSketchPadLandscape(_ sender: Any?) {
        openSketchPad(width: 1280, height: 720)
    }

    @objc func openSketchPadPortrait(_ sender: Any?) {
        openSketchPad(width: 768, height: 1024)
    }

    /// Custom-size sketch pad — modal with two number fields. Cmd+Return
    /// (or the default "Create" button) submits; out-of-range inputs
    /// trip an inline error and re-prompt.
    @objc func openSketchPadCustom(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "New Sketch Pad — Custom size"
        alert.informativeText = "Width and height in pixels (\(Self.sketchPadMinDim)–\(Self.sketchPadMaxDim))."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let widthLabel = NSTextField(labelWithString: "Width:")
        let widthField = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
        widthField.stringValue = "1024"
        let heightLabel = NSTextField(labelWithString: "Height:")
        let heightField = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
        heightField.stringValue = "768"

        row.addArrangedSubview(widthLabel)
        row.addArrangedSubview(widthField)
        row.addArrangedSubview(heightLabel)
        row.addArrangedSubview(heightField)
        row.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = row

        // Focus width so the user can immediately type / tab.
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(widthField)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let w = Int(widthField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let h = Int(heightField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            presentError("Invalid size",
                         "Enter whole numbers for width and height.")
            return
        }
        guard (Self.sketchPadMinDim...Self.sketchPadMaxDim).contains(w),
              (Self.sketchPadMinDim...Self.sketchPadMaxDim).contains(h) else {
            presentError("Out of range",
                         "Width and height must each be between \(Self.sketchPadMinDim) and \(Self.sketchPadMaxDim) pixels.")
            return
        }
        openSketchPad(width: w, height: h)
    }

    /// Shared helper: build a minimal blank HTML doc sized to the
    /// chosen dimensions and route it through `userUpsert` with
    /// `autoEnterDrawMode: true`. The body's width/height in CSS px
    /// plus the matching `width` hint on `userUpsert` gives the
    /// HTMLRenderer a viewport that matches the canvas, so the
    /// in-DOM markup canvas overlays cleanly at 1:1 resolution.
    private func openSketchPad(width: Int, height: Int) {
        guard let manager = sessionManager else { return }
        let panelName = "user-sketch-\(ShareID.mint())"
        let html = blankSketchHTML(width: width, height: height)
        Task { @MainActor in
            do {
                _ = try await manager.userUpsert(
                    name: panelName,
                    contentType: "html",
                    form: "inline",
                    body: html,
                    width: Double(width),
                    displayName: nil,
                    autoEnterDrawMode: true
                )
            } catch {
                self.presentError("Couldn't open Sketch Pad",
                                  String(describing: error))
            }
        }
    }

    /// Minimal full HTML document that paints a white rectangle at the
    /// requested pixel dimensions. The body's explicit width + height
    /// give the WebView a concrete document size; the markup canvas
    /// injected at `documentEnd` overlays the same rect at 1:1.
    private func blankSketchHTML(width: Int, height: Int) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            html, body { margin: 0; padding: 0; }
            body {
              width: \(width)px;
              height: \(height)px;
              background: #ffffff;
            }
          </style>
        </head>
        <body></body>
        </html>
        """
    }

    // MARK: - UI

    private func presentError(_ title: String, _ details: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = details
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }
}
