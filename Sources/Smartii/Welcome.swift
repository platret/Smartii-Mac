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
    /// Clips the glow gradient to the rounded card shape and carries the border.
    private let chrome = NSView()
    private let glow = CAGradientLayer()
    private let borderLayer = CAShapeLayer()
    private let pageContainer = NSView()
    private var pages: [NSView] = []
    private var dots: [NSView] = []
    private let backButton = NSButton()
    private let nextButton = NSButton()
    private var nextWidth: NSLayoutConstraint!
    private var index = 0
    private var escMonitor: Any?

    // Mascot: a fixed-size container we scale/float so layout never moves, plus a
    // behind-robot violet glow circle we breathe independently.
    private let mascotBox = NSView()
    private let logoView = NSImageView()
    private let glowOrb = CALayer()
    private var heroElements: [NSView] = []

    /// Skip looping/decorative animations when the user prefers reduced motion.
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private enum C {
        static let width: CGFloat = 460
        static let height: CGFloat = 540
        static let corner: CGFloat = 20
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
        // Clip the behind-window blur with a resizable rounded-rect MASK image
        // instead of layer.cornerRadius + masksToBounds. Rounding an
        // NSVisualEffectView via the layer leaves hard/transparency artifacts on
        // the edges (notably the right); a mask image clips it cleanly on all
        // four sides.
        card.maskImage = roundedMask(cornerRadius: C.corner)
        window.contentView = card

        // Chrome overlay: hosts the glow + border so both are clipped to the same
        // rounded shape as the card and can never paint a square corner.
        chrome.wantsLayer = true
        chrome.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(chrome)
        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: card.topAnchor),
            chrome.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            chrome.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        if let host = chrome.layer {
            // Clip the glow to the rounded bounds so it follows the corners.
            host.cornerRadius = C.corner
            host.masksToBounds = true

            // Violet glow across the top of the card, clipped to the rounded shape.
            glow.colors = [
                C.accent.withAlphaComponent(0.30).cgColor,
                C.pink.withAlphaComponent(0.08).cgColor,
                NSColor.clear.cgColor,
            ]
            glow.locations = [0.0, 0.25, 0.55]
            glow.startPoint = CGPoint(x: 0.5, y: 1.0) // top
            glow.endPoint = CGPoint(x: 0.5, y: 0.0)   // bottom
            host.addSublayer(glow)

            // 1px hairline border, drawn as a rounded stroke inset by 0.5px so it
            // is crisp and uniform on every edge (a layer border under masking can
            // clip unevenly at the corners).
            borderLayer.fillColor = NSColor.clear.cgColor
            borderLayer.strokeColor = C.border.cgColor
            borderLayer.lineWidth = 1
            host.addSublayer(borderLayer)
        }

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

    /// A resizable rounded-rect mask image whose stretchable center keeps the
    /// corners pixel-perfect at any size. Used as the visual-effect view's
    /// `maskImage` to clip the behind-window blur to a clean rounded shape.
    private func roundedMask(cornerRadius r: CGFloat) -> NSImage {
        let edge = r * 2 + 1
        let size = NSSize(width: edge, height: edge)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
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

        // Fixed-size mascot container. Scaling/floating this box (not the image
        // view) keeps the stack layout perfectly stable. It hosts a behind-robot
        // violet glow orb plus the logo image view on top.
        mascotBox.wantsLayer = true
        mascotBox.translatesAutoresizingMaskIntoConstraints = false
        mascotBox.widthAnchor.constraint(equalToConstant: 108).isActive = true
        mascotBox.heightAnchor.constraint(equalToConstant: 108).isActive = true

        // Soft radial violet orb that sits behind the robot and breathes.
        glowOrb.backgroundColor = C.accent.cgColor
        glowOrb.cornerRadius = 50
        glowOrb.shadowColor = C.accent.cgColor
        glowOrb.shadowOpacity = 1
        glowOrb.shadowRadius = 26
        glowOrb.shadowOffset = .zero
        glowOrb.opacity = 0.42

        logoView.image = logoImage()
        logoView.imageScaling = .scaleProportionallyUpOrDown
        logoView.wantsLayer = true
        logoView.shadow = softGlow()
        logoView.translatesAutoresizingMaskIntoConstraints = false
        mascotBox.addSubview(logoView)
        NSLayoutConstraint.activate([
            logoView.centerXAnchor.constraint(equalTo: mascotBox.centerXAnchor),
            logoView.centerYAnchor.constraint(equalTo: mascotBox.centerYAnchor),
            logoView.widthAnchor.constraint(equalToConstant: 88),
            logoView.heightAnchor.constraint(equalToConstant: 88),
        ])

        let title = label("Smartii", 30, .bold, C.text, align: .center)
        let tagline = label("AI in your menu bar.", 16, .medium, C.accent, align: .center)
        let blurb = label("Press a hotkey anywhere, screenshot your screen, and get the answer — without ever leaving the page you're on.",
                          14, .regular, C.sub, align: .center)
        heroElements = [mascotBox, title, tagline, blurb]

        let heroStack = vstack([
            mascotBox,
            spacer(6),
            title,
            tagline,
            spacer(4),
            blurb,
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

    // MARK: Layout

    /// Keep the manually-framed glow + border layers in sync with the card size.
    private func layoutChrome() {
        let bounds = chrome.bounds
        let actions = ["bounds": NSNull(), "position": NSNull(), "path": NSNull()]
        glow.actions = actions
        borderLayer.actions = actions
        glow.frame = bounds
        borderLayer.frame = bounds
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        borderLayer.path = CGPath(
            roundedRect: inset,
            cornerWidth: C.corner - 0.5,
            cornerHeight: C.corner - 0.5,
            transform: nil
        )
    }

    // MARK: Mascot animation

    /// Anchor a layer's transforms at its center WITHOUT shifting the view, by
    /// compensating the position for the anchor-point change. Call once after the
    /// layer has a non-zero size.
    private func centerAnchor(_ layer: CALayer) {
        guard layer.anchorPoint != CGPoint(x: 0.5, y: 0.5) else { return }
        let b = layer.bounds
        guard b.width > 0, b.height > 0 else { return }
        let old = layer.anchorPoint
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(
            x: layer.position.x + (0.5 - old.x) * b.width,
            y: layer.position.y + (0.5 - old.y) * b.height
        )
    }

    /// Lay out the behind-robot glow orb and (re)start the looping idle/breathing
    /// /glow animations. Safe to call repeatedly; honours reduced-motion.
    private func startMascotLife() {
        // Position the glow orb centered behind the logo within the mascot box.
        let actions: [String: CAAction] = ["bounds": NSNull(), "position": NSNull()]
        glowOrb.actions = actions
        let side: CGFloat = 100
        glowOrb.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        glowOrb.cornerRadius = side / 2
        glowOrb.position = CGPoint(x: mascotBox.bounds.midX, y: mascotBox.bounds.midY)
        if glowOrb.superlayer == nil { mascotBox.layer?.insertSublayer(glowOrb, at: 0) }

        guard let logoLayer = logoView.layer else { return }
        centerAnchor(logoLayer)

        // Remove any prior loops so a re-show doesn't stack them.
        logoLayer.removeAnimation(forKey: "idleLife")
        glowOrb.removeAnimation(forKey: "glowPulse")

        guard !reduceMotion else { return }

        // IDLE FLOAT + BREATHING, layered via a CAAnimationGroup on the logo
        // layer. The group repeats forever; each child autoreverses over a whole
        // number of cycles within the 12s span so the loop is seamless.
        //   float:   2.4s × 5 cycles = 12s  (±5px bob)
        //   breathe: 3.0s × 4 cycles = 12s  (1.0↔1.04 scale, centered anchor)
        let span = 12.0

        let float = CABasicAnimation(keyPath: "transform.translation.y")
        float.fromValue = -5
        float.toValue = 5
        float.duration = 2.4
        float.autoreverses = true
        float.repeatCount = Float(span / 2.4)
        float.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let breathe = CABasicAnimation(keyPath: "transform.scale")
        breathe.fromValue = 1.0
        breathe.toValue = 1.04
        breathe.duration = 3.0
        breathe.autoreverses = true
        breathe.repeatCount = Float(span / 3.0)
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let group = CAAnimationGroup()
        group.animations = [float, breathe]
        group.duration = span
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        logoLayer.add(group, forKey: "idleLife")

        // GLOW PULSE: the violet orb softly breathes opacity, slightly out of
        // phase with the breathing for an organic feel.
        let glowPulse = CABasicAnimation(keyPath: "opacity")
        glowPulse.fromValue = 0.30
        glowPulse.toValue = 0.60
        glowPulse.duration = 2.7
        glowPulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowPulse.autoreverses = true
        glowPulse.repeatCount = .infinity
        glowPulse.isRemovedOnCompletion = false
        glowOrb.add(glowPulse, forKey: "glowPulse")
    }

    private func stopMascotLife() {
        logoView.layer?.removeAnimation(forKey: "idleLife")
        glowOrb.removeAnimation(forKey: "glowPulse")
    }

    /// ENTRANCE POP: spring-ish scale-in for the robot, layered over the idle
    /// loop (the loop's transform.translation/scale and this keyframe coexist).
    private func popMascotIn() {
        guard let layer = logoView.layer else { return }
        centerAnchor(layer)
        guard !reduceMotion else { return }
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.6, 1.06, 0.98, 1.0]
        pop.keyTimes = [0, 0.6, 0.82, 1.0]
        pop.duration = 0.5
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(pop, forKey: "pop")

        // The orb fades up with it.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 0.42
        fade.duration = 0.5
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        glowOrb.add(fade, forKey: "orbFade")
    }

    /// LAST-PAGE WAVE: a friendly little tilt of the robot. Anchor at bottom so it
    /// rocks like a head-nod, then snaps back; doesn't disturb the idle loop.
    private func waveMascot() {
        guard !reduceMotion, let layer = logoView.layer else { return }
        let wave = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        wave.values = [0, 0.16, -0.12, 0.07, 0]
        wave.keyTimes = [0, 0.25, 0.55, 0.8, 1.0]
        wave.duration = 0.7
        wave.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(wave, forKey: "wave")
    }

    /// MICRO-INTERACTION: a quick pop on the active page dot.
    private func bounceActiveDot() {
        guard !reduceMotion, index < dots.count, let layer = dots[index].layer else { return }
        centerAnchor(layer)
        let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
        bounce.values = [1.0, 1.5, 0.9, 1.0]
        bounce.keyTimes = [0, 0.4, 0.7, 1.0]
        bounce.duration = 0.34
        bounce.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(bounce, forKey: "dotBounce")
    }

    /// Fade + small rise stagger for a set of views, 40ms apart.
    private func staggerIn(_ views: [NSView], rise: CGFloat = 10) {
        guard !reduceMotion else {
            for v in views { v.layer?.removeAnimation(forKey: "stagger") }
            return
        }
        for (i, v) in views.enumerated() {
            guard let layer = v.layer else { continue }
            let begin = layer.convertTime(CACurrentMediaTime(), from: nil) + Double(i) * 0.04
            let up = CABasicAnimation(keyPath: "transform.translation.y")
            up.fromValue = rise
            up.toValue = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let group = CAAnimationGroup()
            group.animations = [up, fade]
            group.duration = 0.42
            group.beginTime = begin
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.fillMode = .backwards
            layer.add(group, forKey: "stagger")
        }
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
        if !reduceMotion {
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = forward ? 22 : -22
            slide.toValue = 0
            slide.duration = 0.28
            slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
            incoming.layer?.add(slide, forKey: "slide")
        }

        // Gentle per-element stagger as the page arrives.
        staggerIn(pageElements(of: incoming))
        // Friendly wave when the user lands on the final page.
        if index == pages.count - 1 { waveMascot() }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            incoming.animator().alphaValue = 1
            outgoing?.animator().alphaValue = 0
        }, completionHandler: {
            outgoing?.isHidden = true
        })
    }

    /// The animatable child elements of a page, for stagger-in. For the hero page
    /// we use the captured hero elements (mascot + texts); for list pages we walk
    /// the top-level rows of the pinned stack.
    private func pageElements(of page: NSView) -> [NSView] {
        if page === pages.first { return heroElements }
        if let stack = page.subviews.first as? NSStackView {
            return stack.arrangedSubviews
        }
        return page.subviews
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
            bounceActiveDot()
        }
    }

    @objc private func backTapped() {
        showPage(index - 1, animated: true)
        bounceActiveDot()
    }
    @objc private func closeTapped() { finish() }

    private func finish() {
        Settings.shared.didOnboard = true
        stopMascotLife()
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
        // Lay out the manually-framed glow + border now that the card has size.
        card.layoutSubtreeIfNeeded()
        layoutChrome()

        // Bring the mascot to life and stage its entrance.
        startMascotLife()
        popMascotIn()
        // Stagger the hero text in just after the pop.
        staggerIn(heroElements)

        // Rise the card up a touch as it fades in (skip under reduced motion).
        if !reduceMotion {
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = -16
            rise.toValue = 0
            rise.duration = 0.34
            rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
            card.layer?.add(rise, forKey: "rise")
        }

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
