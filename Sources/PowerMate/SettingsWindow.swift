import AppKit
import ServiceManagement
import SwiftUI

/// Hooks back into AppDelegate for the side effects a settings change
/// carries beyond its defaults write (LED refreshes, gesture re-wiring,
/// login item registration, update checks, profile pinning).
struct SettingsActions {
    var ledChanged: () -> Void = {}
    var pulseTuningChanged: () -> Void = {}
    var pulseAsleepChanged: (Bool) -> Void = { _ in }
    var bindingsChanged: () -> Void = {}
    var checkForUpdates: () -> Void = {}
    var availableUpdate: () -> String? = { nil }
    var pinnedProfileID: () -> String? = { nil }
    var setPinnedProfileID: (String?) -> Void = { _ in }
}

/// Write-through view model over ProfileStore so the Profiles tab reloads
/// when entries change.
final class ProfilesModel: ObservableObject {
    struct Entry: Identifiable {
        let id: String
        let name: String
        let profile: Profile
    }

    @Published private(set) var entries: [Entry] = []
    private let store: ProfileStore
    private let onEdit: () -> Void

    init(store: ProfileStore, onEdit: @escaping () -> Void) {
        self.store = store
        self.onEdit = onEdit
        reload()
    }

    func reload() {
        entries = store.appProfiles.map {
            Entry(id: $0.bundleID, name: $0.name, profile: $0.profile)
        }
    }

    func set(field: String, raw: String, for bundleID: String) {
        store.set(field: field, rawValue: raw, for: bundleID)
        reload()
        onEdit()
    }

    func add(bundleID: String, name: String) {
        store.addProfile(for: bundleID, appName: name, copying: store.defaultProfile)
        reload()
        onEdit()
    }

    func remove(bundleID: String) {
        store.removeProfile(for: bundleID)
        reload()
        onEdit()
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(actions: SettingsActions, store: ProfileStore) {
        let model = ProfilesModel(store: store, onEdit: actions.bindingsChanged)
        let root = SettingsRootView(actions: actions)
            .environmentObject(model)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "PowerMate Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 600, height: 560))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        self.model = model
    }

    private var model: ProfilesModel?

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        ShortcutRunner.shared.refreshAvailable()
        model?.reload()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Root

private struct SettingsRootView: View {
    let actions: SettingsActions

    var body: some View {
        TabView {
            KnobTab(actions: actions)
                .tabItem { Label("Knob", systemImage: "dial.medium") }
            LEDTab(actions: actions)
                .tabItem { Label("LED", systemImage: "lightbulb") }
            ProfilesTab(actions: actions)
                .tabItem { Label("Profiles", systemImage: "square.on.square") }
            GeneralTab(actions: actions)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 600, height: 540)
    }
}

/// Picker content for a button gesture: the fixed actions, then every
/// shortcut from the Shortcuts app.
private struct ActionPickerContent: View {
    var body: some View {
        ForEach(KnobAction.fixed, id: \.raw) { action in
            Text(action.title).tag(action.raw)
        }
        if !ShortcutRunner.shared.available.isEmpty {
            Divider()
            ForEach(ShortcutRunner.shared.available, id: \.self) { name in
                Text("Shortcut: \(name)").tag("shortcut:" + name)
            }
        }
    }
}

private let sensitivityChoices: [(title: String, raw: String)] = [
    ("Fine (0.5%)", "0.005"),
    ("Normal (1%)", "0.01"),
    ("Fast (2%)", "0.02"),
    ("Extra Fast (5%)", "0.05"),
]

// MARK: - Knob tab

private struct KnobTab: View {
    let actions: SettingsActions
    @AppStorage(Pref.rotateMode) private var rotateMode = RotateMode.volume.rawValue
    @AppStorage(Pref.clickAction) private var click = KnobAction.playPause.raw
    @AppStorage(Pref.doubleClickAction) private var doubleClick = KnobAction.nextTrack.raw
    @AppStorage(Pref.longPressAction) private var longPress = KnobAction.mute.raw
    @AppStorage(Pref.pressTurnMode) private var pressTurn = PressTurnMode.skipTracks.rawValue
    @AppStorage(Pref.rotateShortcutCW) private var rotateCW = ""
    @AppStorage(Pref.rotateShortcutCCW) private var rotateCCW = ""
    @AppStorage(Pref.step) private var step = 0.01
    @AppStorage(Pref.reverse) private var reverse = false

    var body: some View {
        Form {
            Section("Rotation") {
                Picker("Rotate", selection: $rotateMode) {
                    ForEach(RotateMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                Picker("Knob Sensitivity", selection: Binding(
                    get: { String(step) },
                    set: { step = Double($0) ?? 0.01 }
                )) {
                    ForEach(sensitivityChoices, id: \.raw) { choice in
                        Text(choice.title).tag(choice.raw)
                    }
                }
                Toggle("Reverse Direction", isOn: $reverse)
            }
            if rotateMode == RotateMode.runShortcuts.rawValue {
                Section("Rotation Shortcuts") {
                    ShortcutPicker(title: "Clockwise", selection: $rotateCW)
                    ShortcutPicker(title: "Counter-Clockwise", selection: $rotateCCW)
                }
            }
            Section("Button") {
                Picker("Click", selection: $click) { ActionPickerContent() }
                Picker("Double-Click", selection: $doubleClick) { ActionPickerContent() }
                Picker("Long Press", selection: $longPress) { ActionPickerContent() }
                Picker("Press & Turn", selection: $pressTurn) {
                    ForEach(PressTurnMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: click) { _ in actions.bindingsChanged() }
        .onChange(of: doubleClick) { _ in actions.bindingsChanged() }
        .onChange(of: longPress) { _ in actions.bindingsChanged() }
        .onChange(of: rotateMode) { _ in actions.bindingsChanged() }
        .onChange(of: pressTurn) { _ in actions.bindingsChanged() }
    }
}

private struct ShortcutPicker: View {
    let title: String
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            Text("None").tag("")
            ForEach(ShortcutRunner.shared.available, id: \.self) { name in
                Text(name).tag(name)
            }
        }
    }
}

// MARK: - LED tab

private struct LEDTab: View {
    let actions: SettingsActions
    @AppStorage(Pref.ledMode) private var ledMode = 0
    @AppStorage(Pref.pulseWhenMuted) private var pulseWhenMuted = true
    @AppStorage(Pref.pulseWhileAsleep) private var pulseWhileAsleep = false
    @AppStorage(Pref.pulseSpeed) private var pulseSpeed = PulseSpeed.normal.rawValue
    @AppStorage(Pref.pulseWaveform) private var pulseWaveform = PulseWaveform.tableA.rawValue

    var body: some View {
        Form {
            Section("Knob LED") {
                Picker("Brightness", selection: $ledMode) {
                    Text("Follow Volume").tag(0)
                    Text("Always On").tag(1)
                    Text("Off").tag(2)
                }
                Toggle("Pulse When Muted", isOn: $pulseWhenMuted)
                    .disabled(ledMode == 2)
                Toggle("Pulse While Mac Sleeps", isOn: $pulseWhileAsleep)
            }
            Section("Pulse") {
                Picker("Speed", selection: $pulseSpeed) {
                    ForEach(PulseSpeed.allCases, id: \.rawValue) { speed in
                        Text(speed.title).tag(speed.rawValue)
                    }
                }
                Picker("Waveform", selection: $pulseWaveform) {
                    ForEach(PulseWaveform.allCases, id: \.rawValue) { waveform in
                        Text(waveform.title).tag(waveform.rawValue)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: ledMode) { _ in actions.ledChanged() }
        .onChange(of: pulseWhenMuted) { _ in actions.ledChanged() }
        .onChange(of: pulseWhileAsleep) { value in actions.pulseAsleepChanged(value) }
        .onChange(of: pulseSpeed) { _ in actions.pulseTuningChanged() }
        .onChange(of: pulseWaveform) { _ in actions.pulseTuningChanged() }
    }
}

// MARK: - Profiles tab

private struct ProfilesTab: View {
    let actions: SettingsActions
    @EnvironmentObject private var model: ProfilesModel
    @State private var selection: String?
    @State private var askingCustomName = false
    @State private var customName = ""

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    List(model.entries, selection: $selection) { entry in
                        Text(entry.name).tag(entry.id)
                    }
                    HStack(spacing: 12) {
                        Menu {
                            Button("App…") { addApp() }
                            Button("Custom…") {
                                customName = ""
                                askingCustomName = true
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 36)
                        Button {
                            if let selection { model.remove(bundleID: selection) }
                            selection = nil
                        } label: {
                            Image(systemName: "minus")
                        }
                        .buttonStyle(.borderless)
                        .disabled(selection == nil)
                        Spacer()
                    }
                    .padding(8)
                }
                .frame(minWidth: 170, maxWidth: 220)

                if let selection,
                   let entry = model.entries.first(where: { $0.id == selection }) {
                    ProfileEditor(entry: entry, actions: actions)
                        .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 6) {
                        Text(model.entries.isEmpty
                             ? "No profiles yet" : "Select a profile")
                            .foregroundColor(.secondary)
                        Text("A profile changes what the knob does while that app is frontmost.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .alert("New Custom Profile", isPresented: $askingCustomName) {
            TextField("Name (e.g. Lights)", text: $customName)
            Button("Create") {
                let name = customName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                let id = "custom:" + UUID().uuidString
                model.add(bundleID: id, name: name)
                selection = id
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A standalone mode that never activates automatically; switch to it by pinning or the Switch Profile gesture.")
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the app this profile applies to"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier
        else { return }
        let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        model.add(bundleID: bundleID, name: name)
        selection = bundleID
    }
}

private struct ProfileEditor: View {
    let entry: ProfilesModel.Entry
    let actions: SettingsActions
    @EnvironmentObject private var model: ProfilesModel

    var body: some View {
        Form {
            Section(entry.name) {
                Picker("Rotate", selection: binding(field: "rotate", current: entry.profile.rotate.rawValue)) {
                    ForEach(RotateMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                Picker("Click", selection: binding(field: "click", current: entry.profile.click.raw)) {
                    ActionPickerContent()
                }
                Picker("Double-Click", selection: binding(field: "doubleClick", current: entry.profile.doubleClick.raw)) {
                    ActionPickerContent()
                }
                Picker("Long Press", selection: binding(field: "longPress", current: entry.profile.longPress.raw)) {
                    ActionPickerContent()
                }
                Picker("Press & Turn", selection: binding(field: "pressTurn", current: entry.profile.pressTurn.rawValue)) {
                    ForEach(PressTurnMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
            }
            if entry.profile.rotate == .runShortcuts {
                Section("Rotation Shortcuts") {
                    Picker("Clockwise", selection: binding(field: "rotateCW", current: entry.profile.rotateCW)) {
                        Text("None").tag("")
                        ForEach(ShortcutRunner.shared.available, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Counter-Clockwise", selection: binding(field: "rotateCCW", current: entry.profile.rotateCCW)) {
                        Text("None").tag("")
                        ForEach(ShortcutRunner.shared.available, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            Section {
                Picker("Sensitivity", selection: binding(field: "step", current: entry.profile.stepOverride)) {
                    Text("Use Default").tag("")
                    ForEach(sensitivityChoices, id: \.raw) { choice in
                        Text(choice.title).tag(choice.raw)
                    }
                }
                Picker("Volume HUD", selection: binding(field: "hud", current: entry.profile.hudOverride)) {
                    Text("Use Default").tag("")
                    Text("Shown").tag("shown")
                    Text("Hidden").tag("hidden")
                }
                Toggle("Pinned (active in every app)", isOn: Binding(
                    get: { actions.pinnedProfileID() == entry.id },
                    set: { actions.setPinnedProfileID($0 ? entry.id : nil) }
                ))
            }
        }
        .formStyle(.grouped)
        .id(entry.id)
    }

    private func binding(field: String, current: String) -> Binding<String> {
        Binding(
            get: { current },
            set: { model.set(field: field, raw: $0, for: entry.id) }
        )
    }
}

// MARK: - General tab

private struct GeneralTab: View {
    let actions: SettingsActions
    @AppStorage(Pref.showHUD) private var showHUD = true
    @AppStorage(Pref.tickSound) private var tickSound = false
    @AppStorage(Pref.blockMusicLaunch) private var blockMusic = false
    @AppStorage(Pref.releaseOnDisplaySleep) private var releaseOnSleep = true
    @AppStorage(Pref.autoUpdateCheck) private var autoUpdate = true
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Feedback") {
                Toggle("Volume HUD", isOn: $showHUD)
                Toggle("Sound When Turning", isOn: $tickSound)
            }
            Section("Behavior") {
                Toggle("Stop Apple Music Auto-Launch", isOn: $blockMusic)
                Toggle("Release Knob While Display Sleeps", isOn: $releaseOnSleep)
                Toggle("Start at Login", isOn: Binding(
                    get: { loginEnabled },
                    set: { setLogin($0) }
                ))
            }
            Section("Updates") {
                Toggle("Check for Updates Automatically", isOn: $autoUpdate)
                HStack {
                    if let version = actions.availableUpdate() {
                        Text("PowerMate \(version) is available")
                    } else {
                        Text("Version \(Self.version)")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Check Now") { actions.checkForUpdates() }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: showHUD) { _ in actions.ledChanged() }
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private func setLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginEnabled = enable
        } catch {
            loginEnabled = SMAppService.mainApp.status == .enabled
        }
    }
}
