import Cocoa

/// Optional framing text rendered between a HUD's tab strip and its
/// content host. Two stacked lines:
///   - **group line** (smaller, muted) — HUD-level `hud_description`,
///     persistent across tab switches within a group.
///   - **panel line** (prominent)      — per-tab `description`, swapped
///     when the user (or the agent) switches the active tab.
///
/// When both strings are nil/empty the view auto-collapses to zero
/// height + `isHidden = true` so HUDs that don't use the feature look
/// identical to the v0.1 chrome. `intrinsicContentSize.height` reports
/// what the view needs given the current strings — `HUDWindow` reads
/// it into its `sizeToContent` chrome math.
@MainActor
final class DescriptionBanner: NSView {
    /// Vertical padding around each line.
    private static let vPadding: CGFloat = 4
    /// Horizontal padding either side.
    private static let hPadding: CGFloat = 10
    /// Spacing between group + panel lines when both shown.
    private static let interLineSpacing: CGFloat = 2

    private let groupLabel = NSTextField(wrappingLabelWithString: "")
    private let panelLabel = NSTextField(wrappingLabelWithString: "")
    private var groupString: String = ""
    private var panelString: String = ""

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // Solid backdrop so banner text reads cleanly over the
        // contentHost (the banner overlays the top of the content,
        // mirroring how the tab strip floats above the renderer).
        layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(0.95).cgColor

        for label in [groupLabel, panelLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isSelectable = true
            label.isEditable = false
            label.drawsBackground = false
            label.isBordered = false
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 3
            label.cell?.usesSingleLineMode = false
            addSubview(label)
        }
        groupLabel.font = .systemFont(ofSize: 10, weight: .medium)
        groupLabel.textColor = .secondaryLabelColor
        panelLabel.font = .systemFont(ofSize: 12, weight: .regular)
        panelLabel.textColor = .labelColor

        applyConstraints()
        refreshVisibility()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// HUDs let their title bar drive the window (`isMovableByWindowBackground`).
    /// The banner sits underneath the tab strip; opting it into background-
    /// drag too lets the user grab the banner area to move the window.
    override var mouseDownCanMoveWindow: Bool { true }

    private func applyConstraints() {
        NSLayoutConstraint.activate([
            groupLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.hPadding),
            groupLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.hPadding),
            groupLabel.topAnchor.constraint(equalTo: topAnchor, constant: Self.vPadding),

            panelLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.hPadding),
            panelLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.hPadding),
            panelLabel.topAnchor.constraint(equalTo: groupLabel.bottomAnchor, constant: Self.interLineSpacing),
            panelLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.vPadding),
        ])
    }

    /// Update the HUD-level (group) framing string. Empty string clears.
    func setGroupDescription(_ s: String) {
        groupString = s
        groupLabel.stringValue = s
        refreshVisibility()
    }

    /// Update the per-tab framing string. Empty string clears.
    func setPanelDescription(_ s: String) {
        panelString = s
        panelLabel.stringValue = s
        refreshVisibility()
    }

    /// Both nil/empty → collapsed; otherwise expanded with whichever
    /// line(s) have text. Auto-hides individual labels they aren't
    /// holding text so unused real estate doesn't reserve space.
    private func refreshVisibility() {
        let hasGroup = !groupString.isEmpty
        let hasPanel = !panelString.isEmpty
        groupLabel.isHidden = !hasGroup
        panelLabel.isHidden = !hasPanel
        isHidden = !(hasGroup || hasPanel)
        invalidateIntrinsicContentSize()
    }

    /// Height the banner needs given current strings + width. Computed
    /// from each visible label's wrapping height. `HUDWindow.sizeToContent`
    /// reads this when deciding the chrome additive.
    override var intrinsicContentSize: NSSize {
        if isHidden {
            return NSSize(width: NSView.noIntrinsicMetric, height: 0)
        }
        let contentWidth = bounds.width > 0
            ? bounds.width - (Self.hPadding * 2)
            : 0
        var h: CGFloat = Self.vPadding * 2
        var anyShown = false
        if !groupString.isEmpty {
            h += heightFor(text: groupString, font: groupLabel.font, width: contentWidth)
            anyShown = true
        }
        if !panelString.isEmpty {
            if anyShown { h += Self.interLineSpacing }
            h += heightFor(text: panelString, font: panelLabel.font, width: contentWidth)
            anyShown = true
        }
        // Defensive floor — a 1-line label at this size is ~14pt; the
        // value below catches the unusual "first layout, bounds == .zero"
        // case so we never report zero height while *holding* content.
        return NSSize(width: NSView.noIntrinsicMetric, height: max(h, 22))
    }

    private func heightFor(text: String, font: NSFont?, width: CGFloat) -> CGFloat {
        guard width > 0, let font = font else { return 16 }
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let bounding = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        return ceil(bounding.height)
    }

    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()
    }
}
