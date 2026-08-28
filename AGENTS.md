# PowerMate: Project Handoff

Everything an engineer or coding agent needs to work on this project
without relearning it. Read this before changing anything.

## What this is

A zero-dependency Swift menu bar app that makes the Griffin PowerMate USB
knob (vendor 0x077D, product 0x0410) useful on modern macOS. Rotation
controls volume (system-wide or the frontmost app's alone, or scrolling,
arrow keys, or Apple Shortcuts), the button
supports click / double-click / long-press / press-and-turn gestures, all
remappable globally and per app, and the knob's blue LED is fully driven
(brightness, breathing pulse with three selectable waveforms, off during
sleep).

- Repo: https://github.com/perimtr/powermate (private until the owner
  decides to open-source it; MIT licensed either way)
- Installed app: /Applications/PowerMate.app, bundle id io.perimtr.powermate
- Local checkout: ~/Projects/powermate
- CI: .github/workflows/ci.yml builds on every push (macOS runner)

## Repository conventions (must follow)

- Commits are authored as `Perimtr LLC <noreply@perimtr.io>` (repo-local
  git config is already set). Never commit with a personal name or email.
- No AI attribution anywhere: no Co-Authored-By trailers, no "generated
  with" lines, in commits or files.
- No em-dashes anywhere: not in code comments, UI strings, README, or
  commit messages. Use hyphens, colons, parentheses, or periods.
- Copyright holder is Perimtr LLC.
- History starts at a single "Initial commit" on purpose. Do not
  resurrect older history.
- Versioning: CFBundleShortVersionString / CFBundleVersion in
  Support/Info.plist. Bump both for behavior changes.

## Architecture

Swift Package Manager executable, AppKit, no third-party dependencies.
All sources in Sources/PowerMate/:

- main.swift: NSApplication bootstrap, accessory activation policy.
- AppDelegate.swift: the hub. Menu bar UI (all menus are built or rebuilt
  in menuWillOpen), preference keys (enum Pref), gesture dispatch,
  profile pinning and cycling, LED state machine, volume HUD wiring,
  sleep/wake and display sleep observers, user activity declaration,
  the stuck-wedge watchdog, login item auto-registration, About panel.
- PowerMateHID.swift: IOHIDManager device matching, exclusive (seize)
  open, raw input report parsing, and the gesture engine (click,
  double-click window, long press timer, chunked press-and-turn).
  Also release/reacquire for display sleep.
- PowerMateLED.swift: LED control through IOUSBDeviceInterface vendor
  control requests. PulseSpeed and PulseWaveform presets live here.
- SystemAudio.swift: CoreAudio default-output volume and mute, with
  per-channel fallback and software mute when hardware mute is absent;
  output-device enumeration and default-output switching; and
  SystemAudioObserver, which follows volume/mute/device changes made
  outside the app so the LED never goes stale.
- AppVolume.swift: the Frontmost App Volume rotate mode (macOS 14.4+).
  A CoreAudio process tap on the app's audio processes (bundle id match
  plus descendants of the app's pid, so browser helpers count) mutes
  their direct path, and a private aggregate device replays the tapped
  audio through the real output with a per-sample-ramped gain applied
  in the IO callback. One engine per app, only while gain < 100%; gains
  persist in appVolumeGains and re-apply on app launch. Engines rebuild
  on default-device changes and refresh their process set when stale.
- MediaKeys.swift: media key synthesis (NSEvent systemDefined subtype 8)
  and the Accessibility trust check.
- SyntheticInput.swift: CGEvent scroll wheel and key press synthesis.
- ShortcutRunner.swift: lists and runs Apple Shortcuts via the
  /usr/bin/shortcuts CLI, off the main thread, with run coalescing.
- UpdateChecker.swift: the app's only network code. One anonymous HTTPS
  GET to the GitHub releases API for the latest tag, compared against
  CFBundleShortVersionString; automatic checks are daily, toggleable,
  and never download anything. PRIVACY.md documents the request; keep
  the two in sync.
- KnobAction.swift: action and mode enums with raw-string serialization.
- Profiles.swift: Profile struct and ProfileStore (UserDefaults-backed
  per-app profile dictionaries).
- VolumeHUD.swift: floating volume bezel (NSPanel + NSVisualEffectView).

Support/: Info.plist (bundle metadata), AppIcon.icns, make_appicon.swift
(regenerates the icon artwork), pmled.swift (standalone USB probe:
sends raw LED control requests and can re-enumerate the device to clear
the stuck activity wedge, pitfall 7). Makefile: build, app bundle
assembly, ad-hoc codesign, install. docs/icon.png: README artwork.

## The device protocol

Learned from the Linux kernel driver (drivers/input/misc/powermate.c)
and verified against real hardware:

- Input reports: byte 0 bit 0 is the button, byte 1 is a signed rotation
  delta (positive = clockwise; magnitude grows when spun fast, roughly
  96 counts per revolution). Later bytes echo LED state.
- The device emits an input report for every LED state change (echo),
  but macOS 26 does not deliver echo-only reports to userspace HID
  clients (verified with both seized and shared opens). The app
  therefore cannot observe LED state or a running pulse through
  reports, and the three pulse waveform tables cannot be characterized
  in software; judge them by eye.
- LED control is a vendor control request on the default pipe:
  bmRequestType 0x41, bRequest 0x01, wValue = command, wIndex = argument.
  Commands: 1 static brightness (arg 0-255), 2 pulse-while-asleep (0/1),
  3 pulse-while-awake (0/1), 4 pulse mode where wValue = (table << 8) | 4
  and wIndex = (arg << 8) | op, with op 0 divide / 1 normal / 2 multiply
  and only args near 255 changing the rate much.
- The autonomous pulse and all LED state survive app restarts (the
  device keeps state until power-cycled). Never trust cached flags.
- The LED is single-color blue. Brightness and pulsing are the only
  controls; color cannot change.

## Hard-won platform knowledge (do not relearn these)

1. Seize the device. The PowerMate enumerates as a consumer-control
   device (usage page 0x0C usage 0x01), so macOS parses every report,
   including LED echoes and electrical noise, as a keyboard-class event
   and counts it as user activity. A stuck pulse once kept a Mac's
   display awake indefinitely (UserIsActive assertion pinned at age 0
   naming the device). The app opens with kIOHIDOptionsTypeSeizeDevice
   so the system never sees the device, and instead declares real user
   activity itself (IOPMAssertionDeclareUserActivity) for button events
   and sustained rotation (net movement of 3 or more; alternating
   vibration jitter cancels out).
2. Force the pulse off at connect and wake. sendLED's steady branch only
   cancels pulsing when its own flag says pulsing, so a stale hardware
   pulse from a previous session would otherwise breathe (and echo)
   forever. onConnect and systemDidWake send setPulsing(false)
   unconditionally.
3. Release the device while the display sleeps. An open client keeps the
   device active on the USB bus, which can hold a kernel USB assertion
   (pmset -g assertions, kernel section) against system idle sleep. On
   screensDidSleep the app blanks the LED and closes both the HID and
   USB clients; on screensDidWake it re-seizes. Critical detail: closing
   a seized device makes the HID system re-publish it, which re-fires
   our own IOHIDManager matching callback and would instantly reopen it.
   The displaySleeping flag in PowerMateHID defers matching until wake.
   Side benefit: while released, the system sees the knob again, so
   touching it wakes the display.
4. macOS 26 menu bar gotchas: the OS can hide third-party status items
   entirely (System Settings menu bar item management; nothing app-side
   fixes it), and it renders NSImage(size:flipped:drawingHandler:)
   template images as blank in the menu bar. Status item icons must be
   SF Symbols (dial.medium.fill family) or pre-rasterized images.
5. TCC: media keys, scrolling, arrow keys, and Space synthesis need
   Accessibility trust (AXIsProcessTrusted). Volume, mute, LED, and
   Shortcuts do not. The Frontmost App Volume mode needs System Audio
   Recording approval (macOS prompts on the first tap) and, under the
   hardened runtime, the com.apple.security.device.audio-input
   entitlement, which the Makefile signs in from
   Support/PowerMate.entitlements. Developer ID builds keep a stable
   TCC identity across rebuilds; ad-hoc builds (no identity in the
   keychain) can invalidate grants on every rebuild (toggle the
   checkbox off and on). Changing the bundle id resets TCC, login
   items, and the defaults domain.
6. The knob does nothing on macOS without this app, and the pre-2019
   Griffin software does not run. Third-party remappers (USB Overdrive)
   attach at the HID event service level; if rotation ever does two
   things at once, check `hidutil list` for another owner and
   `systemextensionsctl list` for driver extensions.
7. The stuck activity wedge. The system can latch into reporting
   constant PowerMate user activity: pmset -g assertions shows a
   WindowServer UserIsActive assertion naming the Griffin PowerMate
   whose 600 s timeout never counts down, and HIDIdleTime (ioreg -c
   IOHIDSystem) stays pinned near zero with nobody at the machine, so
   the display (and system) never idle-sleeps. Meanwhile the seized
   app receives zero input reports, and no LED command clears it;
   quitting the app does not either. Only re-publishing the device
   clears it: replug, Support/pmled.swift reenumerate, or the app's
   own watchdog (below). Findings from the 2026-08-26
   investigation of nine logged episodes (2026-08-17 through 08-25):
   - Episodes cluster at sleep/wake boundaries, often inside
     sleep-wake thrash loops (the Mac sleeps, is woken seconds later,
     repeatedly; one wake in a loop was attributed "due to HID"), and
     twice coincided with app-restart windows. Short episodes can end
     on their own; long ones ran up to 24 h.
   - LED echo storms are NOT the trigger: an autonomous pulse running
     unseized for 90 s produced zero system-side activity (no
     assertion, no HIDIdleTime resets). Echo-only reports are invisible
     to the event stack entirely, not just to userspace clients.
   - Two clean display-sleep cycles with the device unseized also did
     not trigger it: the initiating event is probabilistic, consistent
     with a bus transient at USB suspend/resume being parsed as a
     consumer-control key-down whose release never arrives, after
     which the HID stack re-arms UserIsActive forever with no further
     device traffic.
   The app self-heals: every 2 min while seized it reads
   IOPMCopyAssertionsByProcess, and a PowerMate-named UserIsActive
   assertion whose timeout fails to drain across a 15 s re-sample is
   phantom by definition (seized means the system cannot be seeing
   real knob input), so the app re-enumerates the device (info log
   "Stuck activity wedge detected", rate-limited to once per 10 min)
   and reconnects through normal hot-plug matching.

## Data formats

UserDefaults (domain io.perimtr.powermate). Keys, from Pref in
AppDelegate.swift: volumeStep (Double), reverseRotation (Bool),
rotateMode, clickAction, doubleClickAction, longPressAction,
pressTurnMode, rotateShortcutCW, rotateShortcutCCW, pulseSpeed,
pulseWaveform (raw strings), ledMode (0 follow volume / 1 always on /
2 off),
pulseWhenMuted, pulseWhileAsleep, showHUD, tickSound,
releaseWhenDisplaySleeps, blockMusicAutoLaunch,
checkForUpdatesAutomatically (Bools), lastUpdateCheckAt (Double epoch),
lastNotifiedUpdate (String version), didAutoRegisterLoginItem,
didDiscoverMenu (one-shot flags), appProfiles (dictionary).

appProfiles: { bundleID: { name, rotate, click, doubleClick, longPress,
pressTurn, rotateCW, rotateCCW, step, hud } }, all string values. Custom
profiles (modes tied to no app) use keys "custom:<UUID>" and are skipped
by frontmost matching automatically. step is a stringified Double or ""
for "use the global sensitivity". hud is "" (follow the global Volume
HUD toggle), "shown", or "hidden" (suppress the bezel while this
profile is active; the menu bar readout takes over).

Action raw strings: playPause, mute, nextTrack, previousTrack, space,
cycleProfile, cycleAudioOutput, none, and "shortcut:<Name>" for Run
Shortcut bindings.
Rotate modes: volume, scroll, scrollHorizontal, arrowsHorizontal,
arrowsVertical, runShortcuts, appVolume, none. appVolumeGains is a
{bundleID: Double 0..1} dictionary holding per-app gains below 100%.
Press-and-turn: skipTracks,
fineVolume, none. Pulse speeds: slow, normal, fast. Pulse waveforms:
tableA, tableB, tableC (firmware tables 0-2; A is the classic breathe).

Tuning constants: long press 0.5 s, double-click window 0.35 s (skipped
entirely when nothing binds double-click), press-and-turn chunk 5 counts,
rotation-shortcut chunk 5 counts, user-activity declare throttle 5 s,
LED send throttle 80 ms, tick sound throttle 150 ms, ShortcutRunner
drops runs beyond 2 in flight. Profile pinning is session-only by
design.

## Build, install, release

    make run        # build, bundle, launch dist/PowerMate.app
    make install    # replace /Applications/PowerMate.app (pkills first)
    make dmg        # package dist/PowerMate-<version>.dmg
    make release    # signed + notarized + stapled dmg (needs notary creds)

Signing: the Makefile auto-detects a "Developer ID Application"
identity in the keychain and signs with it plus the hardened runtime
(SIGN_ID= forces ad-hoc; ad-hoc rebuilds churn TCC grants, Developer ID
builds do not). Notarization uses a notarytool keychain profile named
perimtr-notary locally (one-time: xcrun notarytool store-credentials)
and App Store Connect API key secrets in CI. make release notarizes and
staples the app first, then packages and notarizes the dmg, so both
survive offline Gatekeeper checks.

CI builds the dmg on every push and pull request and uploads it as a
workflow artifact; pushing a v* tag (v1.0) additionally publishes a
GitHub Release with the dmg attached. CI signs and notarizes when the
repo secrets MACOS_CERT_P12, MACOS_CERT_PASSWORD, APPSTORE_P8,
APPSTORE_KEY_ID, and APPSTORE_ISSUER_ID exist, and falls back to an
ad-hoc dmg when they do not. The icon is generated from Support/appicon-source.png:

    swift Support/make_appicon.swift Support/AppIcon.iconset
    iconutil -c icns Support/AppIcon.iconset -o Support/AppIcon.icns

The generator writes DIFFERENT artwork at small sizes on purpose. The
full render carries a command glyph above the knob and lettering on the
base; both are illegible below about 128px, where the icon collapsed
into a dark smudge. At 16, 32 and 64 pixels it crops to the knob so the
aluminium disc and the LED ring fill the tile. Do not "simplify" this
away: judge any icon change at 16 and 32px, not only at 1024. It also
writes Support/appicon-small-256.png, which is the knob artwork for
downstream surfaces that display small (the website lists products at
40px and uses it).

## Verification recipes (no knob-touching needed)

- App state: `/usr/bin/log stream --predicate 'subsystem ==
  "io.perimtr.powermate"' --level info` while relaunching. Expect
  "Registered as login item" (first run), "Device seized", "PowerMate
  connected", "LED control active", "Shortcuts available: N". Every raw
  report is logged at info level (btn/delta, plus an echo suffix when a
  report carries LED-state bytes), and a mute-triggered pulse logs
  "pulse start speed=... waveform=...". Nothing is logged at debug:
  macOS 26 never surfaces this app's debug-level messages in log
  stream, so info is the floor for anything a recipe depends on.
- Use the full path /usr/bin/log: plain `log` is a zsh builtin in this
  environment and fails silently in pipelines. Info-level messages do
  not reliably appear in `log show`; use `log stream` captured to a file
  while reproducing.
- Idle report count over 25 s should be zero (nonzero means the device
  is chattering). A stuck pulse no longer shows up here: macOS swallows
  echo-only reports before they reach the app. To detect one, quit the
  app and watch pmset -g assertions for a UserIsActive assertion naming
  the PowerMate that keeps renewing, or look at the knob.
- Sleep health: `pmset -g assertions` should show no UserIsActive naming
  the PowerMate and, after some idle time, no kernel USB assertion owned
  by it. `pmset displaysleepnow` then a wake (caffeinate -u -t 2)
  exercises the release/reacquire path; the log shows "Device released"
  and a re-seize at wake.
- Wedge check (pitfall 7): with hands off every input device,
  HIDIdleTime from `ioreg -c IOHIDSystem` must keep growing between
  samples. Pinned near zero plus a UserIsActive assertion naming the
  PowerMate means the stuck activity wedge. The watchdog should
  clear it within ~2 min ("Stuck activity wedge detected" at info);
  manually: `swiftc -O Support/pmled.swift -o /tmp/pmled && /tmp/pmled
  reenumerate` (quit the app first; it also sends raw LED commands,
  see its header).
- Heal-path test without a live wedge: `defaults write
  io.perimtr.powermate debugReenumerateOnConnect -bool true`, relaunch
  the app, and the log shows connect, "debug: re-enumerating on
  connect", a disconnect, and a clean re-seize. The flag is one-shot.
- Update-check test: `defaults write io.perimtr.powermate
  debugUpdateCheckVersion -string 0.9` and `defaults delete
  io.perimtr.powermate lastUpdateCheckAt`, relaunch, and the log shows
  "update available: <latest> (running 0.9)" with the menu offering
  "Get PowerMate <latest>". Delete the override afterwards; up-to-date
  runs log "update check: up to date".
- App-volume test without a knob: play something with a stable pid
  (afplay a long file), `defaults write io.perimtr.powermate
  debugAppVolumeTest -string "pid:<pid>"` (a bundle id also works),
  relaunch, and the log shows the engine coming up, gain 100% -> 25%,
  then realtime stats where ratio should be ~0.25 (callbacks and inRMS
  nonzero prove audio is flowing through the tap), then teardown. The
  flag is one-shot.
- Settings inspection: `defaults read io.perimtr.powermate`.

## Related surfaces

- Canonical family identity:
  ~/Projects/perimtr-website/design/PERIMTR-FAMILY-DESIGN-SYSTEM.md.
  Use it for shared brand, color, typography, naming presentation, and
  Perimtr attribution decisions. PowerMate remains a hardware-led endorsed
  product and keeps its title-case name, native macOS UI, and fixed blue LED.
- PRIVACY.md in this repo states the app collects nothing and documents
  its single network call (the update check, UpdateChecker.swift); keep
  both statements true, and mirror changes to the perimtr.io page.
- The company site (~/Projects/perimtr-website, deploys to perimtr.io on
  push via S3/CloudFront) has a PowerMate product card linking the
  GitHub repo (404 for the public while the repo is private) and a
  per-app privacy page at perimtr.io/powermate/privacy mirroring
  PRIVACY.md. Update both if data practices ever change.
- When the repo goes public again: re-enable secret scanning, push
  protection, and private vulnerability reporting in repo settings, and
  give the site's PowerMate card a working GitHub link.

## Roadmap ideas (not commitments)

A settings window if the menus outgrow themselves, and Bluetooth
PowerMate support (a different device entirely; out of scope so far).
