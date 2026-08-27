// pmled: standalone Griffin PowerMate USB probe. Not part of the app.
//
// Sends raw LED vendor control requests (bmRequestType 0x41, bRequest
// 0x01) straight to the device, and can re-enumerate it to clear the
// stuck activity wedge (AGENTS.md, hard-won knowledge item 7) without
// replugging. Needs no permissions. Quit PowerMate.app first: the app
// holds the USB device open, and this tool needs its own open.
//
// Build and run:
//   swiftc -O Support/pmled.swift -o /tmp/pmled
//   /tmp/pmled reenumerate                  # reset the device
//   /tmp/pmled 0x0001 0x0040                # static brightness 64
//   /tmp/pmled 0x0003 0x0000                # pulse-while-awake off
//   /tmp/pmled 0x0104 0x0001 0x0003 0x0001  # table B normal pulse, on
//
// Arguments are wValue wIndex pairs in hex: wValue = (table << 8) |
// command, wIndex = argument (see AGENTS.md, device protocol).

import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

let pluginUUID = CFUUIDGetConstantUUIDWithBytes(nil,
    0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
    0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
let userClientUUID = CFUUIDGetConstantUUIDWithBytes(nil,
    0x9D, 0xC7, 0xB7, 0x80, 0x9E, 0xC0, 0x11, 0xD4,
    0xA5, 0x4F, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)
let deviceUUID = CFUUIDGetConstantUUIDWithBytes(nil,
    0x5C, 0x81, 0x87, 0xD0, 0x9E, 0xF3, 0x11, 0xD4,
    0x8B, 0x45, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)

func findPowerMate() -> io_service_t {
    let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
    matching["idVendor"] = 0x077D
    matching["idProduct"] = 0x0410
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
    else { return 0 }
    defer { IOObjectRelease(iterator) }
    return IOIteratorNext(iterator)
}

let service = findPowerMate()
guard service != 0 else { print("no PowerMate USB device found"); exit(1) }
defer { IOObjectRelease(service) }

var pluginPtr: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
var score: Int32 = 0
guard IOCreatePlugInInterfaceForService(
    service, userClientUUID, pluginUUID, &pluginPtr, &score) == KERN_SUCCESS,
    let plugin = pluginPtr, let pluginIntf = plugin.pointee?.pointee
else { print("plugin interface failed"); exit(1) }
defer { _ = pluginIntf.Release(UnsafeMutableRawPointer(plugin)) }

var raw: UnsafeMutableRawPointer?
guard pluginIntf.QueryInterface(UnsafeMutableRawPointer(plugin),
                                CFUUIDGetUUIDBytes(deviceUUID), &raw) == 0, let raw
else { print("device interface failed"); exit(1) }
let dev = raw.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface>?.self)
guard let intf = dev.pointee?.pointee else { print("no interface"); exit(1) }
let me = UnsafeMutableRawPointer(dev)
let openResult = intf.USBDeviceOpen(me)
print("open: 0x\(String(UInt32(bitPattern: openResult), radix: 16))")

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "reenumerate" {
    let r = intf.USBDeviceReEnumerate(me, 0)
    print("reenumerate: 0x\(String(UInt32(bitPattern: r), radix: 16))")
} else if args.isEmpty || args.count % 2 != 0 {
    print("usage: pmled reenumerate | pmled <wValueHex> <wIndexHex> ...")
} else {
    var i = 0
    while i + 1 < args.count {
        let wValue = UInt16(args[i].replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
        let wIndex = UInt16(args[i + 1].replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
        var request = IOUSBDevRequest(
            bmRequestType: 0x41, bRequest: 0x01,
            wValue: wValue, wIndex: wIndex,
            wLength: 0, pData: nil, wLenDone: 0)
        let r = intf.DeviceRequest(me, &request)
        print("wValue=0x\(String(wValue, radix: 16)) wIndex=0x\(String(wIndex, radix: 16)) -> 0x\(String(UInt32(bitPattern: r), radix: 16))")
        i += 2
    }
}
if openResult == kIOReturnSuccess { _ = intf.USBDeviceClose(me) }
_ = intf.Release(me)
