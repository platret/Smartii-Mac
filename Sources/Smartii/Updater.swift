import Cocoa
import QuartzCore

// MARK: - Updater
//
// In-app auto-updater for Smartii, in the spirit of the Sparkle / Claude desktop
// experience. Talks to the GitHub Releases API for `platret/Smartii-Mac`, compares
// the latest published version against this build, and — when something newer is
// available — presents a translucent glass card matching the welcome / settings
// windows. From that card the user can install the update in place: the new build
// is downloaded, unzipped with `ditto`, and a small detached shell script swaps the
// running .app bundle and relaunches it once this process exits.
//
// Everything here is non-sandboxed and uses system frameworks only.
@MainActor
final class Updater {

    static let shared = Updater()
    private init() {}

    // MARK: Configuration

    private static let repo = "platret/Smartii-Mac"
    private static let assetName = "Smartii-mac.zip"
    private var latestURL: URL {
        URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
    }
    private var releasesPageURL: URL {
        URL(string: "https://github.com/\(Self.repo)/releases/latest")!
    }

    /// Parsed metadata for a GitHub release.
    private struct Release {
        let version: String          // tag_name with any leading 'v' stripped
        let notes: String            // release body (may be empty)
        let downloadURL: URL         // browser_download_url of Smartii-mac.zip
        let pageURL: URL             // html_url / fallback releases page
    }

    private enum UpdateError: Error { case noAsset, badStatus(Int), badPayload }

    /// Guards against two overlapping checks (e.g. background + menu).
    private var isChecking = false
    /// The presented popup, retained while on screen.
    private var popup: UpdatePopupController?

    // MARK: Public API

    /// Silent background check, called ~2s after launch. Shows the popup ONLY when a
    /// strictly newer version exists; does nothing (no UI, no error) otherwise.
    func checkInBackground() {
        guard !isChecking else { return }
        isChecking = true
        Task { @MainActor in
            defer { self.isChecking = false }
            guard let release = try? await self.fetchLatest() else { return }
            if self.isNewer(release.version, than: Self.currentVersion) {
                self.present(for: release)
            }
        }
    }

    /// Explicit check from the "Check for Updates…" menu item. Always fetches, then:
    /// shows the update popup if newer, a small "you're up to date" card if current,
    /// or a brief error card if the fetch fails.
    func checkAndPrompt() {
        guard !isChecking else { return }
        isChecking = true
        Task { @MainActor in
            defer { self.isChecking = false }
            do {
                let release = try await self.fetchLatest()
                if self.isNewer(release.version, than: Self.currentVersion) {
                    self.present(for: release)
                } else {
                    self.presentInfo(.upToDate(Self.currentVersion))
                }
            } catch {
                self.presentInfo(.error)
            }
        }
    }

    // MARK: Version

    /// This build's marketing version, from Info.plist (CFBundleShortVersionString).
    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    /// Numeric dotted-version compare: is `lhs` strictly greater than `rhs`?
    /// Each component is parsed as an integer; missing trailing components count as 0,
    /// so "1.0.4" > "1.0.3" and "1.1" > "1.0.9".
    private func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let a = Self.components(lhs)
        let b = Self.components(rhs)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func components(_ v: String) -> [Int] {
        v.split(separator: ".").map { Int($0.filter { $0.isNumber }) ?? 0 }
    }

    // MARK: Networking

    private func fetchLatest() async throws -> Release {
        var request = URLRequest(url: latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Smartii-Mac/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateError.badStatus(http.statusCode)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String else {
            throw UpdateError.badPayload
        }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let notes = (root["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Find the Smartii-mac.zip asset and its direct download URL.
        let assets = (root["assets"] as? [[String: Any]]) ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String) == Self.assetName }),
              let urlString = asset["browser_download_url"] as? String,
              let downloadURL = URL(string: urlString) else {
            throw UpdateError.noAsset
        }

        let pageURL = (root["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPageURL
        return Release(version: version, notes: notes, downloadURL: downloadURL, pageURL: pageURL)
    }

    // MARK: Presentation

    private func present(for release: Release) {
        let popup = UpdatePopupController(
            version: release.version,
            notes: release.notes.isEmpty ? "A new version of Smartii is available." : release.notes,
            install: { [weak self] controller in
                self?.install(release: release, in: controller)
            },
            manual: { release.pageURL }
        )
        self.popup = popup
        popup.onClose = { [weak self] in self?.popup = nil }
        popup.show()
    }

    private func presentInfo(_ kind: UpdatePopupController.Info) {
        let popup = UpdatePopupController(info: kind)
        self.popup = popup
        popup.onClose = { [weak self] in self?.popup = nil }
        popup.show()
    }

    // MARK: Install & relaunch

    /// Download → unzip → swap-and-relaunch. Runs off-main for the heavy work and
    /// hops back to the main actor to drive the popup's state.
    private func install(release: Release, in controller: UpdatePopupController) {
        controller.setState(.downloading)
        Task {
            do {
                let newApp = try await Self.downloadAndExtract(from: release.downloadURL)
                try await MainActor.run {
                    try Self.swapAndRelaunch(newAppPath: newApp.path)
                }
                // swapAndRelaunch terminates the app; we won't get past here.
            } catch {
                await MainActor.run {
                    controller.setState(.failed)
                }
            }
        }
    }

    /// Downloads the zip to a temp dir and expands it with `/usr/bin/ditto`, returning
    /// the URL of the extracted `Smartii.app`. Runs entirely off the main actor.
    private nonisolated static func downloadAndExtract(from url: URL) async throws -> URL {
        // 1. Download the zip.
        var request = URLRequest(url: url)
        request.setValue("Smartii-Mac", forHTTPHeaderField: "User-Agent")
        let (downloaded, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateError.badStatus(http.statusCode)
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("smartii-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("Smartii-mac.zip")
        // The downloaded temp file is removed by the system; move it to our work dir.
        if fm.fileExists(atPath: zip.path) { try fm.removeItem(at: zip) }
        try fm.moveItem(at: downloaded, to: zip)

        // 2. Expand with ditto.
        let extract = work.appendingPathComponent("extract")
        try fm.createDirectory(at: extract, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, extract.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UpdateError.badPayload }

        // 3. Locate Smartii.app inside the extracted tree (top level, then one deep).
        let direct = extract.appendingPathComponent("Smartii.app")
        if fm.fileExists(atPath: direct.path) { return direct }
        if let entries = try? fm.contentsOfDirectory(at: extract, includingPropertiesForKeys: nil) {
            for entry in entries {
                let nested = entry.appendingPathComponent("Smartii.app")
                if fm.fileExists(atPath: nested.path) { return nested }
                if entry.pathExtension == "app", entry.lastPathComponent == "Smartii.app" { return entry }
            }
        }
        throw UpdateError.noAsset
    }

    /// Writes a detached helper script that waits for this process to exit, swaps the
    /// running bundle with the new one, re-signs ad-hoc, and reopens the app. Launches
    /// it and terminates this process so the swap can complete.
    private static func swapAndRelaunch(newAppPath: String) throws {
        let targetPath = Bundle.main.bundlePath

        let script = """
        #!/bin/bash
        APP="$1"; NEW="$2"; PID="$3"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        /bin/rm -rf "$APP"
        /usr/bin/ditto "$NEW" "$APP"
        /usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null
        /usr/bin/codesign --force --deep --sign - "$APP" 2>/dev/null
        /usr/bin/open "$APP"
        """

        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("smartii-update.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptURL.path, targetPath, newAppPath, pid]
        try task.run()   // detached: do NOT wait.

        // Quit so the helper can replace + reopen the app.
        NSApp.terminate(nil)
    }
}

// MARK: - UpdatePopupController
//
// The translucent glass update card. Mirrors the welcome / settings windows: a
// borderless `WelcomeWindow`, an `.hudWindow` behind-window blur clipped to a rounded
// 20pt shape via a stretchable mask image, a violet top glow, a hairline border, the
// Smartii logo, and a smooth fade-in. Esc or "Later" dismisses it.
@MainActor
final class UpdatePopupController: NSObject {

    /// What an informational (non-update) popup says.
    enum Info {
        case upToDate(String)   // associated value = current version
        case error
    }

    /// Install-flow visual state.
    enum State {
        case idle
        case downloading
        case failed
    }

    /// Called when the popup is dismissed (so the owner can drop its reference).
    var onClose: (() -> Void)?

    // Update-mode callbacks.
    private let installAction: ((UpdatePopupController) -> Void)?
    private let manualURLProvider: (() -> URL)?

    private let mode: Mode
    private enum Mode { case update(version: String, notes: String); case info(Info) }

    private var state: State = .idle

    private let window: WelcomeWindow
    private let card = NSVisualEffectView()
    private let chrome = NSView()
    private let glow = CAGradientLayer()
    private let borderLayer = CAShapeLayer()

    // Dynamic content we mutate as the install progresses.
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let notesScroll = NSScrollView()
    private let notesText = NSTextView()
    private let primaryButton = NSButton()
    private let secondaryButton = NSButton()
    private let progressIndicator = NSProgressIndicator()

    private var escMonitor: Any?

    private enum C {
        static let width: CGFloat = 460
        static let height: CGFloat = 480
        static let inset: CGFloat = 28
        static let corner: CGFloat = 20
        static let accent = NSColor(srgbRed: 0x7c / 255, green: 0x5c / 255, blue: 0xff / 255, alpha: 1)
        static let pink   = NSColor(srgbRed: 0xff / 255, green: 0x5e / 255, blue: 0x9c / 255, alpha: 1)
        static let text   = NSColor(white: 0.97, alpha: 1)
        static let sub    = NSColor(white: 0.66, alpha: 1)
        static let chip   = NSColor(white: 1, alpha: 0.05)
        static let border = NSColor(white: 1, alpha: 0.12)
    }

    // MARK: Init

    /// Update-available popup.
    init(version: String,
         notes: String,
         install: @escaping (UpdatePopupController) -> Void,
         manual: @escaping () -> URL) {
        mode = .update(version: version, notes: notes)
        installAction = install
        manualURLProvider = manual
        window = WelcomeWindow(
            contentRect: NSRect(x: 0, y: 0, width: C.width, height: C.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        super.init()
        configureWindow()
        buildCard()
        buildUpdateContent(version: version, notes: notes)
    }

    /// Informational popup ("you're up to date" / "couldn't check").
    init(info: Info) {
        mode = .info(info)
        installAction = nil
        manualURLProvider = nil
        window = WelcomeWindow(
            contentRect: NSRect(x: 0, y: 0, width: C.width, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        super.init()
        configureWindow()
        buildCard()
        buildInfoContent(info)
    }

    // MARK: Window chrome

    private func configureWindow() {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
    }

    private func buildCard() {
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.maskImage = roundedMask(C.corner)
        window.contentView = card

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
            host.cornerRadius = C.corner
            host.masksToBounds = true
            glow.colors = [
                C.accent.withAlphaComponent(0.30).cgColor,
                C.pink.withAlphaComponent(0.08).cgColor,
                NSColor.clear.cgColor,
            ]
            glow.locations = [0.0, 0.25, 0.55]
            glow.startPoint = CGPoint(x: 0.5, y: 1.0)
            glow.endPoint = CGPoint(x: 0.5, y: 0.0)
            host.addSublayer(glow)

            borderLayer.fillColor = NSColor.clear.cgColor
            borderLayer.strokeColor = C.border.cgColor
            borderLayer.lineWidth = 1
            host.addSublayer(borderLayer)
        }

        // Close (top-right).
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
    }

    // MARK: Update content

    private func buildUpdateContent(version: String, notes: String) {
        let logo = makeLogo(size: 64)

        titleLabel.stringValue = "Update available"
        styleTitle(titleLabel)

        subtitleLabel.stringValue = "Smartii \(version) is ready"
        styleSubtitle(subtitleLabel)

        let header = NSStackView(views: [logo, titleLabel, subtitleLabel])
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = 8
        header.setCustomSpacing(12, after: logo)
        header.setCustomSpacing(4, after: titleLabel)
        header.translatesAutoresizingMaskIntoConstraints = false

        // Release notes — read-only, scrollable.
        configureNotes(notes)

        // Buttons: filled accent "Install & Relaunch" + plain "Later".
        primaryButton.title = "Install & Relaunch"
        stylePrimary(primaryButton, title: "Install & Relaunch")
        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)

        secondaryButton.title = "Later"
        styleSecondary(secondaryButton, title: "Later")
        secondaryButton.target = self
        secondaryButton.action = #selector(closeTapped)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [progressIndicator, secondaryButton, primaryButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 12
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(header)
        card.addSubview(notesScroll)
        card.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: card.topAnchor, constant: C.inset + 4),
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: C.inset),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -C.inset),

            notesScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            notesScroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: C.inset),
            notesScroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -C.inset),

            buttonRow.topAnchor.constraint(equalTo: notesScroll.bottomAnchor, constant: 18),
            buttonRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -C.inset),
            buttonRow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -C.inset),
            buttonRow.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: C.inset),
        ])
    }

    private func configureNotes(_ notes: String) {
        notesText.isEditable = false
        notesText.isSelectable = true
        notesText.drawsBackground = false
        notesText.textColor = C.sub
        notesText.font = .systemFont(ofSize: 13)
        notesText.textContainerInset = NSSize(width: 12, height: 10)
        notesText.string = notes
        notesText.isVerticallyResizable = true
        notesText.isHorizontallyResizable = false
        notesText.autoresizingMask = [.width]
        notesText.textContainer?.widthTracksTextView = true

        notesScroll.documentView = notesText
        notesScroll.hasVerticalScroller = true
        notesScroll.drawsBackground = true
        notesScroll.backgroundColor = NSColor(white: 1, alpha: 0.04)
        notesScroll.borderType = .noBorder
        notesScroll.wantsLayer = true
        notesScroll.layer?.cornerRadius = 12
        notesScroll.layer?.borderWidth = 1
        notesScroll.layer?.borderColor = C.border.cgColor
        notesScroll.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: Info content

    private func buildInfoContent(_ info: Info) {
        let logo = makeLogo(size: 60)

        let title: String
        let subtitle: String
        switch info {
        case .upToDate(let version):
            title = "You're up to date"
            subtitle = "You're on the latest version (\(version))."
        case .error:
            title = "Couldn't check for updates"
            subtitle = "Something went wrong reaching the update server. Please try again later."
        }

        titleLabel.stringValue = title
        styleTitle(titleLabel)

        subtitleLabel.stringValue = subtitle
        styleSubtitle(subtitleLabel)
        subtitleLabel.preferredMaxLayoutWidth = C.width - C.inset * 2

        secondaryButton.title = "OK"
        stylePrimary(secondaryButton, title: "OK")   // single accent "OK" button
        secondaryButton.target = self
        secondaryButton.action = #selector(closeTapped)

        let stack = NSStackView(views: [logo, titleLabel, subtitleLabel, spacer(8), secondaryButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(14, after: logo)
        stack.setCustomSpacing(4, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: C.inset),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -C.inset),
        ])
    }

    // MARK: Install-flow state

    /// Drives the visual state of the install flow. Safe to call repeatedly.
    func setState(_ newState: State) {
        state = newState
        switch newState {
        case .idle:
            progressIndicator.stopAnimation(nil)
            subtitleLabel.textColor = C.sub
            stylePrimary(primaryButton, title: "Install & Relaunch")
            primaryButton.action = #selector(primaryTapped)
            primaryButton.isEnabled = true
            secondaryButton.isHidden = false
        case .downloading:
            progressIndicator.startAnimation(nil)
            subtitleLabel.stringValue = "Downloading…"
            subtitleLabel.textColor = C.text
            primaryButton.isEnabled = false
            secondaryButton.isHidden = true
        case .failed:
            progressIndicator.stopAnimation(nil)
            subtitleLabel.stringValue = "Update failed. You can download it manually."
            subtitleLabel.textColor = C.pink
            stylePrimary(primaryButton, title: "Download manually")
            primaryButton.action = #selector(manualTapped)
            primaryButton.isEnabled = true
            secondaryButton.isHidden = false
        }
    }

    // MARK: Actions

    @objc private func primaryTapped() {
        installAction?(self)
    }

    @objc private func manualTapped() {
        if let url = manualURLProvider?() {
            NSWorkspace.shared.open(url)
        }
        dismiss()
    }

    @objc private func closeTapped() { dismiss() }

    // MARK: Public API

    func show() {
        window.center()
        window.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        card.layoutSubtreeIfNeeded()
        layoutChrome()

        // Rise + fade in, matching the welcome window.
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
                if event.keyCode == 53 {   // Esc
                    self?.dismiss()
                    return nil
                }
                return event
            }
        }
    }

    private func dismiss() {
        // Don't allow dismissal mid-download (button is hidden, but Esc could fire).
        if state == .downloading { return }
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.20
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // The completion handler runs on the main thread but is a nonisolated
            // closure type, so assert main-actor isolation (matches UI.swift).
            MainActor.assumeIsolated {
                self?.window.orderOut(nil)
                self?.onClose?()
            }
        })
    }

    // MARK: Chrome layout

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

    // MARK: Builders

    private func makeLogo(size: CGFloat) -> NSImageView {
        let logo = NSImageView()
        logo.image = logoImage()
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.wantsLayer = true
        logo.shadow = softGlow()
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: size).isActive = true
        logo.heightAnchor.constraint(equalToConstant: size).isActive = true
        return logo
    }

    private func logoImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "SmartiiLogo", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 56, weight: .regular)
        return NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Update")?
            .withSymbolConfiguration(cfg)
    }

    private func softGlow() -> NSShadow {
        let s = NSShadow()
        s.shadowColor = C.accent.withAlphaComponent(0.55)
        s.shadowBlurRadius = 24
        s.shadowOffset = .zero
        return s
    }

    private func styleTitle(_ l: NSTextField) {
        l.font = .systemFont(ofSize: 24, weight: .bold)
        l.textColor = C.text
        l.alignment = .center
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 0
    }

    private func styleSubtitle(_ l: NSTextField) {
        l.font = .systemFont(ofSize: 14, weight: .medium)
        l.textColor = C.sub
        l.alignment = .center
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 0
    }

    private func stylePrimary(_ b: NSButton, title: String) {
        b.isBordered = false
        b.wantsLayer = true
        b.bezelStyle = .regularSquare
        b.layer?.backgroundColor = C.accent.cgColor
        b.layer?.cornerRadius = 9
        b.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: NSColor.white,
                         .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold)]
        )
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    }

    private func styleSecondary(_ b: NSButton, title: String) {
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.contentTintColor = C.sub
        b.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: C.sub,
                         .font: NSFont.systemFont(ofSize: 13.5, weight: .medium)]
        )
        b.translatesAutoresizingMaskIntoConstraints = false
    }

    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    private func roundedMask(_ r: CGFloat) -> NSImage {
        let edge = r * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}
