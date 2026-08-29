# PowerMate for modern macOS

[![Build](https://github.com/perimtr/powermate/actions/workflows/ci.yml/badge.svg)](https://github.com/perimtr/powermate/actions/workflows/ci.yml)

<img src="docs/icon.png" width="128" align="right" alt="PowerMate app icon">

A small menu bar app that makes the classic **Griffin PowerMate USB** knob
([the aluminum one](https://www.newegg.com/griffin-model-1040-pmt-audio/p/N82E16800997014))
work on current macOS (tested on macOS 26, works on macOS 13+, Apple Silicon
and Intel). Griffin's own software has been abandoned for years and no longer
runs; this replaces it with a zero-dependency Swift app.

*Unofficial community software - not affiliated with or endorsed by Griffin
Technology. PowerMate is a trademark of its respective owner.*

## What the knob does

All button gestures are remappable from the menu; the defaults:

| Gesture                | Default action                                |
| ---------------------- | --------------------------------------------- |
| Rotate                 | Volume up / down (with a floating volume HUD) |
| Click                  | Play / Pause                                  |
| Double-click           | Next track                                    |
| Long press (½ s)       | Toggle mute                                   |
| Press & turn           | Skip tracks (or fine volume / nothing)        |

Available actions per button gesture: Play/Pause, Mute, Next Track, Previous
Track, Space Bar, Switch Profile, Cycle Audio Output, **Run Shortcut** (any
shortcut from the Shortcuts app), or Do Nothing. Media actions send the same
events as the keyboard media keys, so they control Music, Spotify, browsers -
whatever owns Now Playing. Rotation itself is also remappable: System Volume,
**Frontmost App Volume** (macOS 14.4 and newer: the knob turns down just the
app in front - the browser, a game, a video call - leaving everything else
alone, and the per-app level sticks until you raise it back), Scroll, Scroll
Sideways, Arrow Keys ← → / ↑ ↓, **Run Shortcuts** (a clockwise/
counter-clockwise shortcut pair, stepped one run per ~⅕ turn), or Do
Nothing.

## Run Shortcut actions

Every gesture menu ends with a **Run Shortcut** picker listing the shortcuts
from the Shortcuts app; for rotation, pick a Clockwise and a
Counter-Clockwise shortcut (choosing one switches Rotate to Run Shortcuts
automatically). Runs execute via the `shortcuts` CLI in the background -
expect ~0.5–1 s per run, which is why rotation steps are chunked and dropped
rather than queued when you spin fast.

This is the bridge to things macOS gives apps no direct API for - most
notably **HomeKit**. Example: in the Shortcuts app create "Lights Brighter" /
"Lights Dimmer" (Control My Home → adjust brightness ±10%) and a scene
toggle, then in the PowerMate app's Home profile bind Rotate to that pair and
Click to the scene. The knob becomes a light dimmer whenever the Home app is
frontmost. No extra permissions needed - shortcuts run with the access you
already granted them in the Shortcuts app.

## Per-app profiles

The knob can behave differently depending on the frontmost app: volume on the
desktop, smooth scrolling in a browser, arrow-key frame stepping in a video
editor, Space to play/pause the focused player.

To set one up: switch to the target app, open the PowerMate menu, and choose
**App Profiles → Add Profile for “That App”** (opening the menu doesn't steal
focus, so the app you were just using is the one offered). The new profile
starts as a copy of your defaults; edit any gesture from its submenu under
App Profiles, or remove it there too. Each profile can also override the
knob sensitivity and the **Volume HUD**: hide the bezel in apps that show
volume feedback of their own (players, games), or force it on for one app
while it's off everywhere else. Profiles match the frontmost app's
bundle identifier; apps without a profile use the defaults from the top-level
menus. The App Profiles menu also shows which profile is active right now.

Profiles don't have to follow the frontmost app. **Pin This Profile** (inside
a profile's submenu) makes it active in every app until unpinned - and the
**Switch Profile (cycle)** action can be bound to any button gesture to step
through Auto → each profile → back from the knob itself, with the current
mode flashed next to the menu bar icon and shown in the status line. Pinning
is session-only: after a relaunch the knob follows the frontmost app again.
Handy for the HomeKit setup: pin the Home profile (or long-press to cycle to
it) and dim the lights from any app - the Home app doesn't even need to be
open, since shortcuts talk to HomeKit directly.

Two more profile tools:

- **New Custom Profile…** creates a standalone mode tied to no app at all
  (name it "Lights", "Editing", whatever). It never activates automatically;
  it exists purely for pinning and the Switch Profile cycle. For knob-as-
  light-dimmer this is cleaner than borrowing the Home app's profile.
- **Sensitivity** inside each profile overrides the global knob sensitivity
  for that profile only ("Use Default" restores the global value).

Scroll and arrow-key actions target wherever such input naturally goes -
scrolling affects the window under the pointer, keys go to the focused app -
and need the same one-time Accessibility grant as the media keys.

Extras:

- The current volume appears briefly next to the menu bar icon as you turn.
- The knob's blue LED tracks the volume level (bright = loud), follows
  changes made anywhere (keyboard keys, other apps), and breathes
  slowly while muted, using the device's hardware pulse mode. Switch the LED
  to "Always On" or "Off", or disable "Pulse When Muted", in the menu.
  The LED is single-color blue hardware - brightness and pulsing are the only
  things that can be controlled; the color itself cannot change.
- Rotating while muted unmutes first, like the keyboard volume keys.
- Hot-plug aware - connect/disconnect the knob any time.

## Install

With [Homebrew](https://brew.sh):

```sh
brew install --cask perimtr/tap/powermate
```

Or download the disk image from the
[latest release](https://github.com/perimtr/powermate/releases/latest)
and drag the app to Applications. Either way the app is signed with the
Perimtr LLC Developer ID and notarized by Apple, so it opens without
Gatekeeper warnings.

Launch it once, then tick **Start at Login** (menu or Settings window)
to keep it running. Upgrades: `brew upgrade --cask powermate`.

## Build from source

Requires the Xcode Command Line Tools (`xcode-select --install`). Then:

```sh
make run        # build, bundle and launch dist/PowerMate.app
make install    # copy it to /Applications
make dmg        # package a drag-to-install disk image
```

CI packages the disk image on every push, and pushing a version tag
(`v1.0`) publishes it on the GitHub releases page. Builds are signed
with the Perimtr LLC Developer ID and hardened runtime when the
certificate is available (local keychain, or repository secrets in CI),
and `make release` notarizes and staples both the app and the disk
image so downloads open without Gatekeeper warnings. Without a
certificate the build falls back to ad-hoc signing: right-click the app
and choose Open the first time.

The app icon is generated by `Support/make_appicon.swift` from
`Support/appicon-source.png`. To rebuild it after changing the artwork:

```sh
swift Support/make_appicon.swift Support/AppIcon.iconset
iconutil -c icns Support/AppIcon.iconset -o Support/AppIcon.icns
```

Small sizes get simplified artwork: below 128px the generator crops to the
knob, because the command glyph and the lettering on the base turn into a
smudge at 16 and 32px. Check any icon change at those sizes.

Once built, tick **Start at Login** in the app's menu to make it permanent.

## Permissions

- **Accessibility** - required only for the media actions (play/pause, track
  skip), which synthesize media-key events. The app prompts on first use;
  grant under **System Settings → Privacy & Security → Accessibility**.
  Volume, mute and the LED work without it.
- **Input Monitoring** - macOS may gate HID input. If the menu shows
  "Permission Required", grant it under **System Settings → Privacy &
  Security → Input Monitoring**, then relaunch the app.
- **System Audio Recording** - requested only the first time you use the
  Frontmost App Volume rotate mode. macOS files per-app volume under
  this permission because the app's audio passes through PowerMate's
  gain stage on its way to the speaker; nothing is recorded or stored
  (see [PRIVACY.md](PRIVACY.md)).

Developer ID builds keep a stable code identity, so permission grants
survive rebuilds. Ad-hoc builds (no certificate in the keychain) can
invalidate previous grants on every rebuild - toggle the checkbox off
and on again if that happens.

## Privacy

PowerMate collects nothing. Its only network access is the optional
update check: a single anonymous request to GitHub for the newest
release number, at most once a day, with an off switch in the menu.
Details and how to verify: [PRIVACY.md](PRIVACY.md).

## Menu options

- **Pause PowerMate** - temporarily ignore the knob (until toggled back;
  not persisted across launches). The LED goes dark while paused.
- **Settings…** - everything below in one native window: four tabs for
  the knob bindings, the LED, per-app profiles (add apps straight from
  an open panel), and general behavior. The menu and the window edit
  the same settings; use whichever is closer at hand.
- **Click / Double-Click / Long Press / Press & Turn** - remap each gesture.
  Actions include media keys, mute, Space, profile switching, cycling the
  default audio output device, and any Apple Shortcut. Setting Double-Click
  to "Do Nothing" removes the short delay before single clicks fire.
- **Volume HUD** - the floating volume bezel shown while turning; disable it
  to get the small menu-bar readout instead.
- **Sound When Turning** - an audible tick as the volume changes (off by
  default).
- **Stop Apple Music Auto-Launch** - off by default. macOS opens Apple
  Music whenever a media key fires with no player running, so a knob
  play/pause can summon it by accident; with this on, a Music launch in
  the few seconds after a knob media key is closed again. Opening Music
  yourself is never touched.
- **Release Knob While Display Sleeps** - on by default: when the screen
  turns off, the app closes the device entirely so it can suspend on the USB
  bus and never holds up the Mac's own idle sleep. Bonus: while released,
  the system sees the knob again, so touching it wakes the display. Turn
  this off if you want to keep adjusting volume with the display dark.
- **Knob Sensitivity** - volume change per detent (0.5% to 5%). Spinning the
  knob fast accelerates naturally because the device reports larger deltas.
- **Reverse Direction** - flip if your unit reports rotation inverted
  (applies to press-and-turn track skipping too).
- **Knob LED** - Follow Volume / Always On / Off, plus a Pulse When Muted
  toggle (uses the hardware breathing effect, so it costs nothing to run),
  a Pulse Speed submenu (Slow / Normal / Fast) and a Pulse Waveform
  submenu (Waveform A / B / C - the three breathing patterns stored in
  the knob's firmware; A is the classic Griffin breathe). Speed and
  waveform retune a live breathe immediately and also shape the optional
  sleep pulse.
- **Pulse While Mac Sleeps** - off by default, so the LED goes dark when the
  Mac sleeps. Turn it on to get the classic Griffin sleep throb back. The app
  both sets the device's hardware pulse-asleep flag and forces the LED dark
  just before sleep.
- **Start at Login** - registers a login item via `SMAppService`.
- **About PowerMate** - version, license, and project link.
- **Check for Updates** - asks GitHub for the newest release number and
  offers to open the release page when something newer exists ("Get
  PowerMate x.y"). Automatic checks run at most once a day and can be
  turned off with **Check for Updates Automatically**; nothing downloads
  by itself. What the request contains (and does not) is spelled out in
  [PRIVACY.md](PRIVACY.md).

## How it works

- **Input** - `IOHIDManager` matches vendor `0x077D`, product `0x0410` and
  reads raw input reports. Byte 0 bit 0 is the button, byte 1 is a signed
  rotation delta (same layout the Linux kernel driver documents). The device
  is opened with **exclusive access (seize)**: the PowerMate enumerates as a
  consumer-control device and echoes an input report for every LED state
  change, so left shared, macOS counts those echoes - and any electrical
  noise - as user activity, which can keep the display awake forever.
  Seized, the system never sees the device; the app instead declares user
  activity itself (`IOPMAssertionDeclareUserActivity`) for real gestures:
  button presses and sustained rotation, but not vibration-style jitter.
- **Volume** - CoreAudio (`kAudioDevicePropertyVolumeScalar` / `Mute`) on the
  default output device, with a software-mute fallback for devices without a
  hardware mute control. No Accessibility permission needed.
- **LED** - vendor USB control requests on the default pipe
  (`bmRequestType 0x41, bRequest 0x01`; command 1 = static brightness,
  3 = pulse while awake, 4 = pulse mode: speed plus one of the firmware's
  three waveform tables), sent alongside the system HID driver via
  `IOUSBDeviceInterface`.

## Troubleshooting

- **"Not Found" with the knob plugged in** - check the cable/hub; the device
  should appear in System Information → USB as "Griffin PowerMate". Only the
  USB model (077d:0410) is supported, not the Bluetooth PowerMate.
- **Volume doesn't change on AirPlay/some DACs** - devices without a software
  volume control can't be adjusted this way; the readout shows "n/a".
- **Rotation feels backwards** - use Reverse Direction.
- **Display or Mac never sleeps** - the app defends against the knob's
  hardware quirks (it seizes the device, force-syncs the pulse state, and
  releases the device entirely while the display sleeps), and it watches
  for the one failure mode that slips past all of that: macOS can latch
  phantom knob activity after a sleep/wake transient, pinning a
  `UserIsActive` assertion that names the Griffin PowerMate. The app
  detects that within about two minutes and resets the device on its own
  (the log shows "Stuck activity wedge detected"). If sleep still fails,
  run `pmset -g` and check the "sleep prevented by" list - other
  processes (audio, chat apps) hold their own assertions, and unplugging
  and replugging the knob rules the device out entirely.

## Uninstall

Quit the app, delete `/Applications/PowerMate.app`, and run
`defaults delete io.perimtr.powermate`.
