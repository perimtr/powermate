// fakewedge: synthetic stuck activity wedge. Not part of the app.
//
// Declares a UserIsActive assertion named after the Griffin PowerMate and
// re-arms it five times a second so its countdown never drains, which is
// what the HID stack's phantom tickle looks like to the app's watchdog
// (AGENTS.md, hard-won knowledge item 7). Run it beside PowerMate.app
// while the knob is seized: within 2 min 15 s the app log shows "Stuck
// activity wedge detected", "PowerMate disconnected", and a clean
// re-seize. Needs no permissions and touches no hardware; the assertion
// disappears when this exits. It keeps the display awake while running.
//
// Build and run:
//   swiftc -O Support/fakewedge.swift -o /tmp/fakewedge
//   /tmp/fakewedge          # runs for 200 s
//   /tmp/fakewedge 300      # seconds to run

import Foundation
import IOKit.pwr_mgt

let seconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 200
let name = "fakewedge service:AppleUserHIDEventService product:Griffin PowerMate" as CFString
var assertionID: IOPMAssertionID = 0
let end = Date().addingTimeInterval(seconds)
print("re-arming a PowerMate-named UserIsActive assertion for \(Int(seconds)) s")
while Date() < end {
    IOPMAssertionDeclareUserActivity(name, kIOPMUserActiveLocal, &assertionID)
    Thread.sleep(forTimeInterval: 0.2)
}
IOPMAssertionRelease(assertionID)
print("released")
