import Cocoa

// @main entry. AppKit lifecycle — no SwiftUI App in v0.1; the menu-bar
// UX wants the NSApplication delegate pattern explicitly.

@main
enum QuickShowApp {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            // Hold a strong reference for the lifetime of the run loop.
            objc_setAssociatedObject(app, "QuickShowDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            app.run()
        }
    }
}
