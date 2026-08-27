import AppKit
import ApplicationServices

/// Posts the same system-defined events Apple keyboards send for their media
/// keys, so play/pause and track skipping work with Music, Spotify, browsers -
/// whatever currently owns "Now Playing". Posting events requires the app to
/// be trusted under Privacy & Security → Accessibility.
enum MediaKeys {
    enum Key: Int32 {
        case playPause = 16  // NX_KEYTYPE_PLAY
        case next = 19       // NX_KEYTYPE_FAST - what keyboard next-track keys send
        case previous = 20   // NX_KEYTYPE_REWIND
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt (once per app identity).
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func post(_ key: Key) {
        postKeyEvent(key, down: true)
        postKeyEvent(key, down: false)
    }

    private static func postKeyEvent(_ key: Key, down: Bool) {
        // data1 layout for NX_SUBTYPE_AUX_CONTROL_BUTTONS (subtype 8):
        // key code in the high word, key state (0x0A down / 0x0B up) in byte 1.
        let state: Int32 = down ? 0x0A : 0x0B
        let data1 = Int((key.rawValue << 16) | (state << 8))
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1)
        else { return }
        event.cgEvent?.post(tap: .cghidEventTap)
    }
}
