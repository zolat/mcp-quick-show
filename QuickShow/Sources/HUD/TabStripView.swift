import Cocoa

/// Tab strip displayed at the top of a HUD when it hosts ≥2 panels.
/// One `TabPillView` per panel; clicking a pill switches the active
/// panel; the × on each pill closes that tab.
///
/// Auto-reveal on hover (PRD user story #26): strip starts at 35%
/// opacity and animates to 100% when the cursor enters its tracking
/// area. Returns to 35% on exit. Single-panel sessions hide the strip
/// entirely.
final class TabStripView: NSView {
    static let height: CGFloat = 26

    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?

    private let stack = NSStackView()
    private var pills: [TabPillView] = []
    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(0.6).cgColor
        layer?.cornerRadius = 4

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        alphaValue = 0.35
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Background of the strip is grabbable for window drag.
    override var mouseDownCanMoveWindow: Bool { true }

    func update(panels: [(name: String, isActive: Bool)]) {
        isHidden = panels.count < 2
        // Reuse / create pills.
        while pills.count < panels.count {
            let pill = TabPillView()
            pill.onClick = { [weak self] name in self?.onSelect?(name) }
            pill.onClose = { [weak self] name in self?.onClose?(name) }
            pills.append(pill)
            stack.addArrangedSubview(pill)
        }
        while pills.count > panels.count {
            let last = pills.removeLast()
            last.removeFromSuperview()
        }
        for (i, info) in panels.enumerated() {
            pills[i].configure(name: info.name, isActive: info.isActive)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.animator().alphaValue = 1.0
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            self.animator().alphaValue = 0.35
        }
    }
}

/// One pill in the tab strip. Shows the panel name + a close button.
/// Active state changes the background.
final class TabPillView: NSView {
    var onClick: ((String) -> Void)?
    var onClose: ((String) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    private var panelName: String = ""

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 3

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 11, weight: .medium)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(handleClose)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),
            heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Clicks on the pill body switch tabs, but a tab pill should
    /// NOT drag the window — overrides PipAnything's tab-pill trap.
    override var mouseDownCanMoveWindow: Bool { false }

    func configure(name: String, isActive: Bool) {
        panelName = name
        label.stringValue = name
        if isActive {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
            label.textColor = .labelColor
        } else {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.4).cgColor
            label.textColor = .secondaryLabelColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(panelName)
    }

    @objc private func handleClose() {
        onClose?(panelName)
    }
}
