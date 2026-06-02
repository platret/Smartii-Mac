import Cocoa
import ScreenCaptureKit
import CoreGraphics
import UniformTypeIdentifiers

/// Captures the screen via ScreenCaptureKit. Requires the Screen Recording
/// permission (granted at runtime via TCC the first time capture is attempted).
enum Screenshot {
    /// Capture the main display and return it as a PNG data URL
    /// ("data:image/png;base64,..."), or nil on any failure.
    static func captureMainDisplay() async -> String? {
        guard #available(macOS 14.0, *) else { return nil }

        // Enumerate shareable content; this triggers the TCC permission prompt.
        guard let content = try? await SCShareableContent.current,
              let display = content.displays.first else {
            return nil
        }

        // Filter: the whole display, excluding nothing.
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Configure output at the display's native pixel dimensions.
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.scalesToFit = false
        config.showsCursor = false

        // Capture a single image.
        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        ) else {
            return nil
        }

        // CGImage -> PNG data via NSBitmapImageRep.
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let base64 = pngData.base64EncodedString()
        return "data:image/png;base64," + base64
    }

    /// Show an interactive region-selection overlay, then capture just the
    /// chosen rectangle. Returns a PNG data URL ("data:image/png;base64,..."),
    /// or nil if the user cancelled (Esc / click without dragging) or on any
    /// capture failure.
    static func captureRegion() async -> String? {
        guard #available(macOS 14.0, *) else { return nil }

        // Ask the user to drag out a rectangle. The result is in global
        // (bottom-left origin) screen coordinates, on the screen it was drawn.
        guard let selection = await MainActor.run(body: { RegionSelectOverlay() }).present() else {
            return nil
        }

        let rect = selection.rect
        let screen = selection.screen
        guard rect.width >= 1, rect.height >= 1 else { return nil }

        // Find the SCDisplay matching the NSScreen the selection was made on.
        guard let content = try? await SCShareableContent.current else { return nil }
        let displayID = screen.displayID
        guard let display = content.displays.first(where: { $0.displayID == displayID })
                ?? content.displays.first else {
            return nil
        }

        // Capture the full display at native pixel resolution.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.scalesToFit = false
        config.showsCursor = false

        guard let fullImage = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        ) else {
            return nil
        }

        // The selection rect is in points with a bottom-left origin relative to
        // the global coordinate space. Convert it into a top-left-origin pixel
        // rect within this display's bounds, accounting for backing scale.
        let scale = screen.backingScaleFactor
        let displayFrame = screen.frame   // global, bottom-left origin, in points

        // Rect relative to the display origin (still bottom-left origin).
        let relX = rect.origin.x - displayFrame.origin.x
        let relYBottom = rect.origin.y - displayFrame.origin.y

        // Flip Y to a top-left origin within the display.
        let relYTop = displayFrame.height - (relYBottom + rect.height)

        // Convert to pixels.
        var cropRect = CGRect(
            x: (relX * scale).rounded(.down),
            y: (relYTop * scale).rounded(.down),
            width: (rect.width * scale).rounded(.toNearestOrAwayFromZero),
            height: (rect.height * scale).rounded(.toNearestOrAwayFromZero)
        )

        // Clamp to the captured image bounds so cropping never fails.
        let imageBounds = CGRect(x: 0, y: 0, width: fullImage.width, height: fullImage.height)
        cropRect = cropRect.intersection(imageBounds)
        guard !cropRect.isNull, cropRect.width >= 1, cropRect.height >= 1,
              let cropped = fullImage.cropping(to: cropRect) else {
            return nil
        }

        // CGImage -> PNG data via NSBitmapImageRep.
        let bitmap = NSBitmapImageRep(cgImage: cropped)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let base64 = pngData.base64EncodedString()
        return "data:image/png;base64," + base64
    }
}

extension NSScreen {
    /// The CoreGraphics display ID for this screen (used to match SCDisplay).
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
}
