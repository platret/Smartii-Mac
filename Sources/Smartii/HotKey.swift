import Cocoa
import Carbon.HIToolbox

/// Registers global (system-wide) hotkeys via Carbon's RegisterEventHotKey.
///
/// The Carbon C event callback cannot capture Swift context, so it dispatches
/// by looking up the matching handler on `HotKeyManager.shared` using the
/// `EventHotKeyID.id`. Each registered hotkey is assigned a unique, incrementing
/// id and a unique four-char signature OSType.
final class HotKeyManager {
    static let shared = HotKeyManager()

    /// A single registered hotkey: its Carbon ref and the closure to run.
    private struct Entry {
        let ref: EventHotKeyRef
        let handler: () -> Void
    }

    /// Map of hotkey id -> entry. Keeps EventHotKeyRefs retained.
    private var entries: [UInt32: Entry] = [:]

    /// Monotonically increasing id used for the next registration.
    private var nextID: UInt32 = 1

    /// Four-char signature ('SMTI') shared by all of our hotkeys.
    private let signature: OSType = {
        // 'S','M','T','I' packed big-endian into a UInt32.
        let chars: [UInt32] = [0x53, 0x4D, 0x54, 0x49] // S M T I
        return (chars[0] << 24) | (chars[1] << 16) | (chars[2] << 8) | chars[3]
    }()

    /// Whether the global InstallEventHandler has been installed yet.
    private var handlerInstalled = false

    private init() {}

    /// Register a system-wide hotkey for `keyCode` + Carbon `modifiers`.
    /// `handler` is always invoked on the main thread.
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        installEventHandlerIfNeeded()

        let id = nextID
        nextID += 1

        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            NSLog("HotKeyManager: failed to register hotkey (status \(status))")
            return
        }

        entries[id] = Entry(ref: ref, handler: handler)
    }

    /// Invoked by the C callback; runs the matching handler on the main thread.
    fileprivate func handle(id: UInt32) {
        guard let entry = entries[id] else { return }
        DispatchQueue.main.async {
            entry.handler()
        }
    }

    /// Install the one shared Carbon event handler for kEventHotKeyPressed.
    private func installEventHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            nil,
            nil
        )
    }
}

/// C-compatible Carbon event handler. Extracts the EventHotKeyID and forwards
/// to the shared manager. Must be a free function / non-capturing closure.
private func hotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    guard status == noErr else { return status }

    HotKeyManager.shared.handle(id: hotKeyID.id)
    return noErr
}
