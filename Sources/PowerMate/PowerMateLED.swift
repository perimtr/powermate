import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

/// Hardware breathing rate. The device takes an operation (0 divide, 1
/// normal, 2 multiply) and a strength argument; per the protocol notes only
/// arguments near 255 change the rate dramatically, so the presets use 224.
enum PulseSpeed: String, CaseIterable {
    case slow
    case normal
    case fast

    var title: String {
        switch self {
        case .slow: return "Slow"
        case .normal: return "Normal"
        case .fast: return "Fast"
        }
    }

    /// wIndex payload: (argument << 8) | operation.
    var argument: UInt16 {
        switch self {
        case .slow: return (224 << 8) | 0
        case .normal: return 0x0001
        case .fast: return (224 << 8) | 2
        }
    }
}

/// Hardware breathing waveform. The firmware holds three brightness tables,
/// selected by the high byte of wValue in the pulse-mode request.
enum PulseWaveform: String, CaseIterable {
    case tableA
    case tableB
    case tableC

    var title: String {
        switch self {
        case .tableA: return "Waveform A"
        case .tableB: return "Waveform B"
        case .tableC: return "Waveform C"
        }
    }

    /// The firmware table index (0-2), packed into the high byte of wValue.
    var table: UInt16 {
        switch self {
        case .tableA: return 0
        case .tableB: return 1
        case .tableC: return 2
        }
    }
}

/// Drives the PowerMate's blue LED with the same vendor control request the
/// Linux kernel driver uses: bmRequestType 0x41, bRequest 0x01,
/// wValue = command, wIndex = argument, no data stage.
final class PowerMateLED {
    private static let setStaticBrightnessCommand: UInt16 = 0x01
    private static let setPulseAsleepCommand: UInt16 = 0x02
    private static let setPulseAwakeCommand: UInt16 = 0x03
    private static let setPulseModeCommand: UInt16 = 0x04

    private var loggedSuccess = false

    // CFUUID constants from IOCFPlugIn.h / IOUSBLib.h - the C macros that
    // define them don't import into Swift, so they're spelled out here.
    private static let pluginInterfaceUUID = CFUUIDGetConstantUUIDWithBytes(nil,
        0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
        0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
    private static let usbDeviceUserClientUUID = CFUUIDGetConstantUUIDWithBytes(nil,
        0x9D, 0xC7, 0xB7, 0x80, 0x9E, 0xC0, 0x11, 0xD4,
        0xA5, 0x4F, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)
    private static let usbDeviceInterfaceUUID = CFUUIDGetConstantUUIDWithBytes(nil,
        0x5C, 0x81, 0x87, 0xD0, 0x9E, 0xF3, 0x11, 0xD4,
        0x8B, 0x45, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)

    private typealias DeviceInterfacePtr = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>
    private var dev: DeviceInterfacePtr?
    private var opened = false

    /// Finds the IOUSBHostDevice above the HID service and creates a user-space
    /// USB device interface for it, so control requests can be sent on the
    /// default pipe alongside the system HID driver.
    init?(hidDevice: IOHIDDevice) {
        let hidService = IOHIDDeviceGetService(hidDevice)
        guard hidService != 0,
              let usbService = Self.usbDeviceService(above: hidService)
        else { return nil }
        defer { IOObjectRelease(usbService) }

        var pluginPtr: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let kr = IOCreatePlugInInterfaceForService(
            usbService, Self.usbDeviceUserClientUUID, Self.pluginInterfaceUUID, &pluginPtr, &score)
        guard kr == KERN_SUCCESS, let plugin = pluginPtr, let pluginIntf = plugin.pointee?.pointee
        else { return nil }
        defer { _ = pluginIntf.Release(UnsafeMutableRawPointer(plugin)) }

        var raw: UnsafeMutableRawPointer?
        let hr = pluginIntf.QueryInterface(
            UnsafeMutableRawPointer(plugin),
            CFUUIDGetUUIDBytes(Self.usbDeviceInterfaceUUID), &raw)
        guard hr == 0, let raw else { return nil }
        dev = raw.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface>?.self)
    }

    @discardableResult
    func setBrightness(_ brightness: UInt8) -> Bool {
        send(command: Self.setStaticBrightnessCommand, argument: UInt16(brightness))
    }

    /// Whether the LED pulses while the host is suspended (the factory default
    /// is on - the classic sleep throb). Off means the LED goes dark when the
    /// Mac sleeps. The device remembers this until power-cycled.
    @discardableResult
    func setPulseAsleep(_ pulsing: Bool) -> Bool {
        send(command: Self.setPulseAsleepCommand, argument: pulsing ? 1 : 0)
    }

    /// Start or stop the hardware breathing effect while the host is awake.
    /// Configure the rate with setPulseNormalSpeed() first; the device then
    /// pulses on its own until told to stop.
    @discardableResult
    func setPulsing(_ pulsing: Bool) -> Bool {
        send(command: Self.setPulseAwakeCommand, argument: pulsing ? 1 : 0)
    }

    /// Select the breathing waveform and rate in one request. Packing (from
    /// the Linux driver): wValue = (waveform table << 8) | command,
    /// wIndex = (arg << 8) | op. The op/arg pairs live in PulseSpeed.
    @discardableResult
    func setPulseMode(speed: PulseSpeed, waveform: PulseWaveform) -> Bool {
        send(command: (waveform.table << 8) | Self.setPulseModeCommand,
             argument: speed.argument)
    }

    /// Soft power-cycle: forces the device to drop off the bus and
    /// re-publish, the only known cure for the stuck activity wedge
    /// (AGENTS.md, hard-won knowledge item 7). The app reconnects through
    /// normal hot-plug matching afterwards.
    @discardableResult
    func reenumerate() -> Bool {
        guard let dev, let intf = dev.pointee?.pointee else { return false }
        let me = UnsafeMutableRawPointer(dev)
        if !opened, intf.USBDeviceOpen(me) == kIOReturnSuccess {
            opened = true
        }
        return intf.USBDeviceReEnumerate(me, 0) == kIOReturnSuccess
    }

    @discardableResult
    private func send(command: UInt16, argument: UInt16) -> Bool {
        guard let dev, let intf = dev.pointee?.pointee else { return false }
        let me = UnsafeMutableRawPointer(dev)
        if !opened, intf.USBDeviceOpen(me) == kIOReturnSuccess {
            opened = true
        }
        var request = IOUSBDevRequest(
            bmRequestType: 0x41,  // vendor request, interface recipient, host-to-device
            bRequest: 0x01,
            wValue: command,
            wIndex: argument,
            wLength: 0,
            pData: nil,
            wLenDone: 0)
        let result = intf.DeviceRequest(me, &request)
        if result == kIOReturnSuccess {
            if !loggedSuccess {
                loggedSuccess = true
                logger.info("LED control active")
            }
            return true
        }
        logger.error("LED control request failed: \(result, privacy: .public)")
        return false
    }

    private static func usbDeviceService(above hidService: io_service_t) -> io_service_t? {
        var current: io_object_t = hidService
        IOObjectRetain(current)
        while current != 0 {
            if IOObjectConformsTo(current, "IOUSBHostDevice") != 0
                || IOObjectConformsTo(current, "IOUSBDevice") != 0 {
                return current  // retained; caller releases
            }
            var parent: io_object_t = 0
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            guard kr == KERN_SUCCESS else { return nil }
            current = parent
        }
        return nil
    }

    deinit {
        if let dev, let intf = dev.pointee?.pointee {
            let me = UnsafeMutableRawPointer(dev)
            if opened { _ = intf.USBDeviceClose(me) }
            _ = intf.Release(me)
        }
    }
}
