import ApplicationServices
import Foundation

/// Accessibility (AX) helpers. Pure, no UI.
enum AX {
    /// Whether this process is currently trusted for the Accessibility API.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompts the user to grant Accessibility trust (opens the system dialog
    /// directing them to System Settings if not yet trusted).
    static func promptForTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Sets the value of the system-wide focused UI element to `text`.
    ///
    /// Copies `kAXFocusedUIElementAttribute` from the system-wide element, then
    /// tries to set `kAXValueAttribute`. If that fails, falls back to
    /// `kAXSelectedTextAttribute`. Returns whether either write succeeded.
    @discardableResult
    static func fillFocusedField(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var focused: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard copyResult == .success, let focusedRef = focused else { return false }

        // CFTypeRef → AXUIElement (focused UI elements are AXUIElement values).
        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return false }
        let element = focusedRef as! AXUIElement

        let value = text as CFString

        if AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value) == .success {
            return true
        }

        if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, value) == .success {
            return true
        }

        return false
    }
}
