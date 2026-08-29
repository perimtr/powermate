import Foundation

/// Turns raw button and rotation events from any control surface into the
/// app's gestures: click, double-click, long press, and press-and-turn.
///
/// The knob is only one way to produce those events, so this holds the
/// timing that everything downstream depends on. PowerMateHID still has
/// its own copy of this logic; it should adopt this class once a second
/// input source graduates from prototype, which would leave the HID file
/// doing nothing but parsing reports.
///
/// Call the inputs on the main thread: the timers, and every handler the
/// app hangs off these callbacks, expect it.
final class KnobGestures {
    /// Rotation with the button up; positive is clockwise.
    var onRotate: ((Int) -> Void)?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onLongPress: (() -> Void)?
    /// One step of rotate-while-pressed; +1 clockwise, -1 counter-clockwise.
    var onPressedRotate: ((Int) -> Void)?

    /// When false, clicks fire immediately instead of waiting out the
    /// double-click window.
    var doubleClickEnabled = true

    /// Hold this long without rotating and the long-press action fires.
    private static let longPressDelay: TimeInterval = 0.5
    /// Second click within this window makes a double-click.
    private static let doubleClickWindow: TimeInterval = 0.35
    /// Rotation counts per press-and-turn step.
    private static let pressedTurnChunk = 5

    private var buttonIsDown = false
    private var rotatedWhileDown = false
    private var longPressFired = false
    private var longPressTimer: Timer?
    private var pendingClickTimer: Timer?
    private var pressedRotationAccum = 0

    func rotated(_ delta: Int) {
        guard delta != 0 else { return }
        if buttonIsDown {
            if !rotatedWhileDown {
                rotatedWhileDown = true
                longPressTimer?.invalidate()
            }
            pressedRotationAccum += delta
            while pressedRotationAccum >= Self.pressedTurnChunk {
                pressedRotationAccum -= Self.pressedTurnChunk
                onPressedRotate?(1)
            }
            while pressedRotationAccum <= -Self.pressedTurnChunk {
                pressedRotationAccum += Self.pressedTurnChunk
                onPressedRotate?(-1)
            }
        } else {
            onRotate?(delta)
        }
    }

    func buttonChanged(pressed: Bool) {
        guard pressed != buttonIsDown else { return }
        buttonIsDown = pressed
        if pressed {
            buttonWentDown()
        } else {
            buttonWentUp()
        }
    }

    /// Drop any pending timers, for when the source disconnects mid-gesture.
    func reset() {
        longPressTimer?.invalidate()
        pendingClickTimer?.invalidate()
        longPressTimer = nil
        pendingClickTimer = nil
        buttonIsDown = false
        rotatedWhileDown = false
        longPressFired = false
        pressedRotationAccum = 0
    }

    private func buttonWentDown() {
        rotatedWhileDown = false
        longPressFired = false
        pressedRotationAccum = 0
        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(
            withTimeInterval: Self.longPressDelay, repeats: false
        ) { [weak self] _ in
            guard let self, self.buttonIsDown, !self.rotatedWhileDown else { return }
            self.longPressFired = true
            self.onLongPress?()
        }
    }

    private func buttonWentUp() {
        longPressTimer?.invalidate()
        guard !rotatedWhileDown, !longPressFired else { return }

        if pendingClickTimer != nil {
            pendingClickTimer?.invalidate()
            pendingClickTimer = nil
            onDoubleClick?()
        } else if doubleClickEnabled {
            pendingClickTimer = Timer.scheduledTimer(
                withTimeInterval: Self.doubleClickWindow, repeats: false
            ) { [weak self] _ in
                self?.pendingClickTimer = nil
                self?.onClick?()
            }
        } else {
            onClick?()
        }
    }
}
