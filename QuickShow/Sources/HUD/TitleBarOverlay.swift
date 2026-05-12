import Cocoa

/// Slim title bar that floats over the top of the HUD content. Shows
/// the panel name and an × close button. Auto-hides when the cursor
/// leaves the HUD (Phase 1 default: always-visible; auto-hide lands
/// with the tab strip in Phase 3).
///
/// Click on the bar background drags the window (forwards via
/// `mouseDownCanMoveWindow = true`); the close button consumes its
/// own click via `mouseDownCanMoveWindow = false`.
final class TitleBarOverlay: NSView {
    static let height: CGFloat = 22

    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    private let badgeView = NSTextField(labelWithString: "")
    private let backgroundLayer = CALayer()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Self.height))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(0.85).cgColor
        layer?.cornerRadius = 6

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.font = .systemFont(ofSize: 10, weight: .medium)
        badgeView.textColor = .systemRed
        badgeView.isHidden = true
        addSubview(badgeView)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 14, weight: .medium)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(handleClose)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeView.leadingAnchor, constant: -6),
            badgeView.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            badgeView.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    /// Show or hide the "session ended" badge. When shown, the HUD is
    /// orphaned: the sidecar has disconnected and didn't reconnect
    /// within the grace window.
    func setSessionEnded(_ ended: Bool) {
        badgeView.isHidden = !ended
        badgeView.stringValue = ended ? "● session ended" : ""
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Background of the title bar drags the window.
    override var mouseDownCanMoveWindow: Bool { true }

    func setTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    @objc private func handleClose() {
        onClose?()
    }
}
