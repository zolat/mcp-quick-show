import Cocoa

/// Builds the right-click context menus for HUDs and tab pills.
/// Per PRD § "Right-click menu surface (v0.1)":
///   - Per-tab (right-click on a pill): Close tab, Promote to standard
///     window, Re-snapshot (saves a fresh PNG to ~/Downloads).
///   - Per-HUD (right-click on background): Close all tabs, Opacity
///     submenu (25 / 50 / 75 / 100 %).
///
/// Per-HUD actions thread `hudId` so they target the right sibling
/// when a session has multiple HUDs (post-tear-out).
@MainActor
enum HUDContextMenu {
    static func tabMenu(sessionId: String,
                        name: String,
                        target: AnyObject?,
                        close: Selector,
                        promote: Selector,
                        snapshotToDownloads: Selector) -> NSMenu {
        let menu = NSMenu()

        let closeItem = NSMenuItem(title: "Close tab “\(name)”", action: close, keyEquivalent: "")
        closeItem.target = target
        closeItem.representedObject = MenuPayload(sessionId: sessionId, name: name)
        menu.addItem(closeItem)

        let promoteItem = NSMenuItem(title: "Promote to standard window", action: promote, keyEquivalent: "")
        promoteItem.target = target
        promoteItem.representedObject = MenuPayload(sessionId: sessionId, name: name)
        menu.addItem(promoteItem)

        menu.addItem(.separator())

        let snapshotItem = NSMenuItem(title: "Re-snapshot to ~/Downloads", action: snapshotToDownloads, keyEquivalent: "")
        snapshotItem.target = target
        snapshotItem.representedObject = MenuPayload(sessionId: sessionId, name: name)
        menu.addItem(snapshotItem)

        return menu
    }

    static func hudMenu(sessionId: String,
                        hudId: UUID,
                        target: AnyObject?,
                        closeAll: Selector,
                        opacity: Selector) -> NSMenu {
        let menu = NSMenu()

        let closeAllItem = NSMenuItem(title: "Close all tabs in this HUD", action: closeAll, keyEquivalent: "")
        closeAllItem.target = target
        closeAllItem.representedObject = HudPayload(sessionId: sessionId, hudId: hudId)
        menu.addItem(closeAllItem)

        menu.addItem(.separator())

        let opacityHeader = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let opacitySubmenu = NSMenu()
        for pct in [25, 50, 75, 100] {
            let item = NSMenuItem(title: "\(pct) %", action: opacity, keyEquivalent: "")
            item.target = target
            item.representedObject = OpacityPayload(sessionId: sessionId, hudId: hudId, percent: pct)
            opacitySubmenu.addItem(item)
        }
        opacityHeader.submenu = opacitySubmenu
        menu.addItem(opacityHeader)

        return menu
    }
}

/// Payload riding on `NSMenuItem.representedObject` for per-tab actions.
/// The owning HUD is implicit (located by panel name in the session).
final class MenuPayload: NSObject {
    let sessionId: String
    let name: String
    init(sessionId: String, name: String) {
        self.sessionId = sessionId
        self.name = name
    }
}

/// Payload for per-HUD-background actions that need to target a
/// specific sibling HUD within the session.
final class HudPayload: NSObject {
    let sessionId: String
    let hudId: UUID
    init(sessionId: String, hudId: UUID) {
        self.sessionId = sessionId
        self.hudId = hudId
    }
}

/// Payload for opacity-submenu items.
final class OpacityPayload: NSObject {
    let sessionId: String
    let hudId: UUID
    let percent: Int
    init(sessionId: String, hudId: UUID, percent: Int) {
        self.sessionId = sessionId
        self.hudId = hudId
        self.percent = percent
    }
}
