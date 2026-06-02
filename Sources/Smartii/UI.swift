import Cocoa

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

// MARK: - BarController

/// Owns the floating "ask bar" panel: an input row plus a scrollable answer view.
@MainActor
final class BarController: NSObject, NSTextFieldDelegate {

    // Callbacks wired up by AppDelegate.
    var onSubmit: ((_ text: String, _ includeScreenshot: Bool) -> Void)?
    var onGodmode: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let panel: FloatingPanel
    private let inputField = NSTextField()
    private let answerView = NSTextView()
    private let answerScroll: NSScrollView
    private let statusLabel = NSTextField(labelWithString: "")

    private let panelWidth: CGFloat = 720

    override init() {
        // Build the panel up front; it is shown/hidden on demand.
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 220),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        answerScroll = NSScrollView()
        super.init()
        configurePanel()
        buildContent()
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

        // Rounded, dark, translucent backdrop via the content view's layer.
        let content = NSView()
        content.wantsLayer = true
        if let layer = content.layer {
            layer.backgroundColor = Palette.panelFill.cgColor
            layer.cornerRadius = 16
            layer.borderWidth = 1
            layer.borderColor = Palette.border.cgColor
        }
        panel.contentView = content
    }

    private func buildContent() {
        guard let content = panel.contentView else { return }

        // Input field.
        inputField.placeholderString = "Ask Smartii anything, or hit Solve to read the screen…"
        inputField.font = .systemFont(ofSize: 15)
        inputField.textColor = Palette.text
        inputField.backgroundColor = Palette.field
        inputField.drawsBackground = true
        inputField.isBezeled = false
        inputField.focusRingType = .none
        inputField.delegate = self
        inputField.wantsLayer = true
        inputField.layer?.cornerRadius = 9
        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Inset the text so it doesn't hug the rounded corners.
        if let cell = inputField.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.wraps = false
            cell.isScrollable = true
        }

        // Action buttons.
        let solveButton = makeButton(title: "Solve", primary: false, action: #selector(solveTapped))
        let godmodeButton = makeButton(title: "⚡ Godmode", primary: false, action: #selector(godmodeTapped))
        let sendButton = makeButton(title: "Send", primary: true, action: #selector(sendTapped))
        let gearButton = makeIconButton(title: "⚙", action: #selector(settingsTapped))
        let closeButton = makeIconButton(title: "✕", action: #selector(closeTapped))

        // Top row: input + buttons.
        let topRow = NSStackView(views: [inputField, solveButton, godmodeButton, sendButton, gearButton, closeButton])
        topRow.orientation = .horizontal
        topRow.spacing = 8
        topRow.alignment = .centerY
        topRow.distribution = .fill
        topRow.translatesAutoresizingMaskIntoConstraints = false

        // Status label ("Thinking…").
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = Palette.secondary
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // Answer text view inside a scroll view (read-only, selectable).
        answerView.isEditable = false
        answerView.isSelectable = true
        answerView.drawsBackground = true
        answerView.backgroundColor = Palette.field
        answerView.textColor = Palette.text
        answerView.font = .systemFont(ofSize: 14)
        answerView.textContainerInset = NSSize(width: 10, height: 10)
        answerView.isVerticallyResizable = true
        answerView.isHorizontallyResizable = false
        answerView.autoresizingMask = [.width]
        answerView.textContainer?.widthTracksTextView = true
        answerView.string = ""

        answerScroll.documentView = answerView
        answerScroll.hasVerticalScroller = true
        answerScroll.drawsBackground = false
        answerScroll.borderType = .noBorder
        answerScroll.wantsLayer = true
        answerScroll.layer?.cornerRadius = 9
        answerScroll.layer?.masksToBounds = true
        answerScroll.translatesAutoresizingMaskIntoConstraints = false

        // Vertical stack: top row, status, answer.
        let stack = NSStackView(views: [topRow, statusLabel, answerScroll])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            topRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            topRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),

            inputField.heightAnchor.constraint(equalToConstant: 34),

            answerScroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            answerScroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            answerScroll.heightAnchor.constraint(equalToConstant: 220),

            content.widthAnchor.constraint(equalToConstant: panelWidth)
        ])
    }

    // MARK: Button factories

    private func makeButton(title: String, primary: Bool, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.isBordered = true
        button.setButtonType(.momentaryPushIn)
        button.font = .systemFont(ofSize: 13, weight: primary ? .semibold : .regular)
        button.wantsLayer = true
        button.contentTintColor = primary ? .white : Palette.text
        if primary, let layer = button.layer {
            layer.backgroundColor = Palette.accent.cgColor
            layer.cornerRadius = 8
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: NSColor.white,
                             .font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
            )
        }
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func makeIconButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.isBordered = true
        button.font = .systemFont(ofSize: 14)
        button.contentTintColor = Palette.secondary
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    // MARK: Button actions

    @objc private func solveTapped() {
        onSubmit?(inputField.stringValue, true)
    }

    @objc private func sendTapped() {
        onSubmit?(inputField.stringValue, false)
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

    // MARK: NSTextFieldDelegate

    /// Maps Return / Cmd+Return / Esc in the input field to the right action.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            // Cmd+Return = solve (include screenshot); plain Return = send.
            let includeScreenshot = NSEvent.modifierFlags.contains(.command)
            onSubmit?(inputField.stringValue, includeScreenshot)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hidePanel()
            return true
        default:
            return false
        }
    }

    // MARK: Positioning

    /// Anchors the panel to the bottom-center of the main screen.
    private func positionPanel() {
        guard let screen = NSScreen.main else { return }
        panel.layoutIfNeeded()
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + 80  // floats a little above the Dock
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

    /// Position, bring forward, activate, and focus the input field.
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

    /// Toggle the "Thinking…" status and lock the input while busy.
    func setThinking(_ on: Bool) {
        if on {
            statusLabel.stringValue = "Thinking…"
            statusLabel.isHidden = false
        } else {
            statusLabel.isHidden = true
            statusLabel.stringValue = ""
        }
        inputField.isEnabled = !on
        // Make sure the panel is up so the user sees progress.
        if !panel.isVisible { showForAsk() }
    }

    /// Display an answer, clearing any thinking status, ensuring the panel is visible.
    func showAnswer(_ text: String) {
        setThinking(false)
        answerView.string = text
        answerView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        if !panel.isVisible {
            positionPanel()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Display an error message in the answer view.
    func showError(_ message: String) {
        showAnswer("Error: \(message)")
    }
}

// MARK: - SettingsWindowController

/// A normal titled window for choosing provider, key, model, and copy behavior.
@MainActor
final class SettingsWindowController: NSObject {

    private let window: NSWindow
    private let providerPopup = NSPopUpButton()
    private let keyField = NSSecureTextField()
    private let modelPopup = NSPopUpButton()
    private let copyCheckbox = NSButton(checkboxWithTitle: "Copy answer to clipboard", target: nil, action: nil)
    private let getKeyButton = NSButton()

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Smartii Settings"
        window.isReleasedWhenClosed = false
        window.backgroundColor = Palette.background
        buildContent()
        loadFromSettings()
    }

    // MARK: Layout

    private func buildContent() {
        let content = NSView()
        window.contentView = content

        // Provider popup: "<label> (<tier>)" per entry, in contract order.
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        for info in Providers.all {
            providerPopup.addItem(withTitle: "\(info.label) (\(info.tier))")
            providerPopup.lastItem?.representedObject = info.id
        }

        // API key field + "Get a key" link button.
        keyField.placeholderString = "API key"
        keyField.font = .systemFont(ofSize: 13)

        getKeyButton.title = "Get a key"
        getKeyButton.bezelStyle = .inline
        getKeyButton.isBordered = false
        getKeyButton.contentTintColor = Palette.accent
        getKeyButton.target = self
        getKeyButton.action = #selector(getKeyTapped)

        // Model popup (editable list; blank first item means "use default").
        modelPopup.target = self
        modelPopup.action = nil

        // Copy checkbox.
        copyCheckbox.target = self

        // Save button.
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        // Rows.
        let providerRow = labeledRow("Provider", providerPopup)
        let keyRow = labeledRow("API Key", stackHorizontally([keyField, getKeyButton]))
        let modelRow = labeledRow("Model", modelPopup)

        let stack = NSStackView(views: [providerRow, keyRow, modelRow, copyCheckbox, saveButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            keyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            providerPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            modelPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 280)
        ])
    }

    /// A label + control laid out horizontally with a fixed-width caption.
    private func labeledRow(_ caption: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: caption)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = Palette.text
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12
        return row
    }

    private func stackHorizontally(_ views: [NSView]) -> NSView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    // MARK: State

    private var selectedProviderId: String {
        providerPopup.selectedItem?.representedObject as? String ?? Settings.shared.providerId
    }

    private func loadFromSettings() {
        let settings = Settings.shared
        // Select the saved provider.
        let id = settings.providerId
        if let index = providerPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == id }) {
            providerPopup.selectItem(at: index)
        }
        rebuildModelPopup(for: id, selecting: settings.model)
        keyField.stringValue = settings.apiKey(for: id) ?? ""
        copyCheckbox.state = settings.autoCopyAnswer ? .on : .off
    }

    /// Repopulate the model popup for a provider; blank first entry = use default.
    private func rebuildModelPopup(for providerId: String, selecting model: String) {
        modelPopup.removeAllItems()
        modelPopup.addItem(withTitle: "(default)")
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

    private var selectedModel: String {
        modelPopup.selectedItem?.representedObject as? String ?? ""
    }

    // MARK: Actions

    @objc private func providerChanged() {
        let id = selectedProviderId
        rebuildModelPopup(for: id, selecting: "")
        // Show whatever key is already stored for the newly selected provider.
        keyField.stringValue = Settings.shared.apiKey(for: id) ?? ""
    }

    @objc private func getKeyTapped() {
        guard let info = Providers.info(selectedProviderId),
              let url = URL(string: info.keyURL) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func saveTapped() {
        let settings = Settings.shared
        let id = selectedProviderId
        settings.providerId = id
        settings.model = selectedModel
        settings.autoCopyAnswer = (copyCheckbox.state == .on)
        settings.setAPIKey(keyField.stringValue, for: id)
        window.orderOut(nil)
    }

    // MARK: Public API

    /// Center the window and bring it forward, activating the app.
    func show() {
        window.center()
        loadFromSettings()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
