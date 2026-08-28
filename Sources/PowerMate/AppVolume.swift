import AppKit
import CoreAudio
import os.log

/// Per-application volume for the Frontmost App Volume rotate mode,
/// macOS 14.4 and newer.
///
/// CoreAudio process taps make this possible without a driver: a tap on an
/// app's audio processes captures their output and mutes their direct path,
/// and a private aggregate device replays the tapped audio through the real
/// output device with our gain applied. One engine per application; an
/// engine exists only while that app's gain is below 100%. Gains persist
/// per bundle id and are re-applied when the app next launches.
///
/// The first tap triggers the one-time System Audio Recording permission
/// prompt. Nothing is recorded: samples flow from the tap to the output
/// inside one realtime callback.
@available(macOS 14.4, *)
final class AppVolumeController {
    enum AdjustResult {
        case adjusted(Float)
        case noAudio
        case failed
    }

    private static let gainsKey = "appVolumeGains"
    private let defaults = UserDefaults.standard
    private var engines: [String: AppTapEngine] = [:]
    private var reapTimers: [String: DispatchWorkItem] = [:]
    private var deviceListener: AudioObjectPropertyListenerBlock?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appLaunched(_:)),
                           name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appTerminated(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        listenForDeviceChanges()
        restoreRunningApps()
    }

    /// Nudge an app's gain. `delta` is in the same units as the volume step
    /// (fraction of full scale per knob count).
    func adjust(bundleID: String, pid: pid_t, bySteps delta: Double) -> AdjustResult {
        reapTimers[bundleID]?.cancel()
        reapTimers[bundleID] = nil

        if let engine = engines[bundleID], engine.processSetIsStale {
            let processes = audioProcesses(bundleID: bundleID, rootPID: pid)
            if processes != engine.processObjects {
                let gain = engine.targetGain
                engine.teardown()
                engines[bundleID] = nil
                if !processes.isEmpty {
                    engines[bundleID] = AppTapEngine(
                        bundleID: bundleID, processObjects: processes, initialGain: gain)
                }
            } else {
                engine.markProcessSetFresh()
            }
        }

        if engines[bundleID] == nil {
            let processes = audioProcesses(bundleID: bundleID, rootPID: pid)
            guard !processes.isEmpty else { return .noAudio }
            guard let engine = AppTapEngine(
                bundleID: bundleID, processObjects: processes,
                initialGain: storedGain(for: bundleID))
            else { return .failed }
            engines[bundleID] = engine
        }
        guard let engine = engines[bundleID] else { return .failed }

        let gain = max(0, min(1, engine.targetGain + Float(delta)))
        engine.setTarget(gain)
        store(gain: gain, for: bundleID)
        if gain >= 1 {
            scheduleReap(bundleID)
        }
        return .adjusted(gain)
    }

    /// Debug statistics for the verification recipe.
    func debugStats(bundleID: String) -> String {
        guard let engine = engines[bundleID] else { return "no engine" }
        return engine.debugStats()
    }

    // MARK: - Persistence

    private func storedGains() -> [String: Double] {
        defaults.dictionary(forKey: Self.gainsKey) as? [String: Double] ?? [:]
    }

    private func storedGain(for bundleID: String) -> Float {
        Float(storedGains()[bundleID] ?? 1)
    }

    private func store(gain: Float, for bundleID: String) {
        var gains = storedGains()
        if gain >= 1 {
            gains.removeValue(forKey: bundleID)
        } else {
            gains[bundleID] = Double(gain)
        }
        if gains.isEmpty {
            defaults.removeObject(forKey: Self.gainsKey)
        } else {
            defaults.set(gains, forKey: Self.gainsKey)
        }
    }

    // MARK: - Engine lifecycle

    /// At full volume the engine is pointless; give the user a moment in
    /// case they keep turning, then hand the audio path back to macOS.
    private func scheduleReap(_ bundleID: String) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.engines[bundleID]?.teardown()
            self.engines[bundleID] = nil
            self.reapTimers[bundleID] = nil
        }
        reapTimers[bundleID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Persisted gains apply automatically to apps that are already running
    /// (or launch later). Taps are only created for entries the user made
    /// earlier, so this never triggers a permission prompt on its own.
    private func restoreRunningApps() {
        let gains = storedGains()
        guard !gains.isEmpty else { return }
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, gains[bundleID] != nil,
                  engines[bundleID] == nil else { continue }
            let processes = audioProcesses(bundleID: bundleID, rootPID: app.processIdentifier)
            guard !processes.isEmpty else { continue }
            engines[bundleID] = AppTapEngine(
                bundleID: bundleID, processObjects: processes,
                initialGain: Float(gains[bundleID] ?? 1))
        }
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              let gain = storedGains()[bundleID], gain < 1,
              engines[bundleID] == nil
        else { return }
        // The app's audio processes register with CoreAudio a beat after
        // launch; give them a moment before building the tap.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.engines[bundleID] == nil else { return }
            let processes = self.audioProcesses(
                bundleID: bundleID, rootPID: app.processIdentifier)
            guard !processes.isEmpty else { return }
            self.engines[bundleID] = AppTapEngine(
                bundleID: bundleID, processObjects: processes, initialGain: Float(gain))
        }
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              let engine = engines[bundleID]
        else { return }
        engine.teardown()
        engines[bundleID] = nil
    }

    /// The aggregate embeds the output device's UID, so a default-output
    /// change means every engine rebuilds against the new device.
    private func listenForDeviceChanges() {
        deviceListener = { [weak self] _, _ in
            self?.rebuildAllEngines()
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, deviceListener!)
    }

    private func rebuildAllEngines() {
        let old = engines
        engines = [:]
        for (bundleID, engine) in old {
            let gain = engine.targetGain
            let processes = engine.processObjects
            engine.teardown()
            engines[bundleID] = AppTapEngine(
                bundleID: bundleID, processObjects: processes, initialGain: gain)
        }
    }

    // MARK: - Process resolution

    /// The CoreAudio process objects belonging to an application: processes
    /// with a matching bundle id, plus descendants of the app's own process
    /// (browsers and other multi-process apps play audio from helpers with
    /// bundle ids of their own).
    private func audioProcesses(bundleID: String, rootPID: pid_t) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0
        else { return [] }
        var objects = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr
        else { return [] }

        return objects.filter { object in
            if let objectBundle = processBundleID(object), objectBundle == bundleID {
                return true
            }
            guard let pid = processPID(object) else { return false }
            return pid == rootPID || isDescendant(pid, of: rootPID)
        }.sorted()
    }

    private func processPID(_ object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr
        else { return nil }
        return pid
    }

    private func processBundleID(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectHasProperty(object, &address),
              AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    private func isDescendant(_ pid: pid_t, of ancestor: pid_t) -> Bool {
        var current = pid
        for _ in 0..<12 {
            let parent = parentPID(current)
            if parent == ancestor { return true }
            if parent <= 1 { return false }
            current = parent
        }
        return false
    }

    private func parentPID(_ pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }
}

/// The tap, aggregate device, and realtime gain stage for one application.
@available(macOS 14.4, *)
private final class AppTapEngine {
    let bundleID: String
    let processObjects: [AudioObjectID]
    private(set) var targetGain: Float

    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var torndown = false

    // Realtime state. `currentGain` is touched only by the IO callback;
    // `sharedTarget` crosses threads under the lock.
    private var lock = os_unfair_lock()
    private var sharedTarget: Float
    private var currentGain: Float
    private var callbackCount = 0
    private var inSquares: Double = 0
    private var outSquares: Double = 0
    private var sampleCount: Double = 0

    private var resolvedAt = Date()
    var processSetIsStale: Bool { Date().timeIntervalSince(resolvedAt) > 2 }
    func markProcessSetFresh() { resolvedAt = Date() }

    init?(bundleID: String, processObjects: [AudioObjectID], initialGain: Float) {
        self.bundleID = bundleID
        self.processObjects = processObjects
        self.targetGain = initialGain
        self.sharedTarget = initialGain
        self.currentGain = initialGain

        guard let outputDevice = SystemAudio.defaultOutputDevice(),
              let outputUID = Self.deviceUID(outputDevice)
        else { return nil }

        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.name = "PowerMate App Volume (\(bundleID))"
        description.isPrivate = true
        // MutedWhenTapped silences the app's direct path so only our
        // gain-scaled copy reaches the output device.
        description.muteBehavior = CATapMuteBehavior.mutedWhenTapped
        var tapID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else {
            logger.error("App volume: tap creation failed for \(bundleID, privacy: .public) (System Audio Recording permission?)")
            return nil
        }
        tap = tapID

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "PowerMate App Volume",
            kAudioAggregateDeviceUIDKey: "io.perimtr.powermate.appvolume." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString,
                 kAudioSubTapDriftCompensationKey: true]
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &aggregateID) == noErr
        else {
            logger.error("App volume: aggregate creation failed for \(bundleID, privacy: .public)")
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        aggregate = aggregateID

        var procID: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, {
            [weak self] _, inputData, _, outputData, _ in
            self?.render(input: inputData, output: outputData)
        }) == noErr, let procID else {
            logger.error("App volume: IO proc creation failed for \(bundleID, privacy: .public)")
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        ioProc = procID
        guard AudioDeviceStart(aggregateID, procID) == noErr else {
            logger.error("App volume: device start failed for \(bundleID, privacy: .public)")
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        logger.info("App volume engine up for \(bundleID, privacy: .public): \(processObjects.count) process(es), gain \(Int(initialGain * 100), privacy: .public)%")
    }

    func setTarget(_ gain: Float) {
        targetGain = gain
        os_unfair_lock_lock(&lock)
        sharedTarget = gain
        os_unfair_lock_unlock(&lock)
    }

    func teardown() {
        guard !torndown else { return }
        torndown = true
        if let ioProc {
            AudioDeviceStop(aggregate, ioProc)
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
        }
        if aggregate != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
        }
        logger.info("App volume engine down for \(self.bundleID, privacy: .public)")
    }

    func debugStats() -> String {
        os_unfair_lock_lock(&lock)
        let callbacks = callbackCount
        let inRMS = sampleCount > 0 ? (inSquares / sampleCount).squareRoot() : 0
        let outRMS = sampleCount > 0 ? (outSquares / sampleCount).squareRoot() : 0
        os_unfair_lock_unlock(&lock)
        let ratio = inRMS > 0 ? outRMS / inRMS : 0
        return String(
            format: "callbacks=%d inRMS=%.4f outRMS=%.4f ratio=%.3f", callbacks, inRMS, outRMS, ratio)
    }

    /// Realtime path: copy the tapped audio to the output with a smoothed
    /// gain. No allocation, no Objective-C, one brief uncontended lock.
    private func render(
        input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>
    ) {
        os_unfair_lock_lock(&lock)
        let target = sharedTarget
        os_unfair_lock_unlock(&lock)

        let inputList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input))
        let outputList = UnsafeMutableAudioBufferListPointer(output)

        var localInSquares: Double = 0
        var localOutSquares: Double = 0
        var localSamples: Double = 0

        for bufferIndex in 0..<outputList.count {
            let outBuffer = outputList[bufferIndex]
            guard let outData = outBuffer.mData else { continue }
            let outFloats = outData.assumingMemoryBound(to: Float32.self)
            let outCount = Int(outBuffer.mDataByteSize) / MemoryLayout<Float32>.size

            guard bufferIndex < inputList.count,
                  let inData = inputList[bufferIndex].mData
            else {
                memset(outData, 0, Int(outBuffer.mDataByteSize))
                continue
            }
            let inFloats = inData.assumingMemoryBound(to: Float32.self)
            let inCount = Int(inputList[bufferIndex].mDataByteSize) / MemoryLayout<Float32>.size

            let channels = max(1, Int(outBuffer.mNumberChannels))
            let frames = min(inCount, outCount) / channels
            var gain = currentGain
            var index = 0
            for _ in 0..<frames {
                gain += (target - gain) * 0.002
                for _ in 0..<channels {
                    let sample = inFloats[index]
                    let scaled = sample * gain
                    outFloats[index] = scaled
                    localInSquares += Double(sample * sample)
                    localOutSquares += Double(scaled * scaled)
                    index += 1
                }
            }
            localSamples += Double(frames * channels)
            if index < outCount {
                memset(outFloats + index, 0,
                       (outCount - index) * MemoryLayout<Float32>.size)
            }
            currentGain = gain
        }

        os_unfair_lock_lock(&lock)
        callbackCount += 1
        inSquares += localInSquares
        outSquares += localOutSquares
        sampleCount += localSamples
        os_unfair_lock_unlock(&lock)
    }

    private static func deviceUID(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
