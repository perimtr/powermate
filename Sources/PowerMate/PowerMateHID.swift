import Foundation
import IOKit
import IOKit.hid

/// Talks to the Griffin PowerMate USB knob (vendor 0x077D, product 0x0410) via
/// the IOKit HID Manager. Reports arrive as raw input reports whose layout is
/// known from the Linux kernel driver (drivers/input/misc/powermate.c):
///   byte 0, bit 0 - button state
///   byte 1        - signed rotation delta since the last report
final class PowerMateHID {
    static let vendorID = 0x077D
    static let productID = 0x0410

    /// kIOReturnNotPermitted - the C macro doesn't import into Swift.
    private static let notPermitted = IOReturn(bitPattern: 0xE00002E2)

    var onConnect: ((IOHIDDevice) -> Void)?
    var onDisconnect: (() -> Void)?
    /// Rotation delta; positive = clockwise. Magnitude grows when spun fast.
    var onRotate: ((Int) -> Void)? {
        get { gestures.onRotate } set { gestures.onRotate = newValue }
    }
    /// Button released quickly with no rotation (fires after the double-click
    /// window when double-click is enabled).
    var onClick: (() -> Void)? {
        get { gestures.onClick } set { gestures.onClick = newValue }
    }
    var onDoubleClick: (() -> Void)? {
        get { gestures.onDoubleClick } set { gestures.onDoubleClick = newValue }
    }
    /// Button held without rotation; fires at the long-press threshold.
    var onLongPress: (() -> Void)? {
        get { gestures.onLongPress } set { gestures.onLongPress = newValue }
    }
    /// One step of rotate-while-pressed; argument is +1 (clockwise) or -1.
    var onPressedRotate: ((Int) -> Void)? {
        get { gestures.onPressedRotate } set { gestures.onPressedRotate = newValue }
    }
    var onPermissionDenied: (() -> Void)?

    /// When false, clicks fire immediately instead of waiting out the
    /// double-click window. Set by the app when no double-click action is bound.
    var doubleClickEnabled: Bool {
        get { gestures.doubleClickEnabled } set { gestures.doubleClickEnabled = newValue }
    }

    /// The gesture timing lives in KnobGestures so the knob and any other
    /// input source produce identical clicks, double-clicks, long presses
    /// and press-and-turn steps. This file is now only the HID half:
    /// matching, seizing, and parsing reports.
    private let gestures = KnobGestures()

    private(set) var device: IOHIDDevice?
    /// True when the device was opened with exclusive access (seized), which
    /// detaches it from the system's event stack.
    private(set) var seized = false
    /// Held aside while the device is closed for display sleep.
    private var releasedDevice: IOHIDDevice?
    /// While true, newly matched devices are noted but not opened: closing a
    /// seized device makes the HID system re-publish it, which would
    /// otherwise re-trigger our own matching callback and instantly undo the
    /// release.
    private var displaySleeping = false
    private var manager: IOHIDManager?
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    func start() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let matching: [String: Any] = [
            kIOHIDVendorIDKey: Self.vendorID,
            kIOHIDProductIDKey: Self.productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<PowerMateHID>.fromOpaque(context!).takeUnretainedValue().deviceMatched(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<PowerMateHID>.fromOpaque(context!).takeUnretainedValue().deviceRemoved(device)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result == Self.notPermitted {
            onPermissionDenied?()
        } else if result != kIOReturnSuccess {
            logger.error("IOHIDManagerOpen failed: \(result, privacy: .public)")
        }
    }

    private func deviceMatched(_ device: IOHIDDevice) {
        guard self.device == nil else { return }
        if displaySleeping {
            releasedDevice = device  // note it for wake; keep it closed for now
            return
        }
        releasedDevice = nil  // a fresh match supersedes any released device

        // Seize the device so its reports stop reaching the system event
        // stack. The PowerMate enumerates as a consumer-control device, and
        // macOS treats every report it emits - including LED-state echoes and
        // electrical noise - as user activity, which keeps the display awake.
        // Seized, only this app sees the reports; AppDelegate re-declares
        // user activity explicitly for genuine gestures.
        var openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if openResult == kIOReturnSuccess {
            seized = true
            logger.info("Device seized - system no longer sees knob events")
        } else if openResult != Self.notPermitted {
            seized = false
            logger.error("Seize failed (\(openResult, privacy: .public)); using shared open")
            openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if openResult == Self.notPermitted {
            logger.error("HID device open not permitted - Input Monitoring access needed")
            onPermissionDenied?()
            return
        }

        self.device = device
        gestures.reset()

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 64, { context, _, _, _, _, report, length in
            Unmanaged<PowerMateHID>.fromOpaque(context!).takeUnretainedValue().handleReport(report, length: length)
        }, context)

        logger.info("PowerMate connected")
        onConnect?(device)
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        if let released = releasedDevice, CFEqual(released, device) {
            releasedDevice = nil  // unplugged while released for display sleep
            return
        }
        guard let current = self.device, CFEqual(current, device) else { return }
        self.device = nil
        logger.info("PowerMate disconnected")
        onDisconnect?()
    }

    /// Closes the device so it can suspend on the USB bus. An open client
    /// keeps the device active, and the kernel holds a USB assertion for
    /// active external devices that blocks system idle sleep. While released,
    /// the system event service reattaches - so physically touching the knob
    /// wakes the display, after which the app re-seizes the device.
    func releaseForDisplaySleep() {
        displaySleeping = true
        guard let device else { return }
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        releasedDevice = device
        self.device = nil
        seized = false
        // Drop any half-finished gesture rather than letting a timer fire
        // against a device that is no longer open.
        gestures.reset()
        logger.info("Device released so it can suspend (display asleep)")
        onDisconnect?()
    }

    func reacquireAfterDisplayWake() {
        displaySleeping = false
        guard device == nil, let released = releasedDevice else { return }
        releasedDevice = nil
        deviceMatched(released)
    }

    private func handleReport(_ report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard length >= 2 else { return }
        let pressed = report[0] & 0x01 != 0
        let delta = Int(Int8(bitPattern: report[1]))
        // Info level, not debug: macOS 26 never surfaces this process's
        // debug-level messages in log stream, and these lines are the only
        // view into what the knob sends. Bytes 2+ echo LED state when the
        // report carries them.
        let echo = (2..<length).map { String(format: "%02x", report[$0]) }.joined()
        logger.info("report btn=\(report[0], privacy: .public) delta=\(delta, privacy: .public) echo=\(echo, privacy: .public)")

        // Rotation before the button, so a turn that begins in the same
        // report as a press is still read as press-and-turn.
        gestures.rotated(delta)
        gestures.buttonChanged(pressed: pressed)
    }

    deinit {
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        reportBuffer.deallocate()
    }
}
