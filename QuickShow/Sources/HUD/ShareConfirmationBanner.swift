import Cocoa

/// Transient chrome row that appears under the HUD's title bar after a
/// user-windows Send. Hosts the share token + a Copy action + a dismiss
/// button, then auto-fades after ~6 s. Mirrors `DescriptionBanner`'s
/// visual identity (warm elevated bg, bottom-corner rounding, alpha
/// animation) so the chrome stack reads as one continuous layer.
///
/// Public surface (called by `HUDWindow`):
///   - `show(token:)` — show the strip with the supplied token, restart
///     the auto-dismiss timer.
///   - `dismiss()` — fade out immediately.
///
/// Self-contained: the banner owns its timer + clipboard write; the
/// host doesn't need to wire any callbacks.
@MainActor
final class ShareConfirmationBanner: NSView {
    /// Fixed strip height — matches the title bar (28pt) so the chrome
    /// stack reads as a continuous band when the banner is visible.
    private static let bannerHeight: CGFloat = 28
    /// Horizontal padding mirrors `DescriptionBanner.hPadding` (12pt)
    /// so the ✓ icon sits at the same x as the description banner's
    /// first character.
    private static let hPadding: CGFloat = 12
    /// Seconds before the banner auto-dismisses if the user does
    /// nothing.
    private static let autoDismissAfter: TimeInterval = 6.0

    private let checkIcon = NSButton(title: "", target: nil, action: nil)
    private let copiedLabel = NSTextField(labelWithString: "Copied")
    /// Drag-selectable token field — the whole reason this banner
    /// exists is so the user can verify or partial-copy the token,
    /// which the old `NSAlert` couldn't permit.
    private let tokenField = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let dismissButton = NSButton(title: "", target: nil, action: nil)

    /// In-flight auto-dismiss work item. Cancelled on manual ✕ or on a
    /// follow-on `show(token:)` (second Send before the first faded).
    private var autoDismissWork: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = ArthurPalette.elevated.cgColor
        // Mirror DescriptionBanner: round only the bottom corners so
        // the banner butts cleanly against the title bar above.
        layer?.cornerRadius = 6
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        // Start hidden + zero-alpha so the chrome stack collapses to
        // nothing until the first show.
        isHidden = true
        alphaValue = 0

        configureCheckIcon()
        configureCopiedLabel()
        configureTokenField()
        configureCopyButton()
        configureDismissButton()

        let stack = NSStackView(views: [
            checkIcon, copiedLabel, tokenField, copyButton, dismissButton,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.detachesHiddenViews = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(6, after: checkIcon)
        stack.setCustomSpacing(10, after: tokenField)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.hPadding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),

            checkIcon.widthAnchor.constraint(equalToConstant: 22),
            checkIcon.heightAnchor.constraint(equalToConstant: 22),
            copyButton.widthAnchor.constraint(equalToConstant: 60),
            copyButton.heightAnchor.constraint(equalToConstant: 22),
            dismissButton.widthAnchor.constraint(equalToConstant: 22),
            dismissButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Let the user drag the window by grabbing the banner background,
    /// the same way `DescriptionBanner` does.
    override var mouseDownCanMoveWindow: Bool { true }

    /// Banner is sized by `intrinsicContentSize` — fixed height when
    /// shown, zero when hidden, so the chrome stack collapses cleanly.
    override var intrinsicContentSize: NSSize {
        if isHidden {
            return NSSize(width: NSView.noIntrinsicMetric, height: 0)
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: Self.bannerHeight)
    }

    // MARK: - Public surface

    /// Show the banner with the supplied share token. Restarts the
    /// auto-dismiss timer; a rapid second show replaces the token +
    /// timer in place (no stacking).
    func show(token: String) {
        autoDismissWork?.cancel()
        tokenField.stringValue = token
        // Reset the Copy label in case a previous show left it flashed.
        setCopyButtonTitle("Copy")

        isHidden = false
        invalidateIntrinsicContentSize()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            self.animator().alphaValue = 1.0
        }

        let work = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        autoDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoDismissAfter, execute: work)
    }

    /// Fade out and hide. Safe to call from the ✕ button or from the
    /// timer's own fire path (cancel is a no-op once the work item has
    /// run).
    func dismiss() {
        autoDismissWork?.cancel()
        autoDismissWork = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.isHidden = true
            self.invalidateIntrinsicContentSize()
        })
    }

    // MARK: - Construction helpers

    private func configureCheckIcon() {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        checkIcon.image = NSImage(
            systemSymbolName: "checkmark.seal.fill",
            accessibilityDescription: "Share copied"
        )?.withSymbolConfiguration(cfg)
        checkIcon.isBordered = false
        checkIcon.imagePosition = .imageOnly
        // `.systemGreen` is the standard "positive confirmation" tint
        // across mac chrome (Safari share sheet, system Copy toasts).
        // If it clashes with the new olive accent we'll revisit.
        checkIcon.contentTintColor = .systemGreen
        checkIcon.isEnabled = false   // pure indicator
        checkIcon.toolTip = "Share link copied to clipboard"
    }

    private func configureCopiedLabel() {
        copiedLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        copiedLabel.textColor = ArthurPalette.textMuted
        copiedLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureTokenField() {
        tokenField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tokenField.textColor = ArthurPalette.textMuted
        tokenField.isSelectable = true
        tokenField.isEditable = false
        tokenField.isBordered = false
        tokenField.drawsBackground = false
        tokenField.lineBreakMode = .byTruncatingTail
        tokenField.cell?.usesSingleLineMode = true
        tokenField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tokenField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configureCopyButton() {
        copyButton.wantsLayer = true
        copyButton.isBordered = false
        copyButton.layer?.backgroundColor = ArthurPalette.accent.cgColor
        copyButton.layer?.cornerRadius = 11
        setCopyButtonTitle("Copy")
        copyButton.target = self
        copyButton.action = #selector(handleCopy)
        copyButton.toolTip = "Copy the share token to the clipboard"
    }

    private func configureDismissButton() {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        dismissButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Dismiss share confirmation"
        )?.withSymbolConfiguration(cfg)
        dismissButton.isBordered = false
        dismissButton.imagePosition = .imageOnly
        dismissButton.contentTintColor = ArthurPalette.textMuted
        dismissButton.target = self
        dismissButton.action = #selector(handleDismiss)
    }

    private func setCopyButtonTitle(_ title: String) {
        copyButton.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
        )
    }

    // MARK: - Actions

    @objc private func handleCopy() {
        let token = tokenField.stringValue
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        setCopyButtonTitle("Copied ✓")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            // Don't clobber a later state — only revert if the label is
            // still showing the flash text (and the banner hasn't been
            // dismissed in the meantime).
            if !self.isHidden,
               self.copyButton.attributedTitle.string == "Copied ✓" {
                self.setCopyButtonTitle("Copy")
            }
        }
    }

    @objc private func handleDismiss() {
        dismiss()
    }
}
