# Privacy

How the PowerMate app handles your information: it doesn't.

PowerMate runs entirely on your Mac. It has no server side, no accounts,
and no network code of any kind. The app never phones home, never checks
for updates, and never transmits anything.

## Data We Do NOT Collect

- No personal information
- No usage analytics or telemetry
- No crash reporting
- No location data
- No device identifiers
- No advertising trackers

## What Stays on Your Mac

- All settings (gesture bindings, profiles, preferences) live in macOS
  user defaults on your Mac
- The app reads input only from the Griffin PowerMate device itself,
  which it opens exclusively; it does not observe your keyboard, mouse,
  or screen

## About the Permissions

- **Accessibility** is used only to synthesize media-key, scroll, and
  key-press events locally when you bind those actions to the knob
- **Input Monitoring**, where macOS requires it, covers only the
  PowerMate device's own reports
- **System Audio Recording** is requested only if you use the Frontmost
  App Volume mode. macOS files per-app volume control under this
  permission because the app's audio is routed through PowerMate's gain
  stage on its way to the speaker. The samples pass through one realtime
  callback and are never written anywhere, recorded, or analyzed; the
  permission is never requested if you don't use the mode
- Shortcuts bound to knob gestures run through Apple's Shortcuts app
  with the permissions you granted there

Nothing the app can see ever leaves your Mac.

## Verifying These Claims

The complete source code is in this repository. The absence of network
code can be checked directly: the app links no networking frameworks and
contains no URL sessions, sockets, or analytics SDKs.

Questions: use the contact form at https://perimtr.io.
