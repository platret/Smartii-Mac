import Cocoa

// Smartii for Mac — a menu-bar AI assistant. Press a hotkey anywhere, screenshot
// the screen, get the answer. Native macOS sibling of the Smartii browser extension.
//
// Runs as an accessory app (LSUIElement): no Dock icon, lives in the menu bar.

// Top-level executable code runs on the main thread, but the compiler can't infer
// main-actor isolation here. AppDelegate (and its stored UI controllers) are
// @MainActor-isolated, so assume main-actor isolation to construct it safely.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
