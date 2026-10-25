import AppKit
@preconcurrency import ApplicationServices
import Foundation
import IOKit
import NoSleepCore
import ServiceManagement

struct CommandResult: Sendable {
    let status: Int32
    let output: String
    let error: String
}

enum MacServiceError: Error, LocalizedError {
    case timeout, oversizedOutput, cancelled, permissionRequired, eventCreation, failed(String)
    var errorDescription: String? {
        switch self {
        case .timeout: "The command timed out. Its current state will be checked again."
        case .oversizedOutput: "The system returned unexpectedly large output."
        case .cancelled: "Administrator authentication was cancelled."
        case .permissionRequired: "Allow Sleeplesshan in System Settings > Privacy & Security > Accessibility."
        case .eventCreation: "The lock request could not be created."
        case .failed(let text): text
        }
    }
}

/// Commands have fixed executable paths and argument arrays. No user text enters a shell.
enum CommandRunner {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 8) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try runBlocking(executable, arguments, timeout: timeout) })
            }
        }
    }

    private static func runBlocking(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
            let manager = FileManager.default
            let directory = manager.temporaryDirectory.appendingPathComponent("nosleep-\(UUID().uuidString)")
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? manager.removeItem(at: directory) }
            let outURL = directory.appendingPathComponent("stdout")
            let errURL = directory.appendingPathComponent("stderr")
            manager.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            manager.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let out = try FileHandle(forWritingTo: outURL)
            let err = try FileHandle(forWritingTo: errURL)
            defer { try? out.close(); try? err.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C", "LANG": "C"]) { _, new in new }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = out
            process.standardError = err
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            try process.run()
            if finished.wait(timeout: .now() + timeout) == .timedOut {
                if process.isRunning { process.terminate() }
                if finished.wait(timeout: .now() + 0.5) == .timedOut {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    _ = finished.wait(timeout: .now() + 1)
                }
                throw MacServiceError.timeout
            }
            try out.synchronize(); try err.synchronize()
            func readBounded(_ url: URL) throws -> String {
                let reader = try FileHandle(forReadingFrom: url)
                defer { try? reader.close() }
                let data = try reader.read(upToCount: 262_145) ?? Data()
                guard data.count <= 262_144 else { throw MacServiceError.oversizedOutput }
                return String(decoding: data, as: UTF8.self)
            }
            return try CommandResult(status: process.terminationStatus, output: readBounded(outURL), error: readBounded(errURL))
    }
}

struct MacPowerBackend: PowerBackend {
    func readState() async throws -> SleepState {
        let result = try await CommandRunner.run("/usr/bin/pmset", ["-g"])
        guard result.status == 0 else { throw MacServiceError.failed(result.error) }
        return try PowerStateParser.parse(result.output)
    }

    func setDisabledSleep(_ enabled: Bool) async throws {
        let flag = enabled ? "1" : "0"
        let result = try await CommandRunner.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", flag])
        if result.status == 0 { return }
        // Only an authentication/authorization failure gets an interactive retry.
        let reason = result.error.lowercased()
        guard reason.contains("password is required") || reason.contains("not allowed") || reason.contains("a terminal is required") || reason.contains("not in the sudoers") else {
            throw MacServiceError.failed(result.error.isEmpty ? "pmset failed (\(result.status))." : result.error)
        }
        // flag is derived from Bool, never interpolated user input.
        let source = "do shell script \"/usr/bin/pmset -a disablesleep \(flag)\" with administrator privileges"
        let authorized = try await CommandRunner.run("/usr/bin/osascript", ["-e", source], timeout: 120)
        if authorized.status != 0 {
            if authorized.error.contains("(-128)") { throw MacServiceError.cancelled }
            throw MacServiceError.failed(authorized.error)
        }
    }
}

enum LidReader {
    static func read() -> LidState {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return .unknown }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else { return .unknown }
        return value.boolValue ? .closed : .open
    }
}

@MainActor
enum DisplayService {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func turnOff(lock: Bool) async throws {
        if lock {
            guard accessibilityGranted else { throw MacServiceError.permissionRequired }
            guard let source = CGEventSource(stateID: .hidSystemState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: false) else {
                throw MacServiceError.eventCreation
            }
            down.flags = [.maskControl, .maskCommand]
            up.flags = [.maskControl, .maskCommand]
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(1500))
        }
        let result = try await CommandRunner.run("/usr/bin/pmset", ["displaysleepnow"])
        guard result.status == 0 else { throw MacServiceError.failed(result.error) }
    }
}

/// Explicit, reversible import of this Mac's older standalone lid watcher.
/// This is never run on startup and never manages other power assertions.
enum LegacyWatcher {
    static let label = "local.han.display-sleep-on-lid-close"
    static var plist: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    static var exists: Bool { FileManager.default.fileExists(atPath: plist.path) }

    static func migrate() async throws -> URL {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        let script = home.appendingPathComponent(".local/bin/watch-lid-display-sleep.sh")
        let data = try Data(contentsOf: plist)
        guard let configuration = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              configuration["Label"] as? String == label,
              configuration["ProgramArguments"] as? [String] == [script.path] else {
            throw MacServiceError.failed("The previous watcher configuration is different. No changes were made.")
        }
        let backup = home.appendingPathComponent("Library/Application Support/NoSleep/Backups/\(UUID().uuidString)")
        try manager.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let saved = backup.appendingPathComponent(plist.lastPathComponent)
        try manager.copyItem(at: plist, to: saved)
        if manager.fileExists(atPath: script.path) { try manager.copyItem(at: script, to: backup.appendingPathComponent(script.lastPathComponent)) }
        let domain = "gui/\(getuid())"
        _ = try await CommandRunner.run("/bin/launchctl", ["bootout", domain, plist.path])
        let check = try await CommandRunner.run("/bin/launchctl", ["print", "\(domain)/\(label)"])
        guard check.status == 113 && check.error.contains("Could not find service") else {
            throw MacServiceError.failed("Could not confirm the previous watcher stopped. Its configuration is preserved.")
        }
        do {
            try manager.removeItem(at: plist) // Saved above; prevents launch at the next login.
        } catch {
            let restored = try await CommandRunner.run("/bin/launchctl", ["bootstrap", domain, plist.path])
            guard restored.status == 0 else {
                throw MacServiceError.failed("Migration failed and the previous watcher could not restart. Its backup is at \(backup.path).")
            }
            throw error
        }
        return backup
    }
}
