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
}
