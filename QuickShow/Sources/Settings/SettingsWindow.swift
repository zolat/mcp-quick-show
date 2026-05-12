import Cocoa
import ServiceManagement

/// Minimal preferences window. Per PRD § "SettingsWindow":
/// - Launch at login toggle (ServiceManagement.SMAppService).
/// - Default opacity for newly-spawned HUDs.
/// - Initial size cap inputs.
/// - "Connect to Claude Code" button (writes ~/.claude.json).
/// - Copyable MCP config snippet for other clients.
@MainActor
final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch QuickShow at login", target: nil, action: nil)
    private let opacityField = NSTextField()
    private let connectButton = NSButton(title: "Connect to Claude Code", target: nil, action: nil)
    private let configTextView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "QuickShow Preferences"
        super.init(window: window)
        window.delegate = self
        configureUI()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func configureUI() {
        guard let content = window?.contentView else { return }

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        // --- Launch at login ---
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(toggleLaunchAtLogin(_:))
        launchAtLoginCheckbox.state = isLaunchAtLoginEnabled() ? .on : .off
        stack.addArrangedSubview(launchAtLoginCheckbox)

        stack.addArrangedSubview(separator())

        // --- Default opacity ---
        let opacityRow = NSStackView()
        opacityRow.orientation = .horizontal
        opacityRow.spacing = 8
        let opacityLabel = NSTextField(labelWithString: "Default HUD opacity:")
        opacityField.stringValue = "100"
        opacityField.alignment = .right
        opacityField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let pctLabel = NSTextField(labelWithString: "%")
        opacityRow.addArrangedSubview(opacityLabel)
        opacityRow.addArrangedSubview(opacityField)
        opacityRow.addArrangedSubview(pctLabel)
        stack.addArrangedSubview(opacityRow)

        stack.addArrangedSubview(separator())

        // --- Connect to Claude Code ---
        let connectRow = NSStackView()
        connectRow.orientation = .horizontal
        connectRow.spacing = 12
        connectButton.target = self
        connectButton.action = #selector(connectToClaudeCode(_:))
        connectButton.bezelStyle = .rounded
        connectRow.addArrangedSubview(connectButton)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        connectRow.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(connectRow)

        // --- MCP config snippet (copyable) ---
        let snippetLabel = NSTextField(labelWithString: "MCP server config for other clients:")
        snippetLabel.font = .systemFont(ofSize: 11, weight: .medium)
        stack.addArrangedSubview(snippetLabel)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        configTextView.isEditable = false
        configTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        configTextView.string = mcpConfigSnippet()
        configTextView.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = configTextView
        scroll.widthAnchor.constraint(equalToConstant: 460).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
        stack.addArrangedSubview(scroll)

        // Copy button
        let copyButton = NSButton(title: "Copy snippet", target: self, action: #selector(copyConfig(_:)))
        copyButton.bezelStyle = .rounded
        stack.addArrangedSubview(copyButton)
    }

    private func separator() -> NSBox {
        let s = NSBox()
        s.boxType = .separator
        s.translatesAutoresizingMaskIntoConstraints = false
        s.widthAnchor.constraint(equalToConstant: 460).isActive = true
        return s
    }

    // MARK: - Launch at login

    private func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("QuickShow: launch-at-login toggle failed: \(error)")
            // Roll back the checkbox so the UI reflects reality.
            sender.state = isLaunchAtLoginEnabled() ? .on : .off
            statusLabel.stringValue = "Failed to update: \(error.localizedDescription)"
        }
    }

    // MARK: - Connect to Claude Code

    @objc private func connectToClaudeCode(_ sender: NSButton) {
        let configPath = (NSString(string: "~/.claude.json").expandingTildeInPath as NSString)
        let url = URL(fileURLWithPath: configPath as String)
        do {
            var json: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: configPath as String) {
                let data = try Data(contentsOf: url)
                json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }
            var mcpServers = (json["mcpServers"] as? [String: Any]) ?? [:]
            mcpServers["quick-show"] = mcpServerEntry()
            json["mcpServers"] = mcpServers
            let updated = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try updated.write(to: url, options: .atomic)
            statusLabel.stringValue = "✓ Added 'quick-show' to ~/.claude.json — restart Claude Code"
            statusLabel.textColor = .systemGreen
        } catch {
            NSLog("QuickShow: failed to write ~/.claude.json: \(error)")
            statusLabel.stringValue = "✗ Could not update ~/.claude.json: \(error.localizedDescription)"
            statusLabel.textColor = .systemRed
        }
    }

    @objc private func copyConfig(_ sender: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(configTextView.string, forType: .string)
        statusLabel.stringValue = "✓ Copied"
        statusLabel.textColor = .secondaryLabelColor
    }

    // MARK: - Config helpers

    private func sidecarCommand() -> (cmd: String, args: [String]) {
        // Bundled-sidecar path (Release builds). Falls back to a
        // generic `bun run …/index.ts` invocation when running the
        // app from a Debug build that hasn't bundled the binary yet.
        let bundleURL = Bundle.main.bundleURL
        let bundled = bundleURL
            .appendingPathComponent("Contents/Resources/mcp-quick-show")
            .path
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return (bundled, [])
        }
        // Debug fallback: assume sidecar source is sibling to the
        // app's source tree.
        let sourcePath = bundleURL.deletingLastPathComponent()
            .appendingPathComponent("../sidecar/src/index.ts").path
        return ("bun", ["run", sourcePath])
    }

    private func mcpServerEntry() -> [String: Any] {
        let (cmd, args) = sidecarCommand()
        return ["command": cmd, "args": args]
    }

    private func mcpConfigSnippet() -> String {
        let entry: [String: Any] = ["mcpServers": ["quick-show": mcpServerEntry()]]
        if let data = try? JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }
}
