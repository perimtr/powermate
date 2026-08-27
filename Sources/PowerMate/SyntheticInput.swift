import CoreGraphics

/// Synthesizes scroll-wheel and keyboard events, posted to the HID event tap
/// so they land wherever such input would naturally go (scrolling targets the
/// window under the pointer, keys go to the focused app). Requires the same
/// Accessibility trust as MediaKeys.
enum SyntheticInput {
    enum Key: CGKeyCode {
        case space = 0x31
        case leftArrow = 0x7B
        case rightArrow = 0x7C
        case downArrow = 0x7D
        case upArrow = 0x7E
    }

    /// Pixel-unit scroll; positive vertical scrolls up, positive horizontal
    /// scrolls left, matching CGEvent wheel conventions.
    static func scroll(vertical: Int32, horizontal: Int32 = 0) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
            wheel1: vertical, wheel2: horizontal, wheel3: 0)
        else { return }
        event.post(tap: .cghidEventTap)
    }

    static func press(_ key: Key, times: Int = 1) {
        for _ in 0..<max(1, times) {
            CGEvent(keyboardEventSource: nil, virtualKey: key.rawValue, keyDown: true)?
                .post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: nil, virtualKey: key.rawValue, keyDown: false)?
                .post(tap: .cghidEventTap)
        }
    }
}
