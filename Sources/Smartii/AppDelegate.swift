import Cocoa
import Carbon.HIToolbox

// AppDelegate — the glue of Smartii for Mac.
//
// Owns the menu-bar status item, the floating answer panel (BarController) and the
// settings window. Registers four global hotkeys and routes both the hotkeys and the
// menu items into the same handful of async flows that talk to the AI providers.
//
// Hotkey bindings (see contract):
//   ⌘⇧S  toggle / ask        ⌥⇧S  solve screen
//   ⌥⇧G  godmode             ⌥⇧X  panic (hide panel)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // The GODMODE prompt is fed verbatim to the provider alongside a screenshot.
    private static let godmodePrompt = """
    GODMODE: read the entire attached screenshot of the user's screen. Identify the \
    most important question, problem, code, error, or task on screen and answer it \
    directly and completely. If there are multiple questions, answer all of them, \
    numbered. If it's a multiple-choice question, give the correct letter AND the \
    reasoning. If it's code or an error, show the fix. Be precise. No filler.
    """

    // Generic instruction used when the user submits a screenshot with no typed text.
    private static let screenshotOnlyPrompt = """
    Read the attached screenshot of the user's screen and answer the most important \
    question or task shown. Be direct and complete.
    """

    private var statusItem: NSStatusItem?
    private let bar = BarController()
    private let settingsController = SettingsWindowController()
    private let welcomeController = WelcomeWindowController()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        wireBarController()
        registerHotKeys()

        // First launch: show the welcome / onboarding window once.
        welcomeController.onOpenSettings = { [weak self] in
            self?.settingsController.show()
        }
        if !Settings.shared.didOnboard {
            welcomeController.show()
        }

        // Quietly check for a newer release shortly after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Updater.shared.checkInBackground()
        }
    }

    // MARK: - Status item & menu

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = AppDelegate.makeMenuBarIcon()

        let menu = NSMenu()

        let ask = NSMenuItem(title: "Ask Smartii  ⌘⇧S",
                             action: #selector(menuAsk), keyEquivalent: "")
        ask.target = self
        menu.addItem(ask)

        let solve = NSMenuItem(title: "Solve screen  ⌥⇧S",
                               action: #selector(menuSolveScreen), keyEquivalent: "")
        solve.target = self
        menu.addItem(solve)

        let godmodeItem = NSMenuItem(title: "⚡ Godmode  ⌥⇧G",
                                     action: #selector(menuGodmode), keyEquivalent: "")
        godmodeItem.target = self
        menu.addItem(godmodeItem)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(menuSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        let checkUpdates = NSMenuItem(title: "Check for Updates…",
                                      action: #selector(menuCheckForUpdates), keyEquivalent: "")
        checkUpdates.target = self
        menu.addItem(checkUpdates)

        let welcome = NSMenuItem(title: "Welcome / Help",
                                 action: #selector(menuWelcome), keyEquivalent: "")
        welcome.target = self
        menu.addItem(welcome)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Smartii",
                              action: #selector(menuQuit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    /// Builds the Smartii robot menu-bar glyph as a template image.
    ///
    /// The art is a simplified vector of the Smartii mascot: a rounded-square head
    /// with two punched-out round eyes and a short antenna ending in a small bulb.
    /// Everything is drawn in pure black; marking the image as a template lets the
    /// system recolor it (white on the typical dark menu bar, dark when highlighted).
    private static func makeMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            // ----- Head: a rounded square, roughly centered, ~13×12. -----
            let headRect = NSRect(x: 2.5, y: 2.5, width: 13.0, height: 11.5)
            let head = NSBezierPath(roundedRect: headRect, xRadius: 3.2, yRadius: 3.2)

            // Two round eyes, punched out of the head via even-odd winding.
            let eyeRadius: CGFloat = 1.7
            let eyeY = headRect.midY - 0.3
            let leftEyeCenter = NSPoint(x: headRect.midX - 2.9, y: eyeY)
            let rightEyeCenter = NSPoint(x: headRect.midX + 2.9, y: eyeY)
            for center in [leftEyeCenter, rightEyeCenter] {
                let eyeRect = NSRect(x: center.x - eyeRadius,
                                     y: center.y - eyeRadius,
                                     width: eyeRadius * 2,
                                     height: eyeRadius * 2)
                head.appendOval(in: eyeRect)
            }
            head.windingRule = .evenOdd
            NSColor.black.setFill()
            head.fill()

            // ----- Antenna: a thin stalk rising ~2.5px from the top center… -----
            let antenna = NSBezierPath()
            let stalkBottom = NSPoint(x: headRect.midX, y: headRect.maxY)
            let stalkTop = NSPoint(x: headRect.midX, y: headRect.maxY + 2.0)
            antenna.move(to: stalkBottom)
            antenna.line(to: stalkTop)
            antenna.lineWidth = 1.2
            antenna.lineCapStyle = .round
            NSColor.black.setStroke()
            antenna.stroke()

            // …topped by a small filled bulb.
            let bulbRadius: CGFloat = 1.5
            let bulbRect = NSRect(x: stalkTop.x - bulbRadius,
                                  y: stalkTop.y,
                                  width: bulbRadius * 2,
                                  height: bulbRadius * 2)
            let bulb = NSBezierPath(ovalIn: bulbRect)
            NSColor.black.setFill()
            bulb.fill()

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Smartii"
        return image
    }

    // MARK: - BarController wiring

    private func wireBarController() {
        // The panel hands us the typed text and whether it was a Solve (screenshot) submit.
        bar.onSubmit = { [weak self] text, includeScreenshot in
            self?.solve(text: text, includeScreenshot: includeScreenshot)
        }
        bar.onGodmode = { [weak self] in
            self?.godmode()
        }
        bar.onOpenSettings = { [weak self] in
            self?.settingsController.show()
        }
    }

    // MARK: - Global hotkeys

    private func registerHotKeys() {
        // Carbon kVK_ANSI_* codes: S = 1, G = 5, X = 7.
        let s: UInt32 = 1
        let g: UInt32 = 5
        let x: UInt32 = 7

        let cmdShift = UInt32(cmdKey) | UInt32(shiftKey)
        let optShift = UInt32(optionKey) | UInt32(shiftKey)

        // ⌘⇧S — toggle the ask panel.
        HotKeyManager.shared.register(keyCode: s, modifiers: cmdShift) { [weak self] in
            self?.toggleBar()
        }
        // ⌥⇧S — capture the screen and solve it.
        HotKeyManager.shared.register(keyCode: s, modifiers: optShift) { [weak self] in
            self?.solveScreen()
        }
        // ⌥⇧G — godmode: capture + answer everything on screen.
        HotKeyManager.shared.register(keyCode: g, modifiers: optShift) { [weak self] in
            self?.godmode()
        }
        // ⌥⇧X — panic: hide the panel instantly.
        HotKeyManager.shared.register(keyCode: x, modifiers: optShift) { [weak self] in
            self?.bar.hidePanel()
        }
    }

    // MARK: - Menu actions
    //
    // Each menu item routes into exactly the same flow as its matching hotkey.

    @objc private func menuAsk() { toggleBar() }
    @objc private func menuSolveScreen() { solveScreen() }
    @objc private func menuGodmode() { godmode() }
    @objc private func menuSettings() { settingsController.show() }
    @objc private func menuCheckForUpdates() { Updater.shared.checkAndPrompt() }
    @objc private func menuWelcome() { welcomeController.show() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: - Flows

    /// Toggle the floating ask panel.
    func toggleBar() {
        bar.toggle()
    }

    /// Capture the screen and solve it with no typed prompt.
    func solveScreen() {
        solve(text: "", includeScreenshot: true)
    }

    /// Godmode — screenshot the screen and run the verbatim GODMODE prompt.
    func godmode() {
        solve(text: AppDelegate.godmodePrompt, includeScreenshot: true)
    }

    /// The core flow: optionally screenshot the screen, call the configured provider,
    /// then show the answer (and copy it) or surface the error.
    ///
    /// - Parameters:
    ///   - text: the user's prompt (may be empty for a pure screenshot solve).
    ///   - includeScreenshot: capture the main display and attach it to the request.
    func solve(text: String, includeScreenshot: Bool) {
        Task { @MainActor in
            let settings = Settings.shared
            let providerId = settings.providerId

            // 1. Require an API key for the chosen provider before doing anything.
            guard let apiKey = settings.apiKey(for: providerId), !apiKey.isEmpty else {
                let label = Providers.info(providerId)?.label ?? providerId
                bar.showError("No API key set for \(label). Open Settings to add one.")
                bar.showForAsk()
                settingsController.show()
                return
            }

            bar.setThinking(true)

            // 2. Optionally grab a screenshot. Hide our own panel first so it isn't
            //    captured, give the window server a moment to actually hide it, then shoot.
            var imageDataURL: String? = nil
            if includeScreenshot {
                bar.hidePanel()
                try? await Task.sleep(nanoseconds: 250_000_000) // 0.25s

                let img = await Screenshot.captureMainDisplay()
                guard let img else {
                    bar.setThinking(false)
                    bar.showError("Couldn't capture the screen. Grant Screen Recording "
                                  + "permission in System Settings → Privacy & Security → "
                                  + "Screen Recording, then try again.")
                    return
                }
                imageDataURL = img
            }

            // 3. Build the prompt. An empty prompt with a screenshot gets a generic
            //    "read the screenshot and answer" instruction.
            let prompt: String
            if text.isEmpty && imageDataURL != nil {
                prompt = AppDelegate.screenshotOnlyPrompt
            } else {
                prompt = text
            }

            // 4. Call the provider. Empty model string means "use the provider default".
            let model = settings.model.isEmpty ? nil : settings.model
            do {
                let answer = try await Providers.call(
                    providerId: providerId,
                    apiKey: apiKey,
                    prompt: prompt,
                    imageDataURL: imageDataURL,
                    model: model
                )
                bar.setThinking(false)
                bar.showAnswer(answer)

                // 5. Auto-copy the answer to the clipboard if enabled.
                if settings.autoCopyAnswer {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(answer, forType: .string)
                }
            } catch {
                bar.setThinking(false)
                bar.showError(error.localizedDescription)
            }
        }
    }
}
