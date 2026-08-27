import Foundation

/// A full set of knob bindings. The default profile lives in the individual
/// preference keys (editable from the top-level menus); per-app overrides are
/// stored as dictionaries keyed by bundle identifier.
struct Profile {
    var rotate: RotateMode = .volume
    var click: KnobAction = .playPause
    var doubleClick: KnobAction = .nextTrack
    var longPress: KnobAction = .mute
    var pressTurn: PressTurnMode = .skipTracks
    /// Shortcut names for the Run Shortcuts rotate mode; empty = unset.
    var rotateCW: String = ""
    var rotateCCW: String = ""
    /// Volume step override as a string ("" = use the global sensitivity).
    var stepOverride: String = ""

    var stepValue: Double? {
        stepOverride.isEmpty ? nil : Double(stepOverride)
    }

    init(rotate: RotateMode, click: KnobAction, doubleClick: KnobAction,
         longPress: KnobAction, pressTurn: PressTurnMode,
         rotateCW: String = "", rotateCCW: String = "", stepOverride: String = "") {
        self.rotate = rotate
        self.click = click
        self.doubleClick = doubleClick
        self.longPress = longPress
        self.pressTurn = pressTurn
        self.rotateCW = rotateCW
        self.rotateCCW = rotateCCW
        self.stepOverride = stepOverride
    }

    init(dict: [String: String]) {
        rotate = RotateMode(rawValue: dict["rotate"] ?? "") ?? .volume
        click = KnobAction(raw: dict["click"] ?? "playPause")
        doubleClick = KnobAction(raw: dict["doubleClick"] ?? "nextTrack")
        longPress = KnobAction(raw: dict["longPress"] ?? "mute")
        pressTurn = PressTurnMode(rawValue: dict["pressTurn"] ?? "") ?? .skipTracks
        rotateCW = dict["rotateCW"] ?? ""
        rotateCCW = dict["rotateCCW"] ?? ""
        stepOverride = dict["step"] ?? ""
    }

    func asDict(name: String) -> [String: String] {
        [
            "name": name,
            "rotate": rotate.rawValue,
            "click": click.raw,
            "doubleClick": doubleClick.raw,
            "longPress": longPress.raw,
            "pressTurn": pressTurn.rawValue,
            "rotateCW": rotateCW,
            "rotateCCW": rotateCCW,
            "step": stepOverride,
        ]
    }
}

final class ProfileStore {
    static let profilesKey = "appProfiles"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private var raw: [String: [String: String]] {
        get { defaults.dictionary(forKey: Self.profilesKey) as? [String: [String: String]] ?? [:] }
        set { defaults.set(newValue, forKey: Self.profilesKey) }
    }

    /// The fallback bindings, read from the top-level preference keys.
    var defaultProfile: Profile {
        Profile(
            rotate: RotateMode(rawValue: defaults.string(forKey: Pref.rotateMode) ?? "") ?? .volume,
            click: KnobAction(raw: defaults.string(forKey: Pref.clickAction) ?? "playPause"),
            doubleClick: KnobAction(raw: defaults.string(forKey: Pref.doubleClickAction) ?? "nextTrack"),
            longPress: KnobAction(raw: defaults.string(forKey: Pref.longPressAction) ?? "mute"),
            pressTurn: PressTurnMode(rawValue: defaults.string(forKey: Pref.pressTurnMode) ?? "") ?? .skipTracks,
            rotateCW: defaults.string(forKey: Pref.rotateShortcutCW) ?? "",
            rotateCCW: defaults.string(forKey: Pref.rotateShortcutCCW) ?? "")
    }

    var appProfiles: [(bundleID: String, name: String, profile: Profile)] {
        raw.map { (bundleID: $0.key, name: $0.value["name"] ?? $0.key, profile: Profile(dict: $0.value)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func hasProfile(for bundleID: String) -> Bool {
        raw[bundleID] != nil
    }

    /// The bindings in effect for the given frontmost app.
    func profile(for bundleID: String?) -> Profile {
        guard let bundleID, let dict = raw[bundleID] else { return defaultProfile }
        return Profile(dict: dict)
    }

    func displayName(for bundleID: String) -> String? {
        raw[bundleID]?["name"]
    }

    func addProfile(for bundleID: String, appName: String, copying profile: Profile) {
        raw[bundleID] = profile.asDict(name: appName)
    }

    func set(field: String, rawValue: String, for bundleID: String) {
        guard var dict = raw[bundleID] else { return }
        dict[field] = rawValue
        raw[bundleID] = dict
    }

    func removeProfile(for bundleID: String) {
        var current = raw
        current.removeValue(forKey: bundleID)
        raw = current
    }
}
