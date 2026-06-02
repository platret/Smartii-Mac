import Cocoa

/// Subtle UI sound effects, gated behind `Settings.shared.soundsEnabled`.
///
/// Uses named system sounds (`NSSound(named:)`) which resolve to the system's
/// `.aiff` files in `/System/Library/Sounds`. All playback is optional and
/// best-effort: if a sound can't be found or `soundsEnabled` is false, nothing
/// happens. Sounds are pre-loaded once and reused so playback is allocation-free
/// on the hot path.
enum Sound {
    /// A light click for when the user sends a message.
    private static let sendSound = NSSound(named: "Tink")
    /// A gentle pop for when a response arrives.
    private static let receiveSound = NSSound(named: "Pop")

    /// Play the "send" cue (only if sounds are enabled in Settings).
    static func send() {
        play(sendSound)
    }

    /// Play the "receive" cue (only if sounds are enabled in Settings).
    static func receive() {
        play(receiveSound)
    }

    /// Restart and play a pre-loaded sound, if present and enabled.
    private static func play(_ sound: NSSound?) {
        guard Settings.shared.soundsEnabled, let sound else { return }
        // Rewind so rapid repeated cues always retrigger from the start.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
