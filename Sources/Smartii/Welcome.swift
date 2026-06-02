import Cocoa
import QuartzCore

// MARK: - Welcome / onboarding

/// Borderless window that can still become key, so the buttons inside our custom
/// translucent card receive clicks and Esc.
final class WelcomeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// A polished, translucent, multi-page first-launch onboarding window:
/// blurred glass card, the Smartii logo, a violet glow, page dots, crossfading
/// pages, and a smooth fade + rise in/out. Shown once (Settings.didOnboard) and
/// re-openable from the menu-bar "Welcome / Help" item.
@MainActor
final class WelcomeWindowController: NSObject {

    /// Invoked when the user taps "Set up API key →".
    var onOpenSettings: (() -> Void)?

    private let window: WelcomeWindow
    private let card = NSVisualEffectView()
    private let pageContainer = NSView()
    private var pages: [NSView] = []
    private var dots: [NSView] = []
    private let backButton = NSButton()
    private let nextButton = NSButton()
    private var nextWidth: NSLayoutConstraint!
    private var index = 0
    private var escMonitor: Any?

    private enum C {
        static let width: CGFloat = 460
        static let height: CGFloat = 540
        static let accent = NSColor(srgbRed: 0x7c / 255, green: 0x5c / 255, blue: 0xff / 255, alpha: 1)
        static let pink   = NSColor(srgbRed: 0xff / 255, green: 0x5e / 255, blue: 0x9c / 255, alpha: 1)
        static let text   = NSColor(white: 0.97, alpha: 1)
        static let sub    = NSColor(white: 0.66, alpha: 1)
        static let chip   = NSColor(white: 1, alpha: 0.07)
        static let border = NSColor(white: 1, alpha: 0.12)
        static let dotOff = NSColor(white: 1, alpha: 0.22)
    }

    // MARK: Init

    override init() {
        window = WelcomeWindow(
            contentRect: NSRect(x: 0, y: 0, width: C.width, height: C.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false

        buildCard()
        buildBottomBar()
        buildPages()
        showPage(0, animated: false)
    }

    // MARK: Card chrome

    private func buildCard() {
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 20
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        card.layer?.borderColor = C.border.cgColor
        window.contentView = card

        // Violet glow across the top of the card.
        let glow = CAGradientLayer()
        glow.frame = CGRect(x: 0, y: 0, width: C.width, height: C.height)
        glow.colors = [
            C.accent.withAlphaComponent(0.30).cgColor,
            C.pink.withAlphaComponent(0.08).cgColor,
            NSColor.clear.cgColor,
        ]
        glow.locations = [0.0, 0.25, 0.55]
        glow.startPoint = CGPoint(x: 0.5, y: 1.0) // top
        glow.endPoint = CGPoint(x: 0.5, y: 0.0)   // bottom
        card.layer?.insertSublayer(glow, at: 0)

        // Close button (top-right).
        let close = NSButton(title: "✕", target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.bezelStyle = .regularSquare
        close.contentTintColor = C.sub
        close.font = .systemFont(ofSize: 15, weight: .medium)
        close.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(close)
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            close.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            close.widthAnchor.constraint(equalToConstant: 28),
            close.heightAnchor.constraint(equalToConstant: 28),
        ])

        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(pageContainer)
    }

    private func buildBottomBar() {
        // Page dots.
        let dotRow = NSStackView()
        dotRow.orientation = .horizontal
        dotRow.spacing = 8
        dotRow.translatesAutoresizingMaskIntoConstraints = false
        for _ in 0..<3 {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.backgroundColor = C.dotOff.cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
            dots.append(dot)
            dotRow.addArrangedSubview(dot)
        }
        card.addSubview(dotRow)

        // Back (plain) and Next (filled accent).
        backButton.title = "Back"
        backButton.isBordered = false
        backButton.bezelStyle = .regularSquare
        backButton.contentTintColor = C.sub
        backButton.font = .systemFont(ofSize: 13)
        backButton.target = self
        backButton.action = #selector(backTapped)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(backButton)

        nextButton.isBordered = false
        nextButton.bezelStyle = .regularSquare
        nextButton.wantsLayer = true
        nextButton.layer?.cornerRadius = 9
        nextButton.layer?.backgroundColor = C.accent.cgColor
        nextButton.target = self
        nextButton.action = #selector(nextTapped)
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(nextButton)
        nextWidth = nextButton.widthAnchor.constraint(equalToConstant: 90)

        NSLayoutConstraint.activate([
            nextButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),
            nextButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
            nextButton.heightAnchor.constraint(equalToConstant: 36),
            nextWidth,

            backButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
            backButton.centerYAnchor.constraint(equalTo: nextButton.centerYAnchor),

            dotRow.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            dotRow.bottomAnchor.constraint(equalTo: nextButton.topAnchor, constant: -18),

            pageContainer.topAnchor.constraint(equalTo: card.topAnchor, constant: 34),
            pageContainer.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 32),
            pageContainer.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -32),
            pageContainer.bottomAnchor.constraint(equalTo: dotRow.topAnchor, constant: -16),
        ])
    }

    // MARK: Pages

    private func buildPages() {
        let p1 = makePage()
        let logo = NSImageView()
        logo.image = logoImage()
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.wantsLayer = true
        logo.shadow = softGlow()
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 88).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 88).isActive = true
        let heroStack = vstack([
            logo,
            spacer(6),
            label("Smartii", 30, .bold, C.text, align: .center),
            label("AI in your menu bar.", 16, .medium, C.accent, align: .center),
            spacer(4),
            label("Press a hotkey anywhere, screenshot your screen, and get the answer — without ever leaving the page you're on.",
                  14, .regular, C.sub, align: .center),
        ])
        heroStack.alignment = .centerX
        center(heroStack, in: p1)

        let p2 = makePage()
        let s2 = vstack([
            label("Press a key. Anywhere.", 22, .bold, C.text),
            label("Smartii works system-wide — no window to find.", 13.5, .regular, C.sub),
            spacer(10),
            shortcutRow("⌘ ⇧ S", "Open the ask bar"),
            shortcutRow("⌥ ⇧ S", "Screenshot the screen + solve"),
            shortcutRow("⌥ ⇧ G", "Godmode — answer everything on screen"),
            shortcutRow("⌥ ⇧ X", "Panic — hide instantly"),
        ])
        s2.alignment = .leading
        pinTop(s2, in: p2)

        let p3 = makePage()
        let s3 = vstack([
            label("Set up in 3 steps.", 22, .bold, C.text),
            spacer(6),
            stepRow(1, "Pick a provider — Gemini and Groq have generous free tiers."),
            stepRow(2, "Paste your API key. It's stored safely in your macOS Keychain."),
            stepRow(3, "Press ⌥⇧G on any screen. macOS will ask for Screen Recording permission the first time — allow it."),
            spacer(8),
            label("Tip: answers are copied to your clipboard automatically.", 12.5, .regular, C.sub),
        ])
        s3.alignment = .leading
        pinTop(s3, in: p3)

        pages = [p1, p2, p3]
        for p in pages {
            p.isHidden = true
            p.alphaValue = 0
        }
    }

    private func makePage() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            v.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
        ])
        return v
    }

    // MARK: Navigation

    private func showPage(_ i: Int, animated: Bool) {
        guard i >= 0, i < pages.count else { return }
        let outgoing = (index != i && index < pages.count) ? pages[index] : nil
        let incoming = pages[i]
        let forward = i >= index
        index = i
        updateChrome()

        if !animated {
            for (j, p) in pages.enumerated() {
                p.isHidden = (j != i)
                p.alphaValue = (j == i) ? 1 : 0
            }
            return
        }

        incoming.isHidden = false
        incoming.alphaValue = 0
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = forward ? 22 : -22
        slide.toValue = 0
        slide.duration = 0.28
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        incoming.layer?.add(slide, forKey: "slide")

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            incoming.animator().alphaValue = 1
            outgoing?.animator().alphaValue = 0
        }, completionHandler: {
            outgoing?.isHidden = true
        })
    }

    private func updateChrome() {
        let last = index == pages.count - 1
        backButton.isHidden = index == 0
        let title = last ? "Set up API key →" : "Next"
        nextButton.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
            ]
        )
        nextWidth.constant = last ? 168 : 90
        for (j, dot) in dots.enumerated() {
            dot.layer?.backgroundColor = (j == index ? C.accent : C.dotOff).cgColor
        }
    }

    // MARK: Actions

    @objc private func nextTapped() {
        if index == pages.count - 1 {
            finish()
            onOpenSettings?()
        } else {
            showPage(index + 1, animated: true)
        }
    }

    @objc private func backTapped() { showPage(index - 1, animated: true) }
    @objc private func closeTapped() { finish() }

    private func finish() {
        Settings.shared.didOnboard = true
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.20
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.window.orderOut(nil)
            self?.window.alphaValue = 1
        })
    }

    // MARK: Public API

    func show() {
        // Reset to the first page each time it's opened.
        showPage(0, animated: false)
        window.center()
        window.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // Rise the card up a touch as it fades in.
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -16
        rise.toValue = 0
        rise.duration = 0.34
        rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
        card.layer?.add(rise, forKey: "rise")

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.30
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }

        if escMonitor == nil {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { // Esc
                    self?.finish()
                    return nil
                }
                return event
            }
        }
    }

    // MARK: Builders

    private func logoImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "SmartiiLogo", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        // Fallback when running outside the .app bundle (e.g. `swift run`).
        let cfg = NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)
        return NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Smartii")?
            .withSymbolConfiguration(cfg)
    }

    private func softGlow() -> NSShadow {
        let s = NSShadow()
        s.shadowColor = C.accent.withAlphaComponent(0.55)
        s.shadowBlurRadius = 24
        s.shadowOffset = .zero
        return s
    }

    private func label(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight,
                       _ color: NSColor, align: NSTextAlignment = .left) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.alignment = align
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func keyChip(_ s: String) -> NSView {
        let t = NSTextField(labelWithString: s)
        t.font = .monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        t.textColor = C.text
        t.alignment = .center
        t.isBezeled = false
        t.drawsBackground = false
        t.isEditable = false
        t.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = C.chip.cgColor
        box.layer?.cornerRadius = 7
        box.layer?.borderWidth = 1
        box.layer?.borderColor = C.border.cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(t)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 92),
            box.heightAnchor.constraint(equalToConstant: 30),
            t.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            t.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        return box
    }

    private func shortcutRow(_ keys: String, _ desc: String) -> NSView {
        let row = NSStackView(views: [keyChip(keys), label(desc, 13.5, .regular, C.sub)])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        return row
    }

    private func stepRow(_ n: Int, _ text: String) -> NSView {
        let badge = NSTextField(labelWithString: "\(n)")
        badge.font = .systemFont(ofSize: 12, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.isBezeled = false
        badge.drawsBackground = false
        badge.isEditable = false
        badge.translatesAutoresizingMaskIntoConstraints = false

        let circle = NSView()
        circle.wantsLayer = true
        circle.layer?.backgroundColor = C.accent.cgColor
        circle.layer?.cornerRadius = 11
        circle.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(badge)
        NSLayoutConstraint.activate([
            circle.widthAnchor.constraint(equalToConstant: 22),
            circle.heightAnchor.constraint(equalToConstant: 22),
            badge.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
        ])

        let row = NSStackView(views: [circle, label(text, 13.5, .regular, C.text)])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        return row
    }

    private func vstack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.spacing = 8
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    /// Center a stack within a page (used for the hero page).
    private func center(_ v: NSView, in parent: NSView) {
        parent.addSubview(v)
        NSLayoutConstraint.activate([
            v.centerYAnchor.constraint(equalTo: parent.centerYAnchor),
            v.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])
    }

    /// Pin a stack to the top of a page (used for list pages).
    private func pinTop(_ v: NSView, in parent: NSView) {
        parent.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: parent.topAnchor, constant: 8),
            v.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])
    }
}
