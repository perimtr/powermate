# Privacy

How the PowerMate app handles your information: it doesn't.

PowerMate runs entirely on your Mac. It has no server side, no accounts,
and no analytics. Its one network feature is the optional update check,
described in full below; nothing else ever goes on the wire.

## Data We Do NOT Collect

- No personal information
- No usage analytics or telemetry
- No crash reporting
- No location data
- No device identifiers
- No advertising trackers

## The Update Check

- The app can ask GitHub for the number of the newest release: a single
  anonymous HTTPS request to api.github.com for public release
  metadata, the same information anyone sees on the releases page
- The request carries no identifiers, no account, and no payload. Like
  any web request, GitHub's servers necessarily see the network address
  it came from; nothing else about you or your Mac is included
- Automatic checks run at most once a day while the app is running, and
  only while "Check for Updates Automatically" is enabled in the menu;
  turn it off and the manual "Check for Updates" item is the only
  trigger
- Nothing downloads or installs by itself. When a newer version exists,
  the menu offers to open the release page in your browser

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

The complete source code is in this repository. All of the app's network
code is one small file, Sources/PowerMate/UpdateChecker.swift: a single
HTTPS GET for release metadata. There are no other URL sessions, no
sockets, and no analytics SDKs, which can be checked directly in the
source.

Questions: use the contact form at https://perimtr.io.
