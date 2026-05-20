import Cocoa

/// Optional framing text rendered between a HUD's tab strip and its
/// content host. Two stacked lines:
///   - **group line** (italic, recessed) — HUD-level `hud_description`,
///     persistent across tab switches within a group.
///   - **panel line** (medium, prominent) — per-tab `description`,
///     swapped when the user (or the agent) switches the active tab.
///
/// When both strings are nil/empty the view auto-collapses to zero
/// height + `isHidden = true` so HUDs that don't use the feature look
/// identical to the pre-banner chrome.
///
/// Visibility is driven by **two** independent gates:
///   1. **content gate** — `setGroupDescription` / `setPanelDescription`
///      decide whether there's anything to show. Drives `isHidden`
///      and `intrinsicContentSize.height`.
///   2. **reveal gate** — `setRevealed(_:)` animates `alphaValue`
///      between 0.35 (resting) and 1.0 (cursor in content host).
///      Mirrors `TabStripView`'s auto-fade idiom so the banner
///      doesn't permanently obscure the top of the rendered content.
@MainActor
final class DescriptionBanner: NSView {
    /// Resting alpha when the cursor isn't hovering the HUD content
    /// host. Matches `TabStripView`'s idle alpha for visual continuity.
    static let idleAlpha: CGFloat = 0.35
    /// Vertical padding around the label stack — trimmed from the
    /// first draft to keep the banner from dominating the top of the
    /// content host.
    private static let vPadding: CGFloat = 3
    /// Horizontal padding either side. Matches `TitleBarOverlay`'s
    /// 10pt outer inset + ~2pt internal so banner text lines up
    /// vertically with the title.
    private static let hPadding: CGFloat = 12
    /// Spacing between group + panel lines when both shown.
    private static let interLineSpacing: CGFloat = 1

    private let groupLabel = NSTextField(wrappingLabelWithString: "")
    private let panelLabel = NSTextField(wrappingLabelWithString: "")
    private var groupString: String = ""
    private var panelString: String = ""

    /// Track whether the cursor is in the host content area (set by
    /// `HUDWindow` via `setRevealed`). Independent of `isHidden`.
    private var revealed: Bool = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // Warm dark Arthur surface — matches the title bar so the
        // chrome stack reads as one continuous layer.
        layer?.backgroundColor = ArthurPalette.elevated.cgColor
        // Round only the bottom corners. The banner butts against the
        // tab strip (or title bar when no tabs) above, so its top edge
        // wants to be flush; the bottom edge floats over content, where
        // a soft corner sells the "chrome layer" feel.
        layer?.cornerRadius = 6
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        // Start at the resting alpha — the cursor isn't in the
        // content host until the user moves it there.
        alphaValue = Self.idleAlpha

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
        // Group line: italic 10pt — reads as the "framing context" of
        // the HUD. Slight kerning gives it an editorial feel that pairs
        // with the title bar's medium-weight panel name.
        let italicDescriptor = NSFont.systemFont(ofSize: 10, weight: .regular)
            .fontDescriptor.withSymbolicTraits(.italic)
        let italicFont = NSFont(descriptor: italicDescriptor, size: 10)
            ?? NSFont.systemFont(ofSize: 10, weight: .regular)
        groupLabel.font = italicFont
        groupLabel.textColor = ArthurPalette.textMuted.withAlphaComponent(0.65)

        // Panel line: 11pt medium — same weight + size as the title
        // bar's panel name (`TitleBarOverlay.titleLabel`), so the banner
        // reads as an extension of the title bar.
        panelLabel.font = .systemFont(ofSize: 11, weight: .medium)
        panelLabel.textColor = ArthurPalette.textMuted

        applyConstraints()
        refreshVisibility()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// HUDs let their title bar drive the window
    /// (`isMovableByWindowBackground`). The banner sits underneath the
    /// tab strip; opting it into background-drag too lets the user grab
    /// the banner area to move the window.
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

    /// Animate the banner up to full alpha (`true`) or back to the
    /// resting alpha (`false`). Durations mirror `TabStripView`:
    /// 0.15s on reveal, 0.25s on hide — subtle enough that quick
    /// cursor passes don't strobe, sluggish enough that the fade
    /// reads as intentional.
    func setRevealed(_ on: Bool) {
        guard revealed != on else { return }
        revealed = on
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = on ? 0.15 : 0.25
            self.animator().alphaValue = on ? 1.0 : Self.idleAlpha
        }
    }

    /// Both nil/empty → collapsed; otherwise expanded with whichever
    /// line(s) have text. Auto-hides individual labels that aren't
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
        return NSSize(width: NSView.noIntrinsicMetric, height: max(h, 20))
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
