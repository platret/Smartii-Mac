import Cocoa
import QuartzCore

// MARK: - Palette

// Centralized dark-UI colors so every view stays consistent.
private enum Palette {
    static let background = NSColor(calibratedRed: 0x0f / 255.0, green: 0x0f / 255.0, blue: 0x14 / 255.0, alpha: 1)
    static let panelFill  = NSColor(calibratedRed: 0x0f / 255.0, green: 0x0f / 255.0, blue: 0x14 / 255.0, alpha: 0.96)
    static let field      = NSColor(calibratedRed: 0x1a / 255.0, green: 0x1a / 255.0, blue: 0x22 / 255.0, alpha: 1)
    static let text       = NSColor(calibratedRed: 0xf5 / 255.0, green: 0xf5 / 255.0, blue: 0xf7 / 255.0, alpha: 1)
    static let secondary  = NSColor(calibratedWhite: 0.62, alpha: 1)
    static let accent     = NSColor(calibratedRed: 0x7c / 255.0, green: 0x5c / 255.0, blue: 0xff / 255.0, alpha: 1)
    static let border     = NSColor(calibratedWhite: 1, alpha: 0.08)
}

// MARK: - FloatingPanel

/// Borderless, non-activating floating panel. Overriding `canBecomeKey` lets the
/// text field inside it accept keyboard focus even though the app is an accessory.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - FlippedStackView

/// An NSStackView whose coordinate system is flipped so that content lays out
/// top→down. Used as the transcript's documentView so new bubbles append at the
/// bottom and the scroll view scrolls naturally from the top.
private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

// MARK: - InputTextField

/// A borderless single-line text field that routes its key commands back to the
/// BarController. Using a dedicated NSTextFieldDelegate keeps Return / Cmd+Return /
/// Esc working inside a borderless panel.
private final class InputTextField: NSTextField {
    /// Plain Return (send, no screenshot).
    var onReturn: (() -> Void)?
    /// Cmd+Return (send with screenshot).
    var onCommandReturn: (() -> Void)?
    /// Esc (hide the panel).
    var onEscape: (() -> Void)?
}

// MARK: - BarController

/// Owns the floating "ask bar" panel rendered as a ChatGPT-style chat window.
///
/// Two states:
///   • COLLAPSED — short panel showing only the input pill (first launch).
///   • EXPANDED  — grows UPWARD to reveal a scrollable transcript above the input.
///
/// The panel's BOTTOM edge stays fixed; only the height (and therefore the origin)
/// changes, so the input pill never jumps.
@MainActor
final class BarController: NSObject, NSTextFieldDelegate {

    // MARK: Public API (callbacks wired up by AppDelegate — DO NOT change signatures)

    var onSubmit: ((_ text: String, _ includeScreenshot: Bool) -> Void)?
    var onGodmode: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    // MARK: Layout constants

    private let panelWidth: CGFloat = 640
    private let edgeInset: CGFloat = 14          // input pill inset from panel edges
    private let pillHeight: CGFloat = 44
    private let collapsedHeight: CGFloat = 74    // input bar only
    private let topBarHeight: CGFloat = 26
    private let maxTranscriptHeight: CGFloat = 460
    private let maxPanelHeight: CGFloat = 560
    private let bottomGap: CGFloat = 90          // distance above the screen bottom

    // MARK: Panel + views

    private let panel: FloatingPanel
    private let effectView = NSVisualEffectView()

    // Top bar (visible only when expanded).
    private let topBar = NSView()
    private let smartiiLabel = NSTextField(labelWithString: "Smartii")

    // Transcript.
    private let transcriptScroll = NSScrollView()
    private let transcriptStack = FlippedStackView()

    // Input pill.
    private let inputPill = NSView()
    private let inputField = InputTextField()

    // MARK: State

    /// The bubble views currently in the transcript (excluding the thinking bubble).
    private var transcript: [NSView] = []
    /// True after the user has sent something but before an answer arrives. Prevents
    /// duplicating the user bubble when setThinking(true) fires for the same message.
    private var hasPendingUser = false
    /// The transient "thinking…" bubble, if shown.
    private var thinkingBubble: NSView?
    /// True once at least one message exists, i.e. the panel is in expanded state.
    private var isExpanded = false

    // Height constraint we animate to grow/shrink the transcript region.
    private var transcriptHeightConstraint: NSLayoutConstraint!

    override init() {
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: collapsedHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        buildContent()
        applyState(animated: false)
    }

    // MARK: Panel chrome

    private func configurePanel() {
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Frosted, rounded contentView — the signature ChatGPT companion look.
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.isEmphasized = true
        effectView.wantsLayer = true
        if let layer = effectView.layer {
            layer.cornerRadius = 18
            layer.masksToBounds = true
            layer.borderWidth = 1
            layer.borderColor = Palette.border.cgColor
        }
        panel.contentView = effectView
    }

    private func buildContent() {
        let content = effectView

        // --- Top bar (Smartii label + new / settings / close) ---
        topBar.translatesAutoresizingMaskIntoConstraints = false

        smartiiLabel.font = .systemFont(ofSize: 12, weight: .medium)
        smartiiLabel.textColor = Palette.secondary
        smartiiLabel.translatesAutoresizingMaskIntoConstraints = false

        let newButton = makeIconButton(symbol: "plus", tint: Palette.secondary, action: #selector(newChatTapped))
        let gearButton = makeIconButton(symbol: "gearshape", tint: Palette.secondary, action: #selector(settingsTapped))
        let closeButton = makeIconButton(symbol: "xmark", tint: Palette.secondary, action: #selector(closeTapped))

        let topRight = NSStackView(views: [newButton, gearButton, closeButton])
        topRight.orientation = .horizontal
        topRight.spacing = 4
        topRight.alignment = .centerY
        topRight.translatesAutoresizingMaskIntoConstraints = false

        topBar.addSubview(smartiiLabel)
        topBar.addSubview(topRight)
        NSLayoutConstraint.activate([
            smartiiLabel.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            smartiiLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            topRight.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            topRight.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            topBar.heightAnchor.constraint(equalToConstant: topBarHeight)
        ])

        // --- Transcript: flipped vertical stack inside a scroll view ---
        transcriptStack.orientation = .vertical
        transcriptStack.alignment = .leading
        transcriptStack.spacing = 10
        transcriptStack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        transcriptStack.translatesAutoresizingMaskIntoConstraints = false

        transcriptScroll.documentView = transcriptStack
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.drawsBackground = false
        transcriptScroll.borderType = .noBorder
        transcriptScroll.automaticallyAdjustsContentInsets = false
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false

        // The stack tracks the scroll view's width so bubbles wrap correctly.
        NSLayoutConstraint.activate([
            transcriptStack.leadingAnchor.constraint(equalTo: transcriptScroll.contentView.leadingAnchor),
            transcriptStack.trailingAnchor.constraint(equalTo: transcriptScroll.contentView.trailingAnchor),
            transcriptStack.topAnchor.constraint(equalTo: transcriptScroll.contentView.topAnchor),
            transcriptStack.widthAnchor.constraint(equalTo: transcriptScroll.widthAnchor)
        ])

        // --- Input pill ---
        inputPill.wantsLayer = true
        inputPill.layer?.backgroundColor = Palette.field.cgColor
        inputPill.layer?.cornerRadius = 12
        inputPill.translatesAutoresizingMaskIntoConstraints = false

        let cameraButton = makeIconButton(symbol: "camera.viewfinder", tint: Palette.secondary, action: #selector(cameraTapped))
        let boltButton = makeIconButton(symbol: "bolt.fill", tint: Palette.secondary, action: #selector(godmodeTapped))

        inputField.placeholderString = "Message Smartii…"
        inputField.font = .systemFont(ofSize: 15)
        inputField.textColor = Palette.text
        inputField.drawsBackground = false
        inputField.backgroundColor = .clear
        inputField.isBezeled = false
        inputField.isBordered = false
        inputField.focusRingType = .none
        inputField.delegate = self
        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        inputField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let cell = inputField.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.wraps = false
            cell.isScrollable = true
        }
        // Key handling for the borderless panel.
        inputField.onReturn = { [weak self] in self?.submitFromField(includeScreenshot: false) }
        inputField.onCommandReturn = { [weak self] in self?.submitFromField(includeScreenshot: true) }
        inputField.onEscape = { [weak self] in self?.hidePanel() }

        // Circular accent send button.
        let sendButton = makeSendButton()

        let pillRow = NSStackView(views: [cameraButton, boltButton, inputField, sendButton])
        pillRow.orientation = .horizontal
        pillRow.spacing = 9
        pillRow.alignment = .centerY
        pillRow.translatesAutoresizingMaskIntoConstraints = false
        inputPill.addSubview(pillRow)
        NSLayoutConstraint.activate([
            pillRow.leadingAnchor.constraint(equalTo: inputPill.leadingAnchor, constant: 12),
            pillRow.trailingAnchor.constraint(equalTo: inputPill.trailingAnchor, constant: -8),
            pillRow.centerYAnchor.constraint(equalTo: inputPill.centerYAnchor),
            inputPill.heightAnchor.constraint(equalToConstant: pillHeight)
        ])

        // --- Assemble: top bar, transcript, input pill stacked vertically ---
        content.addSubview(topBar)
        content.addSubview(transcriptScroll)
        content.addSubview(inputPill)

        transcriptHeightConstraint = transcriptScroll.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: panelWidth),

            // Top bar pinned to the top.
            topBar.topAnchor.constraint(equalTo: content.topAnchor, constant: edgeInset),
            topBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: edgeInset + 2),
            topBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -(edgeInset + 2)),

            // Transcript fills the middle.
            transcriptScroll.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
            transcriptScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: edgeInset),
            transcriptScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -edgeInset),
            transcriptHeightConstraint,

            // Input pill pinned to the bottom.
            inputPill.topAnchor.constraint(equalTo: transcriptScroll.bottomAnchor, constant: 6),
            inputPill.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: edgeInset),
            inputPill.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -edgeInset),
            inputPill.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -edgeInset)
        ])
    }

    // MARK: Button factories

    /// A small borderless icon button built from an SF Symbol.
    private func makeIconButton(symbol: String, tint: NSColor, action: Selector) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.contentTintColor = tint
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 22)
        ])
        return button
    }

    /// The circular accent send button (white up-arrow on violet).
    private func makeSendButton() -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(sendTapped)
        button.contentTintColor = .white
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        button.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Send")?
            .withSymbolConfiguration(config)
        button.wantsLayer = true
        button.layer?.backgroundColor = Palette.accent.cgColor
        button.layer?.cornerRadius = 15
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 30)
        ])
        return button
    }

    // MARK: Button actions

    @objc private func cameraTapped() {
        submitFromField(includeScreenshot: true)
    }

    @objc private func sendTapped() {
        submitFromField(includeScreenshot: false)
    }

    @objc private func godmodeTapped() {
        onGodmode?()
    }

    @objc private func settingsTapped() {
        onOpenSettings?()
    }

    @objc private func closeTapped() {
        hidePanel()
    }

    /// New chat: clear the transcript and collapse back to the input-only state.
    @objc private func newChatTapped() {
        for view in transcriptStack.arrangedSubviews {
            transcriptStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        transcript.removeAll()
        thinkingBubble = nil
        hasPendingUser = false
        isExpanded = false
        applyState(animated: true)
        panel.makeFirstResponder(inputField)
    }

    // MARK: Submission

    /// Pulls text from the input field, appends a user bubble, clears the field,
    /// and dispatches the appropriate callback. Screenshot submissions are prefixed
    /// with a camera emoji to mirror what the model is being shown.
    private func submitFromField(includeScreenshot: Bool) {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let display = includeScreenshot ? "📸 \(text)" : text
        appendUserBubble(display)
        inputField.stringValue = ""
        hasPendingUser = true
        onSubmit?(text, includeScreenshot)
    }

    // MARK: NSTextFieldDelegate

    /// Maps Return / Cmd+Return / Esc in the input field to the right action.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSEvent.modifierFlags.contains(.command) {
                inputField.onCommandReturn?()
            } else {
                inputField.onReturn?()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            inputField.onEscape?()
            return true
        default:
            return false
        }
    }

    // MARK: Message bubbles

    /// A read-only, selectable, wrapping label used for bubble text.
    private func makeBubbleLabel(_ text: String, color: NSColor, maxWidth: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.isEditable = false
        label.isSelectable = true
        label.drawsBackground = false
        label.isBezeled = false
        label.textColor = color
        label.font = .systemFont(ofSize: 14)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        label.preferredMaxLayoutWidth = maxWidth
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    /// Builds a rounded bubble container around an inner content view.
    private func makeBubble(content: NSView, fill: NSColor, padding: NSEdgeInsets) -> NSView {
        let bubble = NSView()
        bubble.wantsLayer = true
        bubble.layer?.backgroundColor = fill.cgColor
        bubble.layer?.cornerRadius = 14
        bubble.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: bubble.topAnchor, constant: padding.top),
            content.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -padding.bottom),
            content.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: padding.left),
            content.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -padding.right)
        ])
        return bubble
    }

    /// Wraps a bubble in a full-width row that aligns it left or right.
    private func makeRow(bubble: NSView, alignRight: Bool) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(bubble)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: row.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            row.widthAnchor.constraint(equalTo: transcriptStack.widthAnchor)
        ])
        if alignRight {
            bubble.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: row.leadingAnchor).isActive = true
        } else {
            bubble.leadingAnchor.constraint(equalTo: row.leadingAnchor).isActive = true
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor).isActive = true
        }
        return row
    }

    /// Right-aligned accent bubble for user messages.
    private func appendUserBubble(_ text: String) {
        let maxWidth = panelWidth * 0.78
        let label = makeBubbleLabel(text, color: Palette.text, maxWidth: maxWidth - 28)
        let bubble = makeBubble(
            content: label,
            fill: Palette.accent.withAlphaComponent(0.20),
            padding: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        )
        bubble.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
        let row = makeRow(bubble: bubble, alignRight: true)
        addRow(row)
    }

    /// Left-aligned neutral bubble for assistant messages (or errors when tinted).
    private func appendAssistantBubble(_ text: String, color: NSColor = Palette.text) {
        let maxWidth = panelWidth * 0.86
        let label = makeBubbleLabel(text, color: color, maxWidth: maxWidth - 28)
        let bubble = makeBubble(
            content: label,
            fill: NSColor(calibratedWhite: 1, alpha: 0.06),
            padding: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        )
        bubble.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
        let row = makeRow(bubble: bubble, alignRight: false)
        addRow(row)
    }

    /// Adds a finished row to the transcript (above any thinking bubble).
    private func addRow(_ row: NSView) {
        if let thinking = thinkingBubble,
           let index = transcriptStack.arrangedSubviews.firstIndex(of: thinking) {
            transcriptStack.insertArrangedSubview(row, at: index)
        } else {
            transcriptStack.addArrangedSubview(row)
        }
        transcript.append(row)
    }

    // MARK: Thinking bubble

    /// Left-aligned bubble with three dots that pulse in a staggered loop.
    private func makeThinkingBubble() -> NSView {
        let dotsContainer = NSView()
        dotsContainer.translatesAutoresizingMaskIntoConstraints = false
        let dotSize: CGFloat = 7
        let spacing: CGFloat = 6
        var previous: NSView?
        for i in 0..<3 {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = Palette.secondary.cgColor
            dot.layer?.cornerRadius = dotSize / 2
            dot.translatesAutoresizingMaskIntoConstraints = false
            dotsContainer.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: dotSize),
                dot.heightAnchor.constraint(equalToConstant: dotSize),
                dot.centerYAnchor.constraint(equalTo: dotsContainer.centerYAnchor)
            ])
            if let previous {
                dot.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: spacing).isActive = true
            } else {
                dot.leadingAnchor.constraint(equalTo: dotsContainer.leadingAnchor).isActive = true
            }
            previous = dot

            // Staggered opacity pulse.
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.25
            pulse.toValue = 1.0
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.beginTime = CACurrentMediaTime() + Double(i) * 0.2
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.layer?.add(pulse, forKey: "pulse")
        }
        if let last = previous {
            last.trailingAnchor.constraint(equalTo: dotsContainer.trailingAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            dotsContainer.heightAnchor.constraint(equalToConstant: dotSize)
        ])

        let bubble = makeBubble(
            content: dotsContainer,
            fill: NSColor(calibratedWhite: 1, alpha: 0.06),
            padding: NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        )
        return makeRow(bubble: bubble, alignRight: false)
    }

    /// Adds the thinking bubble to the bottom of the transcript.
    private func showThinkingBubble() {
        guard thinkingBubble == nil else { return }
        let row = makeThinkingBubble()
        transcriptStack.addArrangedSubview(row)
        thinkingBubble = row
    }

    /// Removes the thinking bubble if present.
    private func removeThinkingBubble() {
        guard let row = thinkingBubble else { return }
        transcriptStack.removeArrangedSubview(row)
        row.removeFromSuperview()
        thinkingBubble = nil
    }

    // MARK: State + layout

    /// Lays the panel out for the current collapsed/expanded state, keeping the
    /// bottom edge fixed and growing/shrinking upward.
    private func applyState(animated: Bool) {
        topBar.isHidden = !isExpanded
        transcriptScroll.isHidden = !isExpanded

        // Compute the target panel height.
        let targetHeight: CGFloat
        let targetTranscript: CGFloat
        if isExpanded {
            // Measure the content's natural height, capped at the maximum.
            transcriptStack.layoutSubtreeIfNeeded()
            let natural = transcriptStack.fittingSize.height
            targetTranscript = min(max(natural, 80), maxTranscriptHeight)
            // chrome = top inset + topBar + gap + gap + pill + bottom inset
            let chrome = edgeInset + topBarHeight + 6 + 6 + pillHeight + edgeInset
            targetHeight = min(targetTranscript + chrome, maxPanelHeight)
        } else {
            targetTranscript = 0
            targetHeight = collapsedHeight
        }

        transcriptHeightConstraint.constant = targetTranscript

        // Keep the panel's BOTTOM edge fixed while the height changes.
        let currentFrame = panel.frame
        let bottom = currentFrame.minY
        let newFrame = NSRect(x: currentFrame.minX,
                              y: bottom,
                              width: panelWidth,
                              height: targetHeight)

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(newFrame, display: true)
                effectView.layoutSubtreeIfNeeded()
            } completionHandler: { [weak self] in
                // The animation completion handler runs on the main thread, but the
                // closure type is nonisolated, so we assert main-actor isolation.
                MainActor.assumeIsolated {
                    self?.scrollToBottom()
                }
            }
        } else {
            panel.setFrame(newFrame, display: true)
            effectView.layoutSubtreeIfNeeded()
            scrollToBottom()
        }
    }

    /// Scrolls the transcript so the newest content is visible at the bottom.
    private func scrollToBottom() {
        guard isExpanded else { return }
        transcriptStack.layoutSubtreeIfNeeded()
        let docHeight = transcriptStack.fittingSize.height
        let clipHeight = transcriptScroll.contentView.bounds.height
        let y = max(0, docHeight - clipHeight)
        // Flipped document: larger y == further down.
        transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        transcriptScroll.reflectScrolledClipView(transcriptScroll.contentView)
    }

    // MARK: Positioning

    /// Anchors the panel to the bottom-center of the main screen's visible frame.
    private func positionPanel() {
        guard let screen = NSScreen.main else { return }
        panel.layoutIfNeeded()
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + bottomGap
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: Public API

    /// Show or hide the panel, depending on current visibility.
    func toggle() {
        if panel.isVisible {
            hidePanel()
        } else {
            showForAsk()
        }
    }

    /// Position, bring forward, activate, and focus the input field. Does NOT clear
    /// the transcript — only "new chat" does that.
    func showForAsk() {
        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(inputField)
    }

    /// Hide the panel.
    func hidePanel() {
        panel.orderOut(nil)
    }

    /// Show or hide the thinking indicator.
    ///
    /// When turned on without a pending user message (e.g. a hotkey-initiated Solve
    /// or Godmode that bypasses the input field), a placeholder user bubble is added
    /// so the transcript reads coherently.
    func setThinking(_ on: Bool) {
        if on {
            if !hasPendingUser {
                appendUserBubble("📸 Screenshot")
                hasPendingUser = true
            }
            isExpanded = true
            showThinkingBubble()
            ensureVisible()
            applyState(animated: true)
        } else {
            removeThinkingBubble()
        }
    }

    /// Display an answer: stop thinking, append an assistant bubble, expand, scroll.
    func showAnswer(_ text: String) {
        setThinking(false)
        appendAssistantBubble(text)
        hasPendingUser = false
        isExpanded = true
        ensureVisible()
        applyState(animated: true)
    }

    /// Display an error bubble (assistant-style, tinted red, prefixed ⚠︎).
    func showError(_ message: String) {
        setThinking(false)
        let errorColor = NSColor(calibratedRed: 0xff / 255.0, green: 0x7a / 255.0, blue: 0x8a / 255.0, alpha: 1)
        appendAssistantBubble("⚠︎ \(message)", color: errorColor)
        hasPendingUser = false
        isExpanded = true
        ensureVisible()
        applyState(animated: true)
    }

    /// Brings the panel up (positioned + key) if it isn't already showing.
    private func ensureVisible() {
        if !panel.isVisible {
            positionPanel()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - SettingsWindowController

/// A translucent "glass" settings card that matches the welcome window and the
/// chat box: dark vibrant material, violet accent, the Smartii logo, generous
/// spacing. Borderless + rounded via a mask image; dismiss with Save, ✕, or Esc.
@MainActor
final class SettingsWindowController: NSObject {

    private let window: WelcomeWindow
    private let card = NSVisualEffectView()
    private let providerPopup = NSPopUpButton()
    private let keyField = NSSecureTextField()
    private let modelPopup = NSPopUpButton()
    private let copyCheckbox = NSButton(checkboxWithTitle: "Copy answers to the clipboard", target: nil, action: nil)
    private let getKeyButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private var escMonitor: Any?

    private enum S {
        static let width: CGFloat = 480
        static let height: CGFloat = 470
        static let inset: CGFloat = 26
        static let corner: CGFloat = 20
        static var contentW: CGFloat { width - inset * 2 }
        static let accent = Palette.accent
        static let pink = NSColor(srgbRed: 0xff / 255, green: 0x5e / 255, blue: 0x9c / 255, alpha: 1)
    }

    override init() {
        window = WelcomeWindow(
            contentRect: NSRect(x: 0, y: 0, width: S.width, height: S.height),
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
        // Render the native popups / secure field in dark so they fit the card.
        window.appearance = NSAppearance(named: .darkAqua)
        buildContent()
        loadFromSettings()
    }

    // MARK: Layout

    private func buildContent() {
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.maskImage = roundedMask(S.corner)
        window.contentView = card

        // Violet top glow + hairline border, clipped to the rounded shape.
        let chrome = NSView()
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
            host.cornerRadius = S.corner
            host.masksToBounds = true
            let glow = CAGradientLayer()
            glow.frame = CGRect(x: 0, y: 0, width: S.width, height: S.height)
            glow.colors = [
                S.accent.withAlphaComponent(0.26).cgColor,
                S.pink.withAlphaComponent(0.06).cgColor,
                NSColor.clear.cgColor,
            ]
            glow.locations = [0.0, 0.22, 0.5]
            glow.startPoint = CGPoint(x: 0.5, y: 1.0)
            glow.endPoint = CGPoint(x: 0.5, y: 0.0)
            host.addSublayer(glow)
            let border = CAShapeLayer()
            border.path = CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: S.width - 1, height: S.height - 1),
                                 cornerWidth: S.corner, cornerHeight: S.corner, transform: nil)
            border.fillColor = NSColor.clear.cgColor
            border.strokeColor = Palette.border.cgColor
            border.lineWidth = 1
            host.addSublayer(border)
        }

        // Header: logo + title + close.
        let logo = NSImageView()
        logo.image = logoImage()
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 34).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.textColor = Palette.text

        let header = NSStackView(views: [logo, title])
        header.orientation = .horizontal
        header.spacing = 12
        header.alignment = .centerY

        let close = NSButton(title: "✕", target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.bezelStyle = .regularSquare
        close.contentTintColor = Palette.secondary
        close.font = .systemFont(ofSize: 15, weight: .medium)
        close.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(close)
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            close.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            close.widthAnchor.constraint(equalToConstant: 28),
            close.heightAnchor.constraint(equalToConstant: 28),
        ])

        let subtitle = NSTextField(labelWithString: "Pick a provider and paste your API key. Keys are stored in your macOS Keychain.")
        subtitle.font = .systemFont(ofSize: 12.5)
        subtitle.textColor = Palette.secondary
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 0
        subtitle.preferredMaxLayoutWidth = S.contentW

        // Provider.
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        providerPopup.translatesAutoresizingMaskIntoConstraints = false
        providerPopup.widthAnchor.constraint(equalToConstant: S.contentW).isActive = true
        for info in Providers.all {
            providerPopup.addItem(withTitle: "\(info.label)  ·  \(info.tier)")
            providerPopup.lastItem?.representedObject = info.id
        }

        // API key + "Get a key" link.
        keyField.placeholderString = "Paste your API key"
        keyField.font = .systemFont(ofSize: 13)
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.heightAnchor.constraint(equalToConstant: 26).isActive = true

        getKeyButton.title = "Get a key →"
        getKeyButton.bezelStyle = .inline
        getKeyButton.isBordered = false
        getKeyButton.contentTintColor = S.accent
        getKeyButton.font = .systemFont(ofSize: 12.5, weight: .medium)
        getKeyButton.target = self
        getKeyButton.action = #selector(getKeyTapped)
        getKeyButton.setContentHuggingPriority(.required, for: .horizontal)

        let keyRow = NSStackView(views: [keyField, getKeyButton])
        keyRow.orientation = .horizontal
        keyRow.spacing = 10
        keyRow.alignment = .centerY
        keyRow.translatesAutoresizingMaskIntoConstraints = false
        keyRow.widthAnchor.constraint(equalToConstant: S.contentW).isActive = true

        // Model.
        modelPopup.translatesAutoresizingMaskIntoConstraints = false
        modelPopup.widthAnchor.constraint(equalToConstant: S.contentW).isActive = true

        // Copy checkbox.
        copyCheckbox.target = self
        if let cell = copyCheckbox.cell as? NSButtonCell { cell.font = .systemFont(ofSize: 13) }
        copyCheckbox.contentTintColor = Palette.text

        // Save (filled accent) + status.
        let saveButton = filledButton("Save", #selector(saveTapped))
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = Palette.secondary
        let saveRow = NSStackView(views: [statusLabel, NSView(), saveButton])
        saveRow.orientation = .horizontal
        saveRow.alignment = .centerY
        saveRow.distribution = .fill
        saveRow.translatesAutoresizingMaskIntoConstraints = false
        saveRow.widthAnchor.constraint(equalToConstant: S.contentW).isActive = true
        saveButton.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [
            header,
            subtitle,
            spacer(6),
            caption("Provider"), providerPopup,
            caption("API key"), keyRow,
            caption("Model"), modelPopup,
            spacer(2),
            copyCheckbox,
            spacer(8),
            saveRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: S.inset),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: S.inset),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -S.inset),
        ])
    }

    // MARK: Builders

    private func caption(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s.uppercased())
        l.font = .systemFont(ofSize: 10.5, weight: .semibold)
        l.textColor = Palette.secondary
        return l
    }

    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    private func filledButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.wantsLayer = true
        b.bezelStyle = .regularSquare
        b.layer?.backgroundColor = Palette.accent.cgColor
        b.layer?.cornerRadius = 9
        b.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold)]
        )
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 34).isActive = true
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        return b
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

    private func logoImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "SmartiiLogo", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "Settings")
    }

    // MARK: State

    private var selectedProviderId: String {
        providerPopup.selectedItem?.representedObject as? String ?? Settings.shared.providerId
    }

    private var selectedModel: String {
        modelPopup.selectedItem?.representedObject as? String ?? ""
    }

    private func loadFromSettings() {
        let settings = Settings.shared
        let id = settings.providerId
        if let index = providerPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == id }) {
            providerPopup.selectItem(at: index)
        }
        rebuildModelPopup(for: id, selecting: settings.model)
        keyField.stringValue = settings.apiKey(for: id) ?? ""
        copyCheckbox.state = settings.autoCopyAnswer ? .on : .off
        statusLabel.stringValue = ""
    }

    private func rebuildModelPopup(for providerId: String, selecting model: String) {
        modelPopup.removeAllItems()
        modelPopup.addItem(withTitle: "Default (recommended)")
        modelPopup.lastItem?.representedObject = ""
        if let info = Providers.info(providerId) {
            for m in info.models {
                modelPopup.addItem(withTitle: m)
                modelPopup.lastItem?.representedObject = m
            }
        }
        if !model.isEmpty,
           let index = modelPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == model }) {
            modelPopup.selectItem(at: index)
        } else {
            modelPopup.selectItem(at: 0)
        }
    }

    // MARK: Actions

    @objc private func providerChanged() {
        let id = selectedProviderId
        rebuildModelPopup(for: id, selecting: "")
        keyField.stringValue = Settings.shared.apiKey(for: id) ?? ""
    }

    @objc private func getKeyTapped() {
        guard let info = Providers.info(selectedProviderId), let url = URL(string: info.keyURL) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func saveTapped() {
        let settings = Settings.shared
        let id = selectedProviderId
        settings.providerId = id
        settings.model = selectedModel
        settings.autoCopyAnswer = (copyCheckbox.state == .on)
        settings.setAPIKey(keyField.stringValue, for: id)
        statusLabel.stringValue = "Saved ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            self?.close()
        }
    }

    @objc private func closeTapped() { close() }

    private func close() {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        window.orderOut(nil)
    }

    // MARK: Public API

    func show() {
        loadFromSettings()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if escMonitor == nil {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { self?.close(); return nil }
                return event
            }
        }
    }
}
