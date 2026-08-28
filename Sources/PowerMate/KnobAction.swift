import Foundation

/// What a button gesture (click, double-click, long press) can trigger.
/// Serialized as a raw string; shortcuts encode their name after a prefix so
/// they fit the same profile storage as the fixed actions.
enum KnobAction: Equatable, Hashable {
    case playPause
    case mute
    case nextTrack
    case previousTrack
    case space
    case cycleProfile
    case cycleAudioOutput
    case none
    case shortcut(String)

    private static let shortcutPrefix = "shortcut:"

    /// The fixed, non-parameterized actions, in menu order.
    static let fixed: [KnobAction] = [
        .playPause, .mute, .nextTrack, .previousTrack, .space, .cycleProfile,
        .cycleAudioOutput, .none,
    ]

    init(raw: String) {
        switch raw {
        case "playPause": self = .playPause
        case "mute": self = .mute
        case "nextTrack": self = .nextTrack
        case "previousTrack": self = .previousTrack
        case "space": self = .space
        case "cycleProfile": self = .cycleProfile
        case "cycleAudioOutput": self = .cycleAudioOutput
        case "none": self = .none
        default:
            if raw.hasPrefix(Self.shortcutPrefix) {
                self = .shortcut(String(raw.dropFirst(Self.shortcutPrefix.count)))
            } else {
                self = .none
            }
        }
    }

    var raw: String {
        switch self {
        case .playPause: return "playPause"
        case .mute: return "mute"
        case .nextTrack: return "nextTrack"
        case .previousTrack: return "previousTrack"
        case .space: return "space"
        case .cycleProfile: return "cycleProfile"
        case .cycleAudioOutput: return "cycleAudioOutput"
        case .none: return "none"
        case .shortcut(let name): return Self.shortcutPrefix + name
        }
    }

    var title: String {
        switch self {
        case .playPause: return "Play / Pause"
        case .mute: return "Mute"
        case .nextTrack: return "Next Track"
        case .previousTrack: return "Previous Track"
        case .space: return "Space Bar"
        case .cycleProfile: return "Switch Profile (cycle)"
        case .cycleAudioOutput: return "Cycle Audio Output"
        case .none: return "Do Nothing"
        case .shortcut(let name): return "Shortcut: \(name)"
        }
    }
}

/// What turning the knob while the button is held does.
enum PressTurnMode: String, CaseIterable {
    case skipTracks
    case fineVolume
    case none

    var title: String {
        switch self {
        case .skipTracks: return "Skip Tracks"
        case .fineVolume: return "Fine Volume"
        case .none: return "Do Nothing"
        }
    }
}

/// What turning the knob does. Volume is handled through CoreAudio; scroll
/// and arrows synthesize input events (Accessibility needed); Run Shortcuts
/// steps through a clockwise/counter-clockwise shortcut pair.
enum RotateMode: String, CaseIterable {
    case volume
    case scroll
    case scrollHorizontal
    case arrowsHorizontal
    case arrowsVertical
    case runShortcuts
    case none

    var title: String {
        switch self {
        case .volume: return "System Volume"
        case .scroll: return "Scroll"
        case .scrollHorizontal: return "Scroll Sideways"
        case .arrowsHorizontal: return "Arrow Keys ← →"
        case .arrowsVertical: return "Arrow Keys ↑ ↓"
        case .runShortcuts: return "Run Shortcuts (choose below)"
        case .none: return "Do Nothing"
        }
    }
}
