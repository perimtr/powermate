import CoreMIDI
import Foundation

/// A second way to drive the app: any MIDI controller with a knob.
///
/// Prototype. The point is that nothing downstream of the gestures cares
/// where they came from, so a MIDI encoder reaches the same volume, app
/// volume, profile and shortcut machinery the Griffin knob does. Far more
/// people own a MIDI controller with an encoder than own a PowerMate.
///
/// Compared with the USB knob this is pleasantly boring: CoreMIDI needs no
/// exclusive open, no TCC permission, and holds no power assertions, so
/// none of the seize, wedge or display-sleep handling applies.
///
/// One knob and one button are learned from what the controller actually
/// sends: the first control change becomes the knob, the first note the
/// button, both remembered until relearned.
final class MIDISource {
    var onRotate: ((Int) -> Void)?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onLongPress: (() -> Void)?
    var onPressedRotate: ((Int) -> Void)?
    /// Human-readable note when a control is learned, for the menu bar.
    var onLearned: ((String) -> Void)?

    var doubleClickEnabled: Bool {
        get { gestures.doubleClickEnabled }
        set { gestures.doubleClickEnabled = newValue }
    }

    /// A single message never moves the knob more than this. Controllers
    /// emit their whole state on connect, faders sweep, and a value meant
    /// as a position can arrive while relative mode is selected. Any of
    /// those would otherwise slam the volume from one message.
    private static let maxDeltaPerMessage = 8
    /// How many messages a control must send before it can claim the knob.
    /// One stray value should not win: controllers dump every CC at
    /// startup, and a sleeve brushing a fader sends one message too.
    private static let messagesToLearn = 3
    /// Those messages have to arrive together, or they are not a gesture.
    private static let learnWindow: TimeInterval = 2

    private let defaults = UserDefaults.standard
    private let gestures = KnobGestures()
    private var learnCandidates: [Int: (count: Int, firstSeen: Date)] = [:]
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var started = false
    /// Last absolute value seen, to turn a potentiometer into deltas.
    private var lastValue: Int?

    private var learnedCC: Int {
        get { defaults.object(forKey: Pref.midiKnobCC) as? Int ?? -1 }
        set { defaults.set(newValue, forKey: Pref.midiKnobCC) }
    }
    private var learnedNote: Int {
        get { defaults.object(forKey: Pref.midiButtonNote) as? Int ?? -1 }
        set { defaults.set(newValue, forKey: Pref.midiButtonNote) }
    }
    /// How the knob reports movement. Potentiometers send a position;
    /// endless encoders send ticks, in one of two conventions that look
    /// nothing alike, so the controller decides which one applies.
    enum EncoderMode: String {
        /// A position, 0 to 127. The delta is the change since last time.
        case absolute
        /// Two's complement ticks: 1...63 clockwise, 65...127 the other way.
        /// What most endless encoders send.
        case relative
        /// Signed bit ticks: 65...127 clockwise, 1...63 counter-clockwise.
        /// Used by Mackie-style controllers, and the exact inverse of the
        /// above, so guessing wrong reverses the knob rather than breaking it.
        case relativeSigned
    }

    private var encoderMode: EncoderMode {
        EncoderMode(rawValue: defaults.string(forKey: Pref.midiEncoderMode) ?? "")
            ?? .absolute
    }

    init() {
        gestures.onRotate = { [weak self] delta in self?.onRotate?(delta) }
        gestures.onClick = { [weak self] in self?.onClick?() }
        gestures.onDoubleClick = { [weak self] in self?.onDoubleClick?() }
        gestures.onLongPress = { [weak self] in self?.onLongPress?() }
        gestures.onPressedRotate = { [weak self] dir in self?.onPressedRotate?(dir) }
    }

    func start() {
        guard !started else { return }
        let notifyBlock: MIDINotifyBlock = { [weak self] message in
            // Controllers plugged in later should just work.
            if message.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.connectAllSources() }
            }
        }
        guard MIDIClientCreateWithBlock(
            "PowerMate" as CFString, &client, notifyBlock) == noErr
        else {
            logger.error("MIDI: could not create client")
            return
        }
        let status = MIDIInputPortCreateWithProtocol(
            client, "PowerMate Input" as CFString, ._1_0, &port
        ) { [weak self] eventList, _ in
            // CoreMIDI delivers on its own thread; the gesture timers and
            // every handler downstream expect the main thread.
            // A packet's words are a fixed-size tuple, so read the live
            // count and rebind rather than trusting a fixed shape.
            var words: [UInt32] = []
            for packet in eventList.unsafeSequence() {
                let count = min(Int(packet.pointee.wordCount), 64)
                guard count > 0 else { continue }
                withUnsafePointer(to: packet.pointee.words) { tuple in
                    tuple.withMemoryRebound(to: UInt32.self, capacity: 64) { buffer in
                        for index in 0..<count { words.append(buffer[index]) }
                    }
                }
            }
            guard !words.isEmpty else { return }
            DispatchQueue.main.async {
                for word in words { self?.handle(word: word) }
            }
        }
        guard status == noErr else {
            logger.error("MIDI: could not create input port (\(status, privacy: .public))")
            return
        }
        started = true
        connectAllSources()
        logger.info("MIDI enabled: knob=\(self.describeLearned(), privacy: .public)")
    }

    func stop() {
        guard started else { return }
        started = false
        gestures.reset()
        lastValue = nil
        if port != 0 { MIDIPortDispose(port); port = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        logger.info("MIDI disabled")
    }

    /// Forget the learned controls; the next knob turn and button press
    /// claim their places.
    func relearn() {
        learnedCC = -1
        learnedNote = -1
        lastValue = nil
        learnCandidates.removeAll()
        logger.info("MIDI: relearning, turn a knob then press a button")
    }

    var isRunning: Bool { started }

    func describeLearned() -> String {
        let cc = learnedCC >= 0 ? "CC \(learnedCC)" : "unlearned"
        let note = learnedNote >= 0 ? "note \(learnedNote)" : "unlearned"
        return "\(cc), button \(note)"
    }

    private func connectAllSources() {
        guard started else { return }
        let count = MIDIGetNumberOfSources()
        guard count > 0 else {
            logger.info("MIDI: no sources present")
            return
        }
        for index in 0..<count {
            let source = MIDIGetSource(index)
            // Reconnecting an already-connected source is harmless.
            MIDIPortConnectSource(port, source, nil)
            logger.info("MIDI source: \(Self.name(of: source), privacy: .public)")
        }
    }

    private static func name(of endpoint: MIDIEndpointRef) -> String {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(
            endpoint, kMIDIPropertyDisplayName, &value) == noErr, let value
        else { return "unnamed" }
        return value.takeRetainedValue() as String
    }

    /// One MIDI 1.0 universal packet word.
    private func handle(word: UInt32) {
        // Message type 0x2 is a MIDI 1.0 channel voice message.
        guard (word >> 28) & 0xF == 0x2 else { return }
        let status = UInt8((word >> 16) & 0xFF)
        let data1 = Int((word >> 8) & 0x7F)
        let data2 = Int(word & 0x7F)
        let kind = status & 0xF0

        switch kind {
        case 0xB0:  // control change
            if learnedCC < 0 {
                guard learn(candidate: data1) else { return }
            }
            guard data1 == learnedCC else { return }
            if let delta = rotationDelta(for: data2), delta != 0 {
                let clamped = max(-Self.maxDeltaPerMessage,
                                  min(Self.maxDeltaPerMessage, delta))
                logger.info("MIDI rotate delta=\(clamped, privacy: .public)")
                gestures.rotated(clamped)
            }
        case 0x90 where data2 > 0:  // note on
            if learnedNote < 0 {
                learnedNote = data1
                logger.info("MIDI: learned button = note \(data1, privacy: .public)")
                onLearned?("Button: note \(data1)")
            }
            guard data1 == learnedNote else { return }
            logger.info("MIDI button down")
            gestures.buttonChanged(pressed: true)
        case 0x80, 0x90:  // note off, or note on with zero velocity
            guard data1 == learnedNote else { return }
            logger.info("MIDI button up")
            gestures.buttonChanged(pressed: false)
        default:
            break
        }
    }

    /// Decides whether a control has been moved deliberately enough to
    /// become the knob. Returns true on the message that wins the slot.
    private func learn(candidate cc: Int) -> Bool {
        let now = Date()
        var entry = learnCandidates[cc] ?? (count: 0, firstSeen: now)
        if now.timeIntervalSince(entry.firstSeen) > Self.learnWindow {
            entry = (count: 0, firstSeen: now)  // stale, start again
        }
        entry.count += 1
        learnCandidates[cc] = entry
        guard entry.count >= Self.messagesToLearn else { return false }

        learnedCC = cc
        lastValue = nil
        learnCandidates.removeAll()
        logger.info("MIDI: learned knob = CC \(cc, privacy: .public)")
        onLearned?("Knob: CC \(cc)")
        return true
    }

    /// nil means "no movement to report yet", which is different from a
    /// delta of zero: the first absolute reading only establishes where
    /// the knob is sitting.
    private func rotationDelta(for value: Int) -> Int? {
        switch encoderMode {
        case .relative:
            if value == 0 || value == 64 { return 0 }
            return value < 64 ? value : -(128 - value)
        case .relativeSigned:
            if value == 0 || value == 64 { return 0 }
            return value > 64 ? value - 64 : -value
        case .absolute:
            defer { lastValue = value }
            guard let last = lastValue else { return nil }
            return value - last
        }
    }
}
