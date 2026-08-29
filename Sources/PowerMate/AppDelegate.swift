import AppKit
import IOKit.hid
import IOKit.pwr_mgt
import ServiceManagement
import os.log

let logger = Logger(subsystem: "io.perimtr.powermate", category: "app")

enum Pref {
    static let step = "volumeStep"          // volume change per rotation tick
    static let reverse = "reverseRotation"
    static let rotateMode = "rotateMode"
    static let ledMode = "ledMode"          // 0 = follow volume, 1 = always on, 2 = off
    static let pulseWhenMuted = "pulseWhenMuted"
    static let pulseWhileAsleep = "pulseWhileAsleep"
    static let didAutoRegisterLoginItem = "didAutoRegisterLoginItem"
    static let didDiscoverMenu = "didDiscoverMenu"
    static let clickAction = "clickAction"
    static let doubleClickAction = "doubleClickAction"
    static let longPressAction = "longPressAction"
    static let pressTurnMode = "pressTurnMode"
    static let showHUD = "showHUD"
    static let tickSound = "tickSound"
    static let releaseOnDisplaySleep = "releaseWhenDisplaySleeps"
    static let rotateShortcutCW = "rotateShortcutCW"
    static let rotateShortcutCCW = "rotateShortcutCCW"
    static let pulseSpeed = "pulseSpeed"
    static let pulseWaveform = "pulseWaveform"
    static let blockMusicLaunch = "blockMusicAutoLaunch"
    static let midiEnabled = "midiControllerEnabled"
    static let midiKnobCC = "midiKnobCC"
    static let midiButtonNote = "midiButtonNote"
    static let midiRelativeEncoder = "midiRelativeEncoder"
    static let autoUpdateCheck = "checkForUpdatesAutomatically"
    static let lastUpdateCheckAt = "lastUpdateCheckAt"
    static let lastNotifiedUpdate = "lastNotifiedUpdate"
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private let hid = PowerMateHID()
    private var led: PowerMateLED?

    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "PowerMate: Searching…", action: nil, keyEquivalent: "")
    private let permissionLine = NSMenuItem(
        title: "Grant Input Monitoring Access…",
        action: #selector(openInputMonitoringSettings), keyEquivalent: "")
    private let accessibilityLine = NSMenuItem(
        title: "Grant Accessibility Access…",
        action: #selector(openAccessibilitySettings), keyEquivalent: "")
    private let pauseItem = NSMenuItem(
        title: "Pause PowerMate", action: #selector(togglePaused), keyEquivalent: "")
    private let hudItem = NSMenuItem(
        title: "Volume HUD", action: #selector(toggleHUD), keyEquivalent: "")
    private let soundItem = NSMenuItem(
        title: "Sound When Turning", action: #selector(toggleTickSound), keyEquivalent: "")
    private let musicGuardItem = NSMenuItem(
        title: "Stop Apple Music Auto-Launch",
        action: #selector(toggleMusicGuard), keyEquivalent: "")
    private let updateCheckItem = NSMenuItem(
        title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
    private let autoUpdateItem = NSMenuItem(
        title: "Check for Updates Automatically",
        action: #selector(toggleAutoUpdate), keyEquivalent: "")
    // A MIDI controller as a second input source (prototype). Its gestures
    // land in the same handlers as the knob's.
    private let midi = MIDISource()
    private let midiItem = NSMenuItem(
        title: "Use a MIDI Controller", action: #selector(toggleMIDI), keyEquivalent: "")
    private let midiRelearnItem = NSMenuItem(
        title: "Relearn MIDI Knob and Button",
        action: #selector(relearnMIDI), keyEquivalent: "")
    private let updateChecker = UpdateChecker()
    private var updateTimer: Timer?
    private var updateCheckWasManual = false
    private var settingsController: SettingsWindowController?
    private let releaseItem = NSMenuItem(
        title: "Release Knob While Display Sleeps",
        action: #selector(toggleReleaseOnDisplaySleep), keyEquivalent: "")
    private let loginItem = NSMenuItem(
        title: "Start at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private var sensitivityItems: [NSMenuItem] = []
    private var ledModeItems: [NSMenuItem] = []
    private var pulseSpeedItems: [NSMenuItem] = []
    private var pulseWaveformItems: [NSMenuItem] = []
    private let pulseItem = NSMenuItem(
        title: "Pulse When Muted", action: #selector(togglePulseWhenMuted), keyEquivalent: "")
    private let sleepPulseItem = NSMenuItem(
        title: "Pulse While Mac Sleeps", action: #selector(togglePulseWhileAsleep), keyEquivalent: "")
    private let reverseItem = NSMenuItem(
        title: "Reverse Direction", action: #selector(toggleReverse), keyEquivalent: "")

    private lazy var store = ProfileStore(defaults: UserDefaults.standard)
    /// When set, this profile applies everywhere, ignoring the frontmost app.
    /// Session-only by design: after a relaunch the knob is a volume knob again.
    private var pinnedProfileID: String?
    private var deviceConnected = false
    private let profilesRoot = NSMenuItem(title: "App Profiles", action: nil, keyEquivalent: "")
    private let rotateRoot = NSMenuItem(title: "Rotate", action: nil, keyEquivalent: "")
    private let clickRoot = NSMenuItem(title: "Click", action: nil, keyEquivalent: "")
    private let doubleClickRoot = NSMenuItem(title: "Double-Click", action: nil, keyEquivalent: "")
    private let longPressRoot = NSMenuItem(title: "Long Press", action: nil, keyEquivalent: "")
    private let pressTurnRoot = NSMenuItem(title: "Press & Turn", action: nil, keyEquivalent: "")
    private lazy var hud = VolumeHUD()
    private let audioObserver = SystemAudioObserver()
    // Frontmost App Volume (macOS 14.4+). Stored untyped so the class can
    // stay @available-gated; use the accessor below.
    private var appVolumeStorage: Any?
    // When the app last posted a media key. macOS auto-launches Apple Music
    // in response to a media key nobody is playing for; the optional guard
    // only terminates a Music launch that follows one of OUR media keys.
    private var lastMediaKeyPost = Date.distantPast
    private var isPaused = false
    private let tick = NSSound(named: "Tink")
    private var lastTick = Date.distantPast
    private var titleTimer: Timer?
    private var askedForPermission = false
    private var askedForAccessibility = false
    private var activityToken: NSObjectProtocol?

    // With the device seized, the system never sees knob input, so genuine
    // gestures must re-declare user activity (keeps the display awake while
    // the knob is actually in use). Rotation only counts once it accumulates
    // net movement, so vibration jitter (alternating ±1) never triggers it.
    private var userActivityAssertionID: IOPMAssertionID = 0
    private var lastActivityDeclare = Date.distantPast
    private var netRotation = 0
    private var lastRotationAt = Date.distantPast

    // LED throttle: control transfers are cheap but there's no point sending
    // one per report while the knob spins.
    private var lastLEDSend = Date.distantPast
    private var ledRefreshScheduled = false
    private var ledIsPulsing = false

    // Stuck activity wedge watchdog. While the device is seized the system
    // cannot legitimately be seeing knob activity, so a UserIsActive
    // assertion naming the PowerMate that keeps re-arming instead of
    // draining is phantom input latched in the HID stack; re-enumerating
    // the device is the only known cure. See AGENTS.md, item 7.
    private var wedgeTimer: Timer?
    private var lastWedgeHeal = Date.distantPast

    private static let sensitivities: [(title: String, step: Double)] = [
        ("Fine (0.5%)", 0.005),
        ("Normal (1%)", 0.01),
        ("Fast (2%)", 0.02),
        ("Extra Fast (5%)", 0.05),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [
            Pref.step: 0.01, Pref.reverse: false, Pref.ledMode: 0,
            Pref.pulseWhenMuted: true, Pref.pulseWhileAsleep: false,
            Pref.clickAction: KnobAction.playPause.raw,
            Pref.doubleClickAction: KnobAction.nextTrack.raw,
            Pref.longPressAction: KnobAction.mute.raw,
            Pref.pressTurnMode: PressTurnMode.skipTracks.rawValue,
            Pref.rotateMode: RotateMode.volume.rawValue,
            Pref.showHUD: true, Pref.tickSound: false,
            Pref.releaseOnDisplaySleep: true,
            Pref.rotateShortcutCW: "", Pref.rotateShortcutCCW: "",
            Pref.pulseSpeed: PulseSpeed.normal.rawValue,
            Pref.pulseWaveform: PulseWaveform.tableA.rawValue,
            Pref.blockMusicLaunch: false,
            Pref.autoUpdateCheck: true,
        ])
        refreshDoubleClickEnabled()
        ShortcutRunner.shared.refreshAvailable()
        ShortcutRunner.shared.onFailure = { [weak self] _ in
            self?.showTransient("Shortcut failed")
        }

        // Keep App Nap from delaying HID callbacks while we sit in the background.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "PowerMate HID monitoring")

        setUpStatusItem()
        wireDeviceCallbacks()
        wireMIDICallbacks()
        hid.start()
        if defaults.bool(forKey: Pref.midiEnabled) { midi.start() }

        wedgeTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.checkForWedge()
        }

        // Follow volume and mute changes made outside the app (keyboard
        // keys, other apps), so the LED never goes stale.
        audioObserver.onChange = { [weak self] in
            self?.refreshLED(now: false)
        }
        audioObserver.start()

        updateChecker.onResult = { [weak self] result in
            self?.handleUpdateResult(result)
        }
        maybeAutoCheckForUpdates()
        updateTimer = Timer.scheduledTimer(
            withTimeInterval: 24 * 3600, repeats: true
        ) { [weak self] _ in
            self?.maybeAutoCheckForUpdates()
        }

        // Bring persisted per-app gains back for apps that are running.
        if #available(macOS 14.4, *) {
            _ = appVolume
            if defaults.bool(forKey: "debugOpenSettings") {
                defaults.removeObject(forKey: "debugOpenSettings")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.showSettings()
                    logger.info("debug: settings window opened")
                }
            }
            if let target = defaults.string(forKey: "debugAppVolumeTest") {
                defaults.removeObject(forKey: "debugAppVolumeTest")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.runAppVolumeDebugTest(target)
                }
            }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(systemWillSleep),
                              name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemDidWake),
                              name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidSleep),
                              name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidWake),
                              name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(appDidLaunch(_:)),
                              name: NSWorkspace.didLaunchApplicationNotification, object: nil)

        // A menu bar utility for a physical knob is useless if it dies with
        // every reboot, so register as a login item once, automatically. The
        // "Start at Login" menu item and System Settings remain in control:
        // this runs only on the very first launch and never re-registers.
        if !defaults.bool(forKey: Pref.didAutoRegisterLoginItem) {
            defaults.set(true, forKey: Pref.didAutoRegisterLoginItem)
            if SMAppService.mainApp.status != .enabled {
                do {
                    try SMAppService.mainApp.register()
                    logger.info("Registered as login item")
                } catch {
                    logger.error("Login item registration failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    @objc private func systemWillSleep() {
        // The hardware pulse-asleep flag governs suspend behavior, but also
        // force the LED dark right before sleep so "off while sleeping" holds
        // regardless of firmware quirks.
        guard !defaults.bool(forKey: Pref.pulseWhileAsleep) else { return }
        ledIsPulsing = false
        led?.setPulsing(false)
        led?.setBrightness(0)
    }

    @objc private func systemDidWake() {
        ledIsPulsing = false
        led?.setPulsing(false)  // device state may be stale after sleep
        refreshLED(now: true)
    }

    /// Display sleep = user is away. Blank the LED, then close the device so
    /// it can suspend - an open client holds a kernel USB assertion that
    /// blocks the Mac's own idle sleep.
    @objc private func screensDidSleep() {
        guard defaults.bool(forKey: Pref.releaseOnDisplaySleep) else { return }
        ledIsPulsing = false
        led?.setPulsing(false)
        led?.setBrightness(0)
        hid.releaseForDisplaySleep()
    }

    @objc private func screensDidWake() {
        hid.reacquireAfterDisplayWake()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Status item & menu

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.knobIcon()
            button.imagePosition = .imageLeading
            button.toolTip = "PowerMate"
            // Until the user has opened the menu once, label the icon so it
            // can't be missed among the other status items.
            if !defaults.bool(forKey: Pref.didDiscoverMenu) {
                button.title = " PowerMate"
            }
        }

        let menu = NSMenu()
        menu.delegate = self

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        permissionLine.target = self
        permissionLine.isHidden = true
        menu.addItem(permissionLine)
        accessibilityLine.target = self
        accessibilityLine.isHidden = true
        menu.addItem(accessibilityLine)
        menu.addItem(.separator())

        pauseItem.target = self
        menu.addItem(pauseItem)
        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        for root in [rotateRoot, clickRoot, doubleClickRoot, longPressRoot, pressTurnRoot] {
            root.submenu = NSMenu()
            menu.addItem(root)
        }
        menu.addItem(.separator())

        profilesRoot.submenu = NSMenu()
        menu.addItem(profilesRoot)
        menu.addItem(.separator())

        let sensitivityMenu = NSMenu()
        for (title, step) in Self.sensitivities {
            let item = NSMenuItem(title: title, action: #selector(chooseSensitivity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = step
            sensitivityMenu.addItem(item)
            sensitivityItems.append(item)
        }
        let sensitivityRoot = NSMenuItem(title: "Knob Sensitivity", action: nil, keyEquivalent: "")
        sensitivityRoot.submenu = sensitivityMenu
        menu.addItem(sensitivityRoot)

        reverseItem.target = self
        menu.addItem(reverseItem)

        let ledMenu = NSMenu()
        ledMenu.autoenablesItems = false
        for (index, title) in ["Follow Volume", "Always On", "Off"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(chooseLEDMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = index
            ledMenu.addItem(item)
            ledModeItems.append(item)
        }
        ledMenu.addItem(.separator())
        pulseItem.target = self
        ledMenu.addItem(pulseItem)
        sleepPulseItem.target = self
        ledMenu.addItem(sleepPulseItem)
        let speedMenu = NSMenu()
        for speed in PulseSpeed.allCases {
            let item = NSMenuItem(title: speed.title, action: #selector(choosePulseSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = speed.rawValue
            speedMenu.addItem(item)
            pulseSpeedItems.append(item)
        }
        let speedRoot = NSMenuItem(title: "Pulse Speed", action: nil, keyEquivalent: "")
        speedRoot.submenu = speedMenu
        ledMenu.addItem(speedRoot)
        let waveformMenu = NSMenu()
        for waveform in PulseWaveform.allCases {
            let item = NSMenuItem(title: waveform.title, action: #selector(choosePulseWaveform(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = waveform.rawValue
            waveformMenu.addItem(item)
            pulseWaveformItems.append(item)
        }
        let waveformRoot = NSMenuItem(title: "Pulse Waveform", action: nil, keyEquivalent: "")
        waveformRoot.submenu = waveformMenu
        ledMenu.addItem(waveformRoot)
        let ledRoot = NSMenuItem(title: "Knob LED", action: nil, keyEquivalent: "")
        ledRoot.submenu = ledMenu
        menu.addItem(ledRoot)

        hudItem.target = self
        menu.addItem(hudItem)
        soundItem.target = self
        menu.addItem(soundItem)
        musicGuardItem.target = self
        menu.addItem(musicGuardItem)
        midiItem.target = self
        menu.addItem(midiItem)
        midiRelearnItem.target = self
        menu.addItem(midiRelearnItem)
        releaseItem.target = self
        menu.addItem(releaseItem)

        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())

        let about = NSMenuItem(title: "About PowerMate", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        updateCheckItem.target = self
        menu.addItem(updateCheckItem)
        autoUpdateItem.target = self
        menu.addItem(autoUpdateItem)
        let quit = NSMenuItem(title: "Quit PowerMate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - Gesture binding menus (shared by defaults and app profiles)

    /// Maps a profile field name to the preference key backing the default
    /// profile. Scope "" = default profile; otherwise a bundle identifier.
    private func prefKey(for field: String) -> String {
        switch field {
        case "rotate": return Pref.rotateMode
        case "click": return Pref.clickAction
        case "doubleClick": return Pref.doubleClickAction
        case "longPress": return Pref.longPressAction
        case "pressTurn": return Pref.pressTurnMode
        case "rotateCW": return Pref.rotateShortcutCW
        case "rotateCCW": return Pref.rotateShortcutCCW
        case "step": return Pref.step
        default: return field
        }
    }

    /// Per-profile sensitivity: Use Default plus the named steps.
    private func sensitivityGestureMenu(scope: String, current: String) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(bindingItem(
            title: "Use Default", scope: scope, field: "step", raw: "",
            isCurrent: current.isEmpty))
        for (title, step) in Self.sensitivities {
            let raw = String(step)
            menu.addItem(bindingItem(
                title: title, scope: scope, field: "step", raw: raw,
                isCurrent: current == raw))
        }
        return menu
    }

    private func bindingItem(
        title: String, scope: String, field: String, raw: String, isCurrent: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(chooseBinding(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = [scope, field, raw]
        item.state = isCurrent ? .on : .off
        return item
    }

    /// Submenu listing the user's shortcuts; picking one stores
    /// `rawPrefix + name` into the given field.
    private func shortcutListMenu(
        scope: String, field: String, selected: String?, rawPrefix: String
    ) -> NSMenu {
        let menu = NSMenu()
        let names = ShortcutRunner.shared.available
        if names.isEmpty {
            let empty = NSMenuItem(
                title: "No shortcuts found - create one in the Shortcuts app",
                action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for name in names {
            menu.addItem(bindingItem(
                title: name, scope: scope, field: field,
                raw: rawPrefix + name, isCurrent: name == selected))
        }
        return menu
    }

    /// Menu for click / double-click / long press: fixed actions plus a
    /// Run Shortcut picker.
    private func buttonActionMenu(scope: String, field: String, current: KnobAction) -> NSMenu {
        let menu = NSMenu()
        for action in KnobAction.fixed {
            menu.addItem(bindingItem(
                title: action.title, scope: scope, field: field,
                raw: action.raw, isCurrent: action == current))
        }
        menu.addItem(.separator())
        var currentShortcut: String?
        if case .shortcut(let name) = current { currentShortcut = name }
        let picker = NSMenuItem(
            title: currentShortcut.map { "Run Shortcut: \($0)" } ?? "Run Shortcut",
            action: nil, keyEquivalent: "")
        picker.state = currentShortcut != nil ? .on : .off
        picker.submenu = shortcutListMenu(
            scope: scope, field: field, selected: currentShortcut, rawPrefix: "shortcut:")
        menu.addItem(picker)
        return menu
    }

    /// Menu for rotation: the modes plus clockwise/counter-clockwise shortcut
    /// pickers (picking one switches the mode to Run Shortcuts).
    private func rotateGestureMenu(scope: String, profile: Profile) -> NSMenu {
        let menu = NSMenu()
        for mode in RotateMode.allCases {
            menu.addItem(bindingItem(
                title: mode.title, scope: scope, field: "rotate",
                raw: mode.rawValue, isCurrent: mode == profile.rotate))
        }
        menu.addItem(.separator())
        let pickers: [(label: String, field: String, value: String)] = [
            ("Clockwise Shortcut", "rotateCW", profile.rotateCW),
            ("Counter-Clockwise Shortcut", "rotateCCW", profile.rotateCCW),
        ]
        for picker in pickers {
            let item = NSMenuItem(
                title: picker.value.isEmpty ? picker.label : "\(picker.label): \(picker.value)",
                action: nil, keyEquivalent: "")
            item.submenu = shortcutListMenu(
                scope: scope, field: picker.field,
                selected: picker.value.isEmpty ? nil : picker.value, rawPrefix: "")
            menu.addItem(item)
        }
        return menu
    }

    private func pressTurnGestureMenu(scope: String, current: PressTurnMode) -> NSMenu {
        let menu = NSMenu()
        for mode in PressTurnMode.allCases {
            menu.addItem(bindingItem(
                title: mode.title, scope: scope, field: "pressTurn",
                raw: mode.rawValue, isCurrent: mode == current))
        }
        return menu
    }

    /// Per-profile HUD override: follow the global Volume HUD toggle, force
    /// the bezel on, or suppress it for apps with volume feedback of their
    /// own (the menu bar readout takes over when hidden).
    private func hudGestureMenu(scope: String, current: String) -> NSMenu {
        let menu = NSMenu()
        let choices: [(title: String, raw: String)] = [
            ("Use Default", ""), ("Shown", "shown"), ("Hidden", "hidden"),
        ]
        for choice in choices {
            menu.addItem(bindingItem(
                title: choice.title, scope: scope, field: "hud",
                raw: choice.raw, isCurrent: current == choice.raw))
        }
        return menu
    }

    /// The menu bar glyph. SF Symbols first: the system renders them natively
    /// in the menu bar (macOS 26 refuses to render drawing-handler-based
    /// template images there - they come out blank). The hand-drawn knob
    /// remains only as a fallback for symbol-less systems.
    private static func knobIcon() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        for name in ["dial.medium.fill", "dial.medium", "dial.min.fill", "dial.min"] {
            if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: "PowerMate") {
                return symbol.withSymbolConfiguration(config) ?? symbol
            }
        }
        return drawnKnobIcon()
    }

    /// A bold volume-knob glyph: thick ring with a position-indicator dot.
    private static func drawnKnobIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset: CGFloat = 1.6
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset))
            ring.lineWidth = 2.0
            NSColor.black.setStroke()
            ring.stroke()

            let center = NSPoint(x: rect.midX, y: rect.midY)
            let angle = CGFloat.pi / 4  // indicator at the upper right
            let orbit = (rect.width / 2 - inset) * 0.5
            let dotRadius: CGFloat = 2.3
            let dotCenter = NSPoint(
                x: center.x + orbit * cos(angle),
                y: center.y + orbit * sin(angle))
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius,
                width: dotRadius * 2, height: dotRadius * 2)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    func menuWillOpen(_ menu: NSMenu) {
        if !defaults.bool(forKey: Pref.didDiscoverMenu) {
            defaults.set(true, forKey: Pref.didDiscoverMenu)
            statusItem.button?.title = ""
        }
        let step = defaults.double(forKey: Pref.step)
        for item in sensitivityItems {
            let itemStep = item.representedObject as? Double ?? -1
            item.state = abs(itemStep - step) < 0.0001 ? .on : .off
        }
        reverseItem.state = defaults.bool(forKey: Pref.reverse) ? .on : .off
        let mode = defaults.integer(forKey: Pref.ledMode)
        for (index, item) in ledModeItems.enumerated() {
            item.state = index == mode ? .on : .off
        }
        pulseItem.state = defaults.bool(forKey: Pref.pulseWhenMuted) ? .on : .off
        pulseItem.isEnabled = mode != 2
        sleepPulseItem.state = defaults.bool(forKey: Pref.pulseWhileAsleep) ? .on : .off
        let speedRaw = defaults.string(forKey: Pref.pulseSpeed)
        for item in pulseSpeedItems {
            item.state = (item.representedObject as? String) == speedRaw ? .on : .off
        }
        let waveformRaw = defaults.string(forKey: Pref.pulseWaveform)
        for item in pulseWaveformItems {
            item.state = (item.representedObject as? String) == waveformRaw ? .on : .off
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        ShortcutRunner.shared.refreshAvailable()  // async; menus use the cache
        let defaultProfile = store.defaultProfile
        rotateRoot.submenu = rotateGestureMenu(scope: "", profile: defaultProfile)
        clickRoot.submenu = buttonActionMenu(scope: "", field: "click", current: defaultProfile.click)
        doubleClickRoot.submenu = buttonActionMenu(
            scope: "", field: "doubleClick", current: defaultProfile.doubleClick)
        longPressRoot.submenu = buttonActionMenu(
            scope: "", field: "longPress", current: defaultProfile.longPress)
        pressTurnRoot.submenu = pressTurnGestureMenu(scope: "", current: defaultProfile.pressTurn)
        pauseItem.state = isPaused ? .on : .off
        hudItem.state = defaults.bool(forKey: Pref.showHUD) ? .on : .off
        soundItem.state = defaults.bool(forKey: Pref.tickSound) ? .on : .off
        musicGuardItem.state = defaults.bool(forKey: Pref.blockMusicLaunch) ? .on : .off
        let midiOn = defaults.bool(forKey: Pref.midiEnabled)
        midiItem.state = midiOn ? .on : .off
        midiRelearnItem.isHidden = !midiOn
        midiRelearnItem.title = "Relearn MIDI Knob and Button (\(midi.describeLearned()))"
        autoUpdateItem.state = defaults.bool(forKey: Pref.autoUpdateCheck) ? .on : .off
        updateCheckItem.title = updateChecker.available.map {
            "Get PowerMate \($0.version)…"
        } ?? "Check for Updates…"
        releaseItem.state = defaults.bool(forKey: Pref.releaseOnDisplaySleep) ? .on : .off
        accessibilityLine.isHidden = MediaKeys.trusted || !needsAccessibility
        rebuildProfilesMenu()
    }

    // MARK: - Device events

    private func wireDeviceCallbacks() {
        hid.onConnect = { [weak self] device in
            guard let self else { return }
            self.deviceConnected = true
            self.updateStatusLine()
            self.permissionLine.isHidden = true
            self.led = PowerMateLED(hidDevice: device)
            if self.led == nil {
                logger.error("Could not create USB interface for LED control")
            }
            // The device keeps LED state across app restarts, so never trust
            // our flags after attach: force the autonomous pulse OFF first. A
            // stale pulse left running emits a continuous stream of LED-echo
            // reports, which macOS (pre-seize) counted as nonstop user
            // activity - the display could never sleep.
            self.ledIsPulsing = false
            self.led?.setPulsing(false)
            self.led?.setPulseAsleep(self.defaults.bool(forKey: Pref.pulseWhileAsleep))
            self.refreshLED(now: true)
            self.showTransient("PowerMate")
            // Hidden one-shot test hook for the wedge heal path:
            // defaults write io.perimtr.powermate debugReenumerateOnConnect -bool true
            if self.defaults.bool(forKey: "debugReenumerateOnConnect") {
                self.defaults.removeObject(forKey: "debugReenumerateOnConnect")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    logger.info("debug: re-enumerating on connect")
                    self?.led?.reenumerate()
                }
            }
        }
        hid.onDisconnect = { [weak self] in
            self?.led = nil
            self?.deviceConnected = false
            self?.updateStatusLine()
        }
        hid.onRotate = { [weak self] delta in
            self?.handleRotate(delta)
        }
        hid.onClick = { [weak self] in
            guard let self else { return }
            self.perform(self.activeProfile().click)
        }
        hid.onDoubleClick = { [weak self] in
            guard let self else { return }
            self.perform(self.activeProfile().doubleClick)
        }
        hid.onLongPress = { [weak self] in
            guard let self else { return }
            self.perform(self.activeProfile().longPress)
        }
        hid.onPressedRotate = { [weak self] direction in
            self?.handlePressedRotate(direction)
        }
        hid.onPermissionDenied = { [weak self] in
            self?.showPermissionNeeded()
        }
    }

    /// The MIDI source lands in exactly the same handlers as the knob, which
    /// is the whole point: everything downstream is input-agnostic.
    private func wireMIDICallbacks() {
        midi.onRotate = { [weak self] delta in self?.handleRotate(delta) }
        midi.onClick = { [weak self] in
            guard let self else { return }
            self.perform(self.activeProfile().click)
        }
        midi.onDoubleClick = { [weak self] in
            guard let self else { return }
            self.perform(self.activeProfile().doubleClick)
        }
        midi.onLongPress = { [weak self] in
            guard let self else { return }
            self.perform(self.activeProfile().longPress)
        }
        midi.onPressedRotate = { [weak self] direction in
            self?.handlePressedRotate(direction)
        }
        midi.onLearned = { [weak self] description in
            self?.showTransient(description, duration: 2.5)
        }
    }

    @objc private func toggleMIDI() {
        let enable = !defaults.bool(forKey: Pref.midiEnabled)
        defaults.set(enable, forKey: Pref.midiEnabled)
        if enable {
            midi.doubleClickEnabled = hid.doubleClickEnabled
            midi.start()
            showTransient(
                midi.describeLearned().contains("unlearned")
                    ? "Turn a knob, then press a button" : "MIDI on",
                duration: 3)
        } else {
            midi.stop()
            showTransient("MIDI off")
        }
    }

    @objc private func relearnMIDI() {
        midi.relearn()
        showTransient("Turn a knob, then press a button", duration: 3)
    }

    // MARK: - Actions

    /// The bindings in effect right now: the pinned profile if one is set,
    /// otherwise whatever matches the frontmost application.
    private func activeProfile() -> Profile {
        if let pinned = pinnedProfileID {
            return store.profile(for: pinned)
        }
        return store.profile(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private func updateStatusLine() {
        var text = deviceConnected ? "PowerMate: Connected" : "PowerMate: Not Found"
        if let pinned = pinnedProfileID {
            text += " · \(store.displayName(for: pinned) ?? "Default")"
        }
        statusLine.title = text
    }

    /// Cycle: follow-frontmost → each app profile (alphabetical) → back.
    private func cycleProfile() {
        let ids = store.appProfiles.map(\.bundleID)
        guard !ids.isEmpty else {
            showTransient("No profiles to switch")
            return
        }
        if let current = pinnedProfileID, let index = ids.firstIndex(of: current) {
            pinnedProfileID = index + 1 < ids.count ? ids[index + 1] : nil
        } else {
            pinnedProfileID = ids.first
        }
        let name = pinnedProfileID.flatMap { store.displayName(for: $0) }
        showTransient("Profile: \(name ?? "Auto")", duration: 2)
        updateStatusLine()
        refreshLED(now: true)
    }

    /// True when any profile (default or per-app) binds an action that
    /// synthesizes events and therefore needs Accessibility trust. Shortcuts
    /// don't - they run through the `shortcuts` CLI.
    private var needsAccessibility: Bool {
        let profiles = [store.defaultProfile] + store.appProfiles.map(\.profile)
        let mediaActions: Set<KnobAction> = [.playPause, .nextTrack, .previousTrack, .space]
        let eventRotateModes: Set<RotateMode> = [
            .scroll, .scrollHorizontal, .arrowsHorizontal, .arrowsVertical,
        ]
        return profiles.contains { profile in
            eventRotateModes.contains(profile.rotate)
                || [profile.click, profile.doubleClick, profile.longPress]
                    .contains(where: mediaActions.contains)
                || profile.pressTurn == .skipTracks
        }
    }

    private func refreshDoubleClickEnabled() {
        let profiles = [store.defaultProfile] + store.appProfiles.map(\.profile)
        let enabled = profiles.contains { $0.doubleClick != KnobAction.none }
        hid.doubleClickEnabled = enabled
        midi.doubleClickEnabled = enabled
    }

    private func declareUserActivity() {
        let now = Date()
        guard now.timeIntervalSince(lastActivityDeclare) > 5 else { return }
        lastActivityDeclare = now
        IOPMAssertionDeclareUserActivity(
            "PowerMate knob input" as CFString, kIOPMUserActiveLocal, &userActivityAssertionID)
    }

    private func perform(_ action: KnobAction) {
        guard !isPaused else { return }
        declareUserActivity()
        switch action {
        case .playPause: postMedia(.playPause)
        case .nextTrack: postMedia(.next)
        case .previousTrack: postMedia(.previous)
        case .space: postSynthetic { SyntheticInput.press(.space) }
        case .mute: toggleMute()
        case .shortcut(let name): ShortcutRunner.shared.run(name)
        case .cycleProfile: cycleProfile()
        case .cycleAudioOutput: cycleAudioOutput()
        case .none: break
        }
    }

    /// Hop the default output to the next device, alphabetically. CoreAudio
    /// only; no permissions involved. The audio observer refreshes the LED
    /// against the new device on its own.
    private func cycleAudioOutput() {
        let devices = SystemAudio.outputDevices()
        guard !devices.isEmpty else {
            showTransient("n/a")
            return
        }
        let current = SystemAudio.defaultOutputDevice()
        let index = devices.firstIndex { $0.id == current } ?? -1
        let next = devices[(index + 1) % devices.count]
        if SystemAudio.setDefaultOutputDevice(next.id) {
            showTransient(next.name, duration: 2)
        } else {
            showTransient("n/a")
        }
    }

    /// The optional Apple Music guard: macOS launches Music for a media key
    /// that no running player claims. When one of OUR media keys did that,
    /// and the option is on, close it again before it takes over.
    @objc private func appDidLaunch(_ note: Notification) {
        guard defaults.bool(forKey: Pref.blockMusicLaunch),
              Date().timeIntervalSince(lastMediaKeyPost) < 3,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                  as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              bundleID == "com.apple.Music" || bundleID == "com.apple.iTunes"
        else { return }
        logger.info("Terminating Apple Music auto-launch after a knob media key")
        app.terminate()
        showTransient("Music blocked")
    }

    @objc private func toggleMusicGuard() {
        defaults.set(!defaults.bool(forKey: Pref.blockMusicLaunch),
                     forKey: Pref.blockMusicLaunch)
    }

    // MARK: - Updates

    /// Automatic checks run at most once every 20 hours, and only while
    /// the toggle is on. A found update is announced once per version.
    private func maybeAutoCheckForUpdates() {
        guard defaults.bool(forKey: Pref.autoUpdateCheck) else { return }
        let last = defaults.double(forKey: Pref.lastUpdateCheckAt)
        guard Date().timeIntervalSince1970 - last > 20 * 3600 else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: Pref.lastUpdateCheckAt)
        updateChecker.check()
    }

    private func handleUpdateResult(_ result: Result<UpdateChecker.Update?, Error>) {
        let manual = updateCheckWasManual
        updateCheckWasManual = false
        switch result {
        case .success(let update?):
            if manual || defaults.string(forKey: Pref.lastNotifiedUpdate) != update.version {
                defaults.set(update.version, forKey: Pref.lastNotifiedUpdate)
                showTransient("PowerMate \(update.version) available", duration: 4)
            }
        case .success(nil):
            if manual { showTransient("Up to date") }
        case .failure:
            if manual { showTransient("Update check failed") }
        }
    }

    /// Manual entry point: checks, or opens the release page once an
    /// update is known.
    @objc private func checkForUpdates() {
        if let update = updateChecker.available {
            NSWorkspace.shared.open(update.pageURL)
            return
        }
        updateCheckWasManual = true
        updateChecker.check()
    }

    @objc private func toggleAutoUpdate() {
        defaults.set(!defaults.bool(forKey: Pref.autoUpdateCheck),
                     forKey: Pref.autoUpdateCheck)
    }

    // MARK: - Settings window

    @objc private func showSettings() {
        if settingsController == nil {
            var actions = SettingsActions()
            actions.ledChanged = { [weak self] in self?.refreshLED(now: true) }
            actions.pulseTuningChanged = { [weak self] in self?.resendPulseMode() }
            actions.pulseAsleepChanged = { [weak self] value in
                self?.led?.setPulseAsleep(value)
            }
            actions.bindingsChanged = { [weak self] in
                guard let self else { return }
                self.refreshDoubleClickEnabled()
                if self.needsAccessibility, !MediaKeys.trusted {
                    self.accessibilityNeeded()
                }
            }
            actions.checkForUpdates = { [weak self] in self?.checkForUpdates() }
            actions.availableUpdate = { [weak self] in
                self?.updateChecker.available?.version
            }
            actions.pinnedProfileID = { [weak self] in self?.pinnedProfileID }
            actions.setPinnedProfileID = { [weak self] id in
                self?.pinnedProfileID = id
                self?.updateStatusLine()
                self?.refreshLED(now: true)
            }
            settingsController = SettingsWindowController(actions: actions, store: store)
        }
        settingsController?.show()
    }

    private func handlePressedRotate(_ direction: Int) {
        guard !isPaused else { return }
        declareUserActivity()
        let dir = defaults.bool(forKey: Pref.reverse) ? -direction : direction
        switch activeProfile().pressTurn {
        case .skipTracks:
            postMedia(dir > 0 ? .next : .previous)
        case .fineVolume:
            adjustVolume(bySteps: Double(dir) * 0.5)
        case .none:
            break
        }
    }

    private func postSynthetic(_ body: () -> Void) {
        guard MediaKeys.trusted else {
            accessibilityNeeded()
            return
        }
        body()
    }

    private func postMedia(_ key: MediaKeys.Key) {
        guard MediaKeys.trusted else {
            accessibilityNeeded()
            return
        }
        lastMediaKeyPost = Date()
        MediaKeys.post(key)
    }

    private func accessibilityNeeded() {
        accessibilityLine.isHidden = false
        showTransient("Grant Access")
        if !askedForAccessibility {
            askedForAccessibility = true
            MediaKeys.requestTrust()
        }
    }

    private func handleRotate(_ delta: Int) {
        guard !isPaused else { return }
        let now = Date()
        if now.timeIntervalSince(lastRotationAt) > 1.5 {
            netRotation = 0
            shortcutRotationAccum = 0
        }
        lastRotationAt = now
        netRotation += delta
        if abs(netRotation) >= 3 {
            netRotation = 0
            declareUserActivity()
        }
        let signed = defaults.bool(forKey: Pref.reverse) ? -delta : delta
        switch activeProfile().rotate {
        case .volume:
            adjustVolume(bySteps: Double(signed))
        case .appVolume:
            adjustAppVolume(bySteps: Double(signed))
        case .scroll:
            // Clockwise scrolls down, like rolling a wheel; ~10 px per count.
            postSynthetic { SyntheticInput.scroll(vertical: Int32(-signed * 10)) }
        case .scrollHorizontal:
            postSynthetic { SyntheticInput.scroll(vertical: 0, horizontal: Int32(-signed * 10)) }
        case .arrowsHorizontal:
            postSynthetic {
                SyntheticInput.press(signed > 0 ? .rightArrow : .leftArrow, times: min(abs(signed), 6))
            }
        case .arrowsVertical:
            postSynthetic {
                SyntheticInput.press(signed > 0 ? .downArrow : .upArrow, times: min(abs(signed), 6))
            }
        case .runShortcuts:
            stepRotationShortcuts(signed)
        case .none:
            break
        }
    }

    /// One shortcut run per ~fifth of a turn, like track skipping - a
    /// shortcut takes ~0.5–1 s, so per-count runs would pile up hopelessly.
    private var shortcutRotationAccum = 0

    private func stepRotationShortcuts(_ signed: Int) {
        shortcutRotationAccum += signed
        let profile = activeProfile()
        while shortcutRotationAccum >= 5 {
            shortcutRotationAccum -= 5
            runRotationShortcut(profile.rotateCW)
        }
        while shortcutRotationAccum <= -5 {
            shortcutRotationAccum += 5
            runRotationShortcut(profile.rotateCCW)
        }
    }

    private func runRotationShortcut(_ name: String) {
        if name.isEmpty {
            showTransient("No shortcut set")
        } else {
            ShortcutRunner.shared.run(name)
        }
    }

    private func adjustVolume(bySteps steps: Double) {
        guard let device = SystemAudio.defaultOutputDevice(),
              let current = SystemAudio.volume(of: device)
        else {
            showTransient("n/a")
            return
        }
        if SystemAudio.isMuted(device) {
            SystemAudio.setMuted(false, of: device)
        }
        let step = activeProfile().stepValue ?? defaults.double(forKey: Pref.step)
        let newVolume = Float32(min(1, max(0, Double(current) + step * steps)))
        SystemAudio.setVolume(newVolume, of: device)
        feedbackVolume(newVolume, muted: false)
        refreshLED(now: false)
    }

    @available(macOS 14.4, *)
    private var appVolume: AppVolumeController {
        if let controller = appVolumeStorage as? AppVolumeController { return controller }
        let controller = AppVolumeController()
        appVolumeStorage = controller
        return controller
    }

    /// Frontmost App Volume: the knob adjusts the gain of whatever app is in
    /// front, leaving the system volume alone.
    private func adjustAppVolume(bySteps steps: Double) {
        guard #available(macOS 14.4, *) else {
            showTransient("Needs macOS 14.4")
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier
        else {
            showTransient("n/a")
            return
        }
        let name = front.localizedName ?? bundleID
        let step = activeProfile().stepValue ?? defaults.double(forKey: Pref.step)
        switch appVolume.adjust(
            bundleID: bundleID, pid: front.processIdentifier, bySteps: steps * step) {
        case .adjusted(let gain):
            if hudEnabled {
                hud.show(volume: gain, muted: gain == 0)
            }
            showTransient("\(name) \(Int((gain * 100).rounded()))%")
        case .noAudio:
            showTransient("\(name): no audio")
        case .failed:
            showTransient("n/a")
        }
    }

    /// Verification recipe: `defaults write io.perimtr.powermate
    /// debugAppVolumeTest -string "pid:<pid>"` (or a bundle id), relaunch,
    /// and the log shows the engine coming up, the realtime statistics, and
    /// the teardown, with no knob involved. One-shot.
    @available(macOS 14.4, *)
    private func runAppVolumeDebugTest(_ target: String) {
        var pid: pid_t = 0
        var bundleID = target
        if target.hasPrefix("pid:"), let value = pid_t(target.dropFirst(4)) {
            pid = value
            bundleID = "debug.pid.\(value)"
        } else if let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == target }) {
            pid = app.processIdentifier
        }
        logger.info("debug: app volume test target \(bundleID, privacy: .public) pid \(pid, privacy: .public)")
        let result = appVolume.adjust(bundleID: bundleID, pid: pid, bySteps: -0.75)
        logger.info("debug: app volume adjust -> \(String(describing: result), privacy: .public)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            logger.info("debug: app volume stats \(self.appVolume.debugStats(bundleID: bundleID), privacy: .public)")
            _ = self.appVolume.adjust(bundleID: bundleID, pid: pid, bySteps: 1)
            logger.info("debug: app volume test done (gain restored)")
        }
    }

    private func toggleMute() {
        guard let device = SystemAudio.defaultOutputDevice() else {
            showTransient("n/a")
            return
        }
        let muted = !SystemAudio.isMuted(device)
        SystemAudio.setMuted(muted, of: device)
        feedbackVolume(SystemAudio.volume(of: device) ?? 0, muted: muted)
        refreshLED(now: true)
    }

    /// Whether the bezel should appear right now: the active profile can
    /// force it on or off per app; otherwise the global toggle decides.
    private var hudEnabled: Bool {
        switch activeProfile().hudOverride {
        case "shown": return true
        case "hidden": return false
        default: return defaults.bool(forKey: Pref.showHUD)
        }
    }

    /// Volume feedback: the floating HUD (or the menu bar readout when the
    /// HUD is disabled), plus the optional tick sound while turning.
    private func feedbackVolume(_ volume: Float32, muted: Bool) {
        if hudEnabled {
            hud.show(volume: Float(volume), muted: muted)
        } else {
            showTransient(muted ? "Muted" : "\(Int((volume * 100).rounded()))%")
        }
        if !muted, defaults.bool(forKey: Pref.tickSound),
           Date().timeIntervalSince(lastTick) > 0.15 {
            lastTick = Date()
            tick?.stop()
            tick?.volume = 0.4
            tick?.play()
        }
    }

    private func showPermissionNeeded() {
        statusLine.title = "PowerMate: Permission Required"
        permissionLine.isHidden = false
        if !askedForPermission {
            askedForPermission = true
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }

    // MARK: - LED

    private func refreshLED(now: Bool) {
        guard led != nil else { return }
        let elapsed = Date().timeIntervalSince(lastLEDSend)
        if now || elapsed >= 0.08 {
            sendLED()
        } else if !ledRefreshScheduled {
            ledRefreshScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
                self?.ledRefreshScheduled = false
                self?.sendLED()
            }
        }
    }

    private enum LEDState: Equatable {
        case steady(UInt8)
        case pulsing
    }

    private func sendLED() {
        lastLEDSend = Date()
        guard let led else { return }
        switch desiredLEDState() {
        case .pulsing:
            // Re-sending the pulse commands restarts the breathing cycle, so
            // only send them on the transition into the muted state.
            guard !ledIsPulsing else { return }
            ledIsPulsing = true
            // The one headless proof that the pulse engaged: LED echo reports
            // never reach this process (macOS swallows them), so log it.
            logger.info("pulse start speed=\(self.currentPulseSpeed().rawValue, privacy: .public) waveform=\(self.currentPulseWaveform().rawValue, privacy: .public)")
            led.setPulseMode(speed: currentPulseSpeed(), waveform: currentPulseWaveform())
            led.setPulsing(true)
        case .steady(let brightness):
            if ledIsPulsing {
                ledIsPulsing = false
                led.setPulsing(false)
            }
            led.setBrightness(brightness)
        }
    }

    private func desiredLEDState() -> LEDState {
        if isPaused { return .steady(0) }
        let pulseWhenMuted = defaults.bool(forKey: Pref.pulseWhenMuted)
        let muted = SystemAudio.defaultOutputDevice().map(SystemAudio.isMuted) ?? false
        switch defaults.integer(forKey: Pref.ledMode) {
        case 1:
            return muted && pulseWhenMuted ? .pulsing : .steady(200)
        case 2:
            return .steady(0)
        default:
            if muted { return pulseWhenMuted ? .pulsing : .steady(0) }
            guard let device = SystemAudio.defaultOutputDevice(),
                  let volume = SystemAudio.volume(of: device)
            else { return .steady(0) }
            return .steady(UInt8(min(255, max(4, Int(volume * 255)))))
        }
    }

    // MARK: - Stuck activity wedge watchdog

    /// Remaining timeout of a UserIsActive assertion naming the PowerMate,
    /// or nil when there is none. A healthy assertion drains toward zero
    /// and expires; phantom input re-arms it back to its full timeout.
    private func powerMateAssertionTimeLeft() -> Int? {
        var assertionsRef: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertionsRef) == kIOReturnSuccess,
              let byPid = assertionsRef?.takeRetainedValue() as? [AnyHashable: Any]
        else { return nil }
        for perProcess in byPid.values {
            guard let list = perProcess as? [[String: Any]] else { continue }
            for assertion in list {
                let details = assertion["Details"] as? String ?? ""
                guard details.contains("Griffin PowerMate") else { continue }
                return assertion["TimeoutTimeLeft"] as? Int ?? -1
            }
        }
        return nil
    }

    private func checkForWedge() {
        guard deviceConnected, hid.seized, led != nil,
              Date().timeIntervalSince(lastWedgeHeal) > 600,
              let first = powerMateAssertionTimeLeft() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.deviceConnected, self.hid.seized,
                  let second = self.powerMateAssertionTimeLeft() else { return }
            // Draining is healthy; anything else means it was re-armed.
            guard second >= first else { return }
            self.lastWedgeHeal = Date()
            logger.info("Stuck activity wedge detected (assertion re-arming while seized); re-enumerating the device")
            self.led?.reenumerate()
        }
    }

    // MARK: - Transient readout next to the menu bar icon

    private func showTransient(_ text: String, duration: TimeInterval = 1.2) {
        statusItem.button?.title = " " + text
        titleTimer?.invalidate()
        titleTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            guard let self else { return }
            // Restore the discovery label if the menu has never been opened.
            self.statusItem.button?.title =
                self.defaults.bool(forKey: Pref.didDiscoverMenu) ? "" : " PowerMate"
        }
    }

    // MARK: - Menu actions

    @objc private func chooseSensitivity(_ sender: NSMenuItem) {
        guard let step = sender.representedObject as? Double else { return }
        defaults.set(step, forKey: Pref.step)
    }

    @objc private func chooseBinding(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? [String], ctx.count == 3 else { return }
        let (scope, field, raw) = (ctx[0], ctx[1], ctx[2])
        setBinding(scope: scope, field: field, raw: raw)
        // Picking a rotation shortcut implies the Run Shortcuts mode.
        if field == "rotateCW" || field == "rotateCCW" {
            setBinding(scope: scope, field: "rotate", raw: RotateMode.runShortcuts.rawValue)
        }
        refreshDoubleClickEnabled()
        // Kick off the permission flow as soon as an event-posting action is bound.
        if needsAccessibility, !MediaKeys.trusted {
            accessibilityNeeded()
        }
    }

    private func setBinding(scope: String, field: String, raw: String) {
        if scope.isEmpty {
            defaults.set(raw, forKey: prefKey(for: field))
        } else {
            store.set(field: field, rawValue: raw, for: scope)
        }
    }

    // MARK: - App profiles menu

    /// Rebuilt on every menu open: shows which profile is active, one submenu
    /// per configured app, and an add entry for the current frontmost app.
    private func rebuildProfilesMenu() {
        guard let menu = profilesRoot.submenu else { return }
        menu.removeAllItems()

        let front = NSWorkspace.shared.frontmostApplication
        let frontID = front?.bundleIdentifier

        let activeText: String
        if let pinned = pinnedProfileID {
            activeText = "Active: \(store.displayName(for: pinned) ?? "Default") (pinned)"
        } else {
            let activeName = frontID.flatMap { store.displayName(for: $0) }
            activeText = "Active: \(activeName ?? "Default") (follows frontmost app)"
        }
        let status = NSMenuItem(title: activeText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let follow = NSMenuItem(
            title: "Follow Frontmost App", action: #selector(clearPin), keyEquivalent: "")
        follow.target = self
        follow.state = pinnedProfileID == nil ? .on : .off
        menu.addItem(follow)
        menu.addItem(.separator())

        for entry in store.appProfiles {
            let appItem = NSMenuItem(title: entry.name, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let submenus: [(String, NSMenu)] = [
                ("Rotate", rotateGestureMenu(scope: entry.bundleID, profile: entry.profile)),
                ("Click", buttonActionMenu(scope: entry.bundleID, field: "click",
                                           current: entry.profile.click)),
                ("Double-Click", buttonActionMenu(scope: entry.bundleID, field: "doubleClick",
                                                  current: entry.profile.doubleClick)),
                ("Long Press", buttonActionMenu(scope: entry.bundleID, field: "longPress",
                                                current: entry.profile.longPress)),
                ("Press & Turn", pressTurnGestureMenu(scope: entry.bundleID,
                                                      current: entry.profile.pressTurn)),
                ("Sensitivity", sensitivityGestureMenu(scope: entry.bundleID,
                                                       current: entry.profile.stepOverride)),
                ("Volume HUD", hudGestureMenu(scope: entry.bundleID,
                                              current: entry.profile.hudOverride)),
            ]
            for (title, submenu) in submenus {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = submenu
                sub.addItem(item)
            }
            sub.addItem(.separator())
            let pin = NSMenuItem(
                title: "Pin This Profile (use in every app)",
                action: #selector(togglePin(_:)), keyEquivalent: "")
            pin.target = self
            pin.representedObject = entry.bundleID
            pin.state = pinnedProfileID == entry.bundleID ? .on : .off
            sub.addItem(pin)
            let remove = NSMenuItem(
                title: "Remove Profile", action: #selector(removeProfile(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = entry.bundleID
            sub.addItem(remove)
            appItem.submenu = sub
            menu.addItem(appItem)
        }
        if !store.appProfiles.isEmpty {
            menu.addItem(.separator())
        }

        if let front, let frontID,
           frontID != Bundle.main.bundleIdentifier, !store.hasProfile(for: frontID) {
            let name = front.localizedName ?? frontID
            let add = NSMenuItem(
                title: "Add Profile for “\(name)”",
                action: #selector(addProfile(_:)), keyEquivalent: "")
            add.target = self
            add.representedObject = [frontID, name]
            menu.addItem(add)
        } else {
            let hint = NSMenuItem(
                title: "Switch to an app to add its profile",
                action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        let custom = NSMenuItem(
            title: "New Custom Profile…",
            action: #selector(addCustomProfile), keyEquivalent: "")
        custom.target = self
        menu.addItem(custom)
    }

    /// A standalone mode not tied to any app: it never activates
    /// automatically, only via pinning or the Switch Profile gesture.
    @objc private func addCustomProfile() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "New Custom Profile"
        alert.informativeText = "A standalone mode that never activates automatically. "
            + "Switch to it by pinning or with the Switch Profile gesture."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 230, height: 24))
        field.placeholderString = "Name (e.g. Lights)"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.addProfile(for: "custom:" + UUID().uuidString, appName: name,
                         copying: store.defaultProfile)
        showTransient("Added \(name). Edit it under App Profiles", duration: 3.5)
    }

    @objc private func addProfile(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        store.addProfile(for: pair[0], appName: pair[1], copying: store.defaultProfile)
        // A new profile is a copy of the defaults - nothing changes until edited.
        showTransient("Added. Now edit it under App Profiles", duration: 3.5)
    }

    @objc private func removeProfile(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        store.removeProfile(for: bundleID)
        if pinnedProfileID == bundleID {
            pinnedProfileID = nil
            updateStatusLine()
        }
        refreshDoubleClickEnabled()
    }

    @objc private func togglePin(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        pinnedProfileID = pinnedProfileID == bundleID ? nil : bundleID
        updateStatusLine()
        refreshLED(now: true)
    }

    @objc private func clearPin() {
        pinnedProfileID = nil
        updateStatusLine()
        refreshLED(now: true)
    }

    @objc private func togglePaused() {
        isPaused.toggle()
        refreshLED(now: true)
        showTransient(isPaused ? "Paused" : "Active")
    }

    @objc private func toggleHUD() {
        defaults.set(!defaults.bool(forKey: Pref.showHUD), forKey: Pref.showHUD)
    }

    @objc private func toggleTickSound() {
        defaults.set(!defaults.bool(forKey: Pref.tickSound), forKey: Pref.tickSound)
    }

    @objc private func toggleReleaseOnDisplaySleep() {
        defaults.set(!defaults.bool(forKey: Pref.releaseOnDisplaySleep),
                     forKey: Pref.releaseOnDisplaySleep)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSMutableAttributedString(
            string: "Brings the Griffin PowerMate USB knob back to life on modern macOS.\n\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor,
            ])
        credits.append(NSAttributedString(
            string: "github.com/perimtr/powermate",
            attributes: [
                .link: URL(string: "https://github.com/perimtr/powermate")!,
                .font: NSFont.systemFont(ofSize: 11),
            ]))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleReverse() {
        defaults.set(!defaults.bool(forKey: Pref.reverse), forKey: Pref.reverse)
    }

    @objc private func chooseLEDMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? Int else { return }
        defaults.set(mode, forKey: Pref.ledMode)
        refreshLED(now: true)
    }

    private func currentPulseSpeed() -> PulseSpeed {
        PulseSpeed(rawValue: defaults.string(forKey: Pref.pulseSpeed) ?? "") ?? .normal
    }

    private func currentPulseWaveform() -> PulseWaveform {
        PulseWaveform(rawValue: defaults.string(forKey: Pref.pulseWaveform) ?? "") ?? .tableA
    }

    /// Retune a live breathe so speed and waveform changes show immediately.
    private func resendPulseMode() {
        guard ledIsPulsing else { return }
        led?.setPulseMode(speed: currentPulseSpeed(), waveform: currentPulseWaveform())
    }

    @objc private func choosePulseSpeed(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        defaults.set(raw, forKey: Pref.pulseSpeed)
        resendPulseMode()
    }

    @objc private func choosePulseWaveform(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        defaults.set(raw, forKey: Pref.pulseWaveform)
        resendPulseMode()
    }

    @objc private func togglePulseWhenMuted() {
        defaults.set(!defaults.bool(forKey: Pref.pulseWhenMuted), forKey: Pref.pulseWhenMuted)
        refreshLED(now: true)
    }

    @objc private func togglePulseWhileAsleep() {
        let newValue = !defaults.bool(forKey: Pref.pulseWhileAsleep)
        defaults.set(newValue, forKey: Pref.pulseWhileAsleep)
        led?.setPulseAsleep(newValue)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't update the login item"
            alert.informativeText = error.localizedDescription
                + "\n\nTip: install the app to /Applications first (make install)."
            alert.runModal()
        }
    }

    @objc private func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }
}
