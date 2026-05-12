import Cocoa
import ServiceManagement

/// Minimal preferences window. Per PRD § "SettingsWindow":
/// - Launch at login toggle (ServiceManagement.SMAppService).
/// - Default opacity for newly-spawned HUDs.
/// - Initial size cap width/height inputs.
/// - "Connect to Claude Code" button (writes ~/.claude.json).
/// - Copyable MCP config snippet for other clients.
///
/// Values are persisted via `Settings.shared` (UserDefaults). They
/// apply to *new* HUDs — live ones retain their captured-at-creation
/// state, matching PipAnything's "defaults, not global toggles" rule.
@MainActor
final class SettingsWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch QuickShow at login", target: nil, action: nil)
    private let opacitySlider = NSSlider(value: 100, minValue: 10, maxValue: 100, target: nil, action: nil)
    private let opacityValueLabel = NSTextField(labelWithString: "100 %")
    private let sizeWidthField = NSTextField()
    private let sizeHeightField = NSTextField()
    private let connectButton = NSButton(title: "Connect to Claude Code", target: nil, action: nil)
    private let configTextView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
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

        // --- Default opacity slider ---
        let opacityRow = NSStackView()
        opacityRow.orientation = .horizontal
        opacityRow.spacing = 10
        opacityRow.alignment = .centerY
        let opacityLabel = NSTextField(labelWithString: "Default HUD opacity:")
        opacityLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged(_:))
        opacitySlider.doubleValue = Double(Settings.shared.defaultOpacityPercent)
        opacitySlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        opacityValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        opacityValueLabel.stringValue = "\(Settings.shared.defaultOpacityPercent) %"
        opacityValueLabel.widthAnchor.constraint(equalToConstant: 50).isActive = true
        opacityRow.addArrangedSubview(opacityLabel)
        opacityRow.addArrangedSubview(opacitySlider)
        opacityRow.addArrangedSubview(opacityValueLabel)
        stack.addArrangedSubview(opacityRow)

        let opacityNote = NSTextField(labelWithString: "Applies to newly-spawned HUDs.")
        opacityNote.font = .systemFont(ofSize: 10)
        opacityNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(opacityNote)

        stack.addArrangedSubview(separator())

        // --- Initial size cap ---
        let sizeRow = NSStackView()
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 10
        sizeRow.alignment = .centerY
        let sizeLabel = NSTextField(labelWithString: "Initial size cap:")
        sizeLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        sizeWidthField.stringValue = "\(Settings.shared.initialSizeCapWidth)"
        sizeWidthField.alignment = .right
        sizeWidthField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        sizeWidthField.delegate = self
        let sizeMul = NSTextField(labelWithString: "×")
        sizeHeightField.stringValue = "\(Settings.shared.initialSizeCapHeight)"
        sizeHeightField.alignment = .right
        sizeHeightField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        sizeHeightField.delegate = self
        let sizeUnit = NSTextField(labelWithString: "pt")
        sizeRow.addArrangedSubview(sizeLabel)
        sizeRow.addArrangedSubview(sizeWidthField)
        sizeRow.addArrangedSubview(sizeMul)
        sizeRow.addArrangedSubview(sizeHeightField)
        sizeRow.addArrangedSubview(sizeUnit)
        stack.addArrangedSubview(sizeRow)

        let sizeNote = NSTextField(labelWithString: "Upper bound for content-aware HUD sizing.")
        sizeNote.font = .systemFont(ofSize: 10)
        sizeNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(sizeNote)

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
        scroll.widthAnchor.constraint(equalToConstant: 480).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
        stack.addArrangedSubview(scroll)

        let copyButton = NSButton(title: "Copy snippet", target: self, action: #selector(copyConfig(_:)))
        copyButton.bezelStyle = .rounded
        stack.addArrangedSubview(copyButton)
    }

    private func separator() -> NSBox {
        let s = NSBox()
        s.boxType = .separator
        s.translatesAutoresizingMaskIntoConstraints = false
        s.widthAnchor.constraint(equalToConstant: 480).isActive = true
        return s
    }

    // MARK: - Opacity

    @objc private func opacityChanged(_ sender: NSSlider) {
        let pct = Int(sender.doubleValue.rounded())
        Settings.shared.defaultOpacityPercent = pct
        opacityValueLabel.stringValue = "\(pct) %"
    }

    // MARK: - Size cap (NSTextFieldDelegate)

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === sizeWidthField {
            let v = Int(field.stringValue) ?? Settings.shared.initialSizeCapWidth
            Settings.shared.initialSizeCapWidth = v
            field.stringValue = "\(Settings.shared.initialSizeCapWidth)" // reflect clamping
        } else if field === sizeHeightField {
            let v = Int(field.stringValue) ?? Settings.shared.initialSizeCapHeight
            Settings.shared.initialSizeCapHeight = v
            field.stringValue = "\(Settings.shared.initialSizeCapHeight)"
        }
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
        let bundleURL = Bundle.main.bundleURL
        let bundled = bundleURL
            .appendingPathComponent("Contents/Resources/mcp-quick-show")
            .path
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return (bundled, [])
        }
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
