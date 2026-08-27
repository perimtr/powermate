import Foundation

/// Lists and runs Apple Shortcuts via the `shortcuts` CLI. Runs execute on a
/// serial queue off the main thread (a run takes ~0.5–1 s); when the knob
/// steps faster than Shortcuts can execute, extra steps are dropped rather
/// than queued so rotation never builds a backlog.
final class ShortcutRunner {
    static let shared = ShortcutRunner()

    /// Called on the main thread when a run exits nonzero.
    var onFailure: ((String) -> Void)?

    /// Shortcut names, refreshed asynchronously; read from the main thread.
    private(set) var available: [String] = []

    private let runQueue = DispatchQueue(label: "io.perimtr.powermate.shortcuts")
    private var inFlight = 0  // main thread only

    func refreshAvailable() {
        DispatchQueue.global(qos: .utility).async {
            guard let output = Self.capture(arguments: ["list"]) else { return }
            let names = output
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            DispatchQueue.main.async {
                if names != self.available {
                    self.available = names
                    logger.info("Shortcuts available: \(names.count, privacy: .public)")
                }
            }
        }
    }

    /// Call on the main thread.
    func run(_ name: String) {
        guard inFlight < 2 else { return }  // knob outran Shortcuts - drop the step
        inFlight += 1
        runQueue.async {
            let status = Self.execute(arguments: ["run", name])
            DispatchQueue.main.async {
                self.inFlight -= 1
                if status != 0 {
                    logger.error("Shortcut failed (\(status, privacy: .public)): \(name, privacy: .public)")
                    self.onFailure?(name)
                }
            }
        }
    }

    private static func execute(arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func capture(arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
