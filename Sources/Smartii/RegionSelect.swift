import Cocoa

// MARK: - Region selection overlay

/// A borderless, transparent, full-screen overlay (one window per screen) that
/// lets the user drag out a rectangle. The dim backdrop darkens everything; the
/// chosen area is shown as a clear cut-out framed by a violet selection
/// rectangle. On mouse-up the chosen rect is returned in global (bottom-left
/// origin) screen coordinates, together with the screen it was drawn on, via an
/// async continuation. Esc — or a click without a drag — cancels (returns nil).
@MainActor
final class RegionSelectOverlay {

    /// The result of a successful selection.
    struct Selection {
        /// The chosen rectangle in global screen coordinates (points, bottom-left origin).
        let rect: NSRect
        /// The screen the rectangle was drawn on.
        let screen: NSScreen
    }

    private var windows: [OverlayWindow] = []
    private var continuation: CheckedContinuation<Selection?, Never>?
    private var didFinish = false

    init() {}

    /// Present the overlay and await the user's selection (or nil if cancelled).
    func present() async -> Selection? {
        await withCheckedContinuation { (cont: CheckedContinuation<Selection?, Never>) in
            self.continuation = cont
            self.show()
        }
    }

    // MARK: Setup

    private func show() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            finish(with: nil)
            return
        }

        for screen in screens {
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.setFrame(screen.frame, display: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .screenSaver
            window.ignoresMouseEvents = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

            let view = RegionSelectView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.screen = screen
            view.onCommit = { [weak self] rect, screen in
                self?.finish(with: Selection(rect: rect, screen: screen))
            }
            view.onCancel = { [weak self] in
                self?.finish(with: nil)
            }
            window.contentView = view
            windows.append(window)
        }

        // Bring the app forward so the overlay can take key/mouse focus, then
        // make the overlay on the screen with the mouse the key window.
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        let keyWindow = windows.first(where: { $0.frame.contains(mouse) }) ?? windows.first
        for window in windows {
            window.orderFrontRegardless()
        }
        keyWindow?.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.set()
    }

    // MARK: Teardown

    private func finish(with selection: Selection?) {
        guard !didFinish else { return }
        didFinish = true
        NSCursor.arrow.set()
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        let cont = continuation
        continuation = nil
        cont?.resume(returning: selection)
    }
}

// MARK: - Overlay window

/// Borderless overlay window that can still become key so it receives Esc and
/// mouse events even though the app is a menu-bar (accessory) app.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Selection view

/// Draws the dim backdrop, the clear selection cut-out, and the violet frame as
/// the user drags. Reports the result in *global* screen coordinates.
private final class RegionSelectView: NSView {

    /// Called on a successful drag, with the rect in global screen coords.
    var onCommit: ((NSRect, NSScreen) -> Void)?
    /// Called on Esc or a click without a drag.
    var onCancel: (() -> Void)?
    /// The screen this view's window covers (set by the overlay).
    var screen: NSScreen?

    /// Drag anchor and current point, in this view's local coordinates.
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var isDragging = false

    /// Minimum drag distance (points) before we treat it as a real selection.
    private let dragThreshold: CGFloat = 4

    private let accent = NSColor(srgbRed: 0x7c / 255, green: 0x5c / 255, blue: 0xff / 255, alpha: 1)

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Dim the whole screen.
        NSColor(white: 0, alpha: 0.32).setFill()
        bounds.fill()

        guard let sel = localSelectionRect(), sel.width >= 1, sel.height >= 1 else { return }

        // Clear the selected region so it reads at full brightness.
        NSColor.clear.set()
        let blend = NSGraphicsContext.current?.compositingOperation
        NSGraphicsContext.current?.compositingOperation = .clear
        sel.fill()
        if let blend { NSGraphicsContext.current?.compositingOperation = blend }

        // Subtle violet wash inside the selection.
        accent.withAlphaComponent(0.12).setFill()
        sel.fill()

        // Violet frame.
        let border = NSBezierPath(rect: sel.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1.5
        accent.setStroke()
        border.stroke()

        // Dimensions label near the bottom-left of the selection.
        let dims = "\(Int(sel.width.rounded())) × \(Int(sel.height.rounded()))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(white: 0.97, alpha: 1)
        ]
        let textSize = (dims as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 5
        var labelOrigin = NSPoint(x: sel.minX, y: sel.minY - textSize.height - 2 * pad - 4)
        if labelOrigin.y < 4 { labelOrigin.y = sel.minY + 4 }   // keep on-screen
        let labelRect = NSRect(
            x: labelOrigin.x,
            y: labelOrigin.y,
            width: textSize.width + 2 * pad,
            height: textSize.height + 2 * pad
        )
        let bg = NSBezierPath(roundedRect: labelRect, xRadius: 5, yRadius: 5)
        NSColor(white: 0, alpha: 0.55).setFill()
        bg.fill()
        (dims as NSString).draw(
            at: NSPoint(x: labelRect.minX + pad, y: labelRect.minY + pad),
            withAttributes: attrs
        )
    }

    /// The current selection rect in this view's local coordinates.
    private func localSelectionRect() -> NSRect? {
        guard let start = startPoint, let cur = currentPoint else { return nil }
        return NSRect(
            x: min(start.x, cur.x),
            y: min(start.y, cur.y),
            width: abs(cur.x - start.x),
            height: abs(cur.y - start.y)
        )
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        startPoint = p
        currentPoint = p
        isDragging = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        currentPoint = p
        if let start = startPoint,
           abs(p.x - start.x) >= dragThreshold || abs(p.y - start.y) >= dragThreshold {
            isDragging = true
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { startPoint = nil; currentPoint = nil; isDragging = false }

        guard isDragging, let sel = localSelectionRect(),
              sel.width >= 1, sel.height >= 1, let screen = screen else {
            // A plain click (no drag) cancels.
            onCancel?()
            return
        }

        // Convert the local rect to global screen coordinates. The window covers
        // the screen exactly, so adding the screen frame origin maps local
        // (bottom-left) points to the global (bottom-left) space.
        let origin = screen.frame.origin
        let global = NSRect(
            x: sel.origin.x + origin.x,
            y: sel.origin.y + origin.y,
            width: sel.width,
            height: sel.height
        )
        onCommit?(global, screen)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        // Esc (key code 53) cancels.
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        // Handles Esc routed through the responder chain.
        onCancel?()
    }
}
