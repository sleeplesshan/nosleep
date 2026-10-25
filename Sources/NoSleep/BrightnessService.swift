import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit.pwr_mgt
import NoSleepCore

/// Apple Silicon does not expose built-in brightness through IODisplayConnect.
/// Isolate the optional DisplayServices SPI, validate every result, and fail closed.
/// No software shading, gamma change, or external-monitor DDC fallback is used.
final class NativeBrightnessBackend: BrightnessBackend, @unchecked Sendable {
    private typealias Getter = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (UInt32, Float) -> Int32
    private let handle: UnsafeMutableRawPointer
    private let getter: Getter
    private let setter: Setter

    init() throws {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL) else {
            throw MacServiceError.failed("Native brightness control is unavailable on this macOS version.")
        }
        guard let get = dlsym(handle, "DisplayServicesGetBrightness"), let set = dlsym(handle, "DisplayServicesSetBrightness") else {
            dlclose(handle)
            throw MacServiceError.failed("Native brightness functions are unavailable.")
        }
        self.handle = handle
        getter = unsafeBitCast(get, to: Getter.self)
        setter = unsafeBitCast(set, to: Setter.self)
    }
    deinit { dlclose(handle) }

    func readBrightness(displayID: UInt32) throws -> Double {
        var value: Float = -1
        guard getter(displayID, &value) == 0, value.isFinite, (0...1).contains(value) else {
            throw MacServiceError.failed("Could not read the built-in display brightness.")
        }
        return Double(value)
    }

    func setBrightness(_ value: Double, displayID: UInt32) throws {
        guard value.isFinite, (0...1).contains(value), setter(displayID, Float(value)) == 0 else {
            throw MacServiceError.failed("Could not change the built-in display brightness.")
        }
    }

    static func builtInDisplays() -> [UInt32] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0, count <= 32 else { return [] }
        var displays = [UInt32](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) != 0 }
    }

    static func stableID(_ id: UInt32) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

@MainActor
final class BrightnessService {
    private struct Recovery: Codable { let brightnessByUUID: [String: Double] }
    private let backend: NativeBrightnessBackend
    private var transaction: BrightnessTransaction
    private let journal: URL
    private var knownDisplays: [UInt32]
    private var snapshotUUIDs: [UInt32: String] = [:]
    private var pendingRecovery: [String: Double] = [:]
    private var journalLoadError: Error?
    private var recoveryNeeded = false
    private var nextRecoveryAttempt: TimeInterval = 0
    private var lastErrorText: String?
    private var lastErrorTime: TimeInterval = -.infinity
    private var displaySleepAssertion: IOPMAssertionID = 0
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var ignoreInputUntil: TimeInterval = .infinity
    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?

    var isDimmed: Bool { !transaction.snapshots.isEmpty }
    var available: Bool { journalLoadError == nil && knownDisplays.contains { (try? backend.readBrightness(displayID: $0)) != nil } }

    init() throws {
        backend = try NativeBrightnessBackend()
        knownDisplays = NativeBrightnessBackend.builtInDisplays()
        journal = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NoSleep/brightness-recovery.json")
        transaction = try BrightnessTransaction(backend: backend)
        // Construction never restores hardware. The owner installs callbacks before recovery.
        if FileManager.default.fileExists(atPath: journal.path) {
            do {
                let recovery = try JSONDecoder().decode(Recovery.self, from: Data(contentsOf: journal))
                guard recovery.brightnessByUUID.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                    throw MacServiceError.failed("The saved brightness recovery data is invalid; it has been preserved.")
                }
                pendingRecovery = recovery.brightnessByUUID
            } catch { journalLoadError = error }
        }
    }

    /// Nonfatal to service lifetime: the caller reports errors and retains this instance for retry.
    func recoverIfNeeded() throws {
        if let journalLoadError { throw journalLoadError }
        try synchronizeDisplays()
        guard recoveryNeeded else { return }
        nextRecoveryAttempt = ProcessInfo.processInfo.systemUptime + 5
        do {
            try restore()
            recoveryNeeded = false
        } catch {
            armRecoveryIfNeeded()
            throw error
        }
    }

    func refreshDisplays() {
        do {
            try synchronizeDisplays()
            if recoveryNeeded && ProcessInfo.processInfo.systemUptime >= nextRecoveryAttempt {
                try recoverIfNeeded()
            } else if isDimmed {
                _ = try transaction.reconcileExternalChanges(persist: persistence())
            }
            cleanupIfRestored()
        } catch { reportThrottled(error) }
        onChange?()
    }

    private func synchronizeDisplays() throws {
        knownDisplays = NativeBrightnessBackend.builtInDisplays()
        var snapshots = transaction.snapshots
        var changed = false
        // Preserve offline panels by stable UUID, not a display ID that can change after reconnect.
        for (id, value) in snapshots where !knownDisplays.contains(id) {
            if let uuid = snapshotUUIDs[id] {
                pendingRecovery[uuid] = value
                snapshots.removeValue(forKey: id)
                changed = true
            }
        }
        for id in knownDisplays {
            guard let uuid = NativeBrightnessBackend.stableID(id) else { continue }
            snapshotUUIDs[id] = uuid
            if let value = pendingRecovery.removeValue(forKey: uuid) {
                if snapshots[id] == nil { snapshots[id] = value }
                recoveryNeeded = true
                changed = true
            }
        }
        if changed { transaction = try BrightnessTransaction(backend: backend, snapshots: snapshots) }
        cleanupIfRestored()
    }

    func dim() throws {
        if let journalLoadError { throw journalLoadError }
        try synchronizeDisplays()
        guard !isDimmed else { armRecoveryIfNeeded(); return }
        guard !knownDisplays.isEmpty else { throw BrightnessError.noDisplays }
        var assertion: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               "Sleeplesshan brightness-zero session" as CFString, &assertion)
        guard result == kIOReturnSuccess else { throw MacServiceError.failed("Could not keep the dimmed display out of idle display sleep.") }
        displaySleepAssertion = assertion
        do {
            try transaction.dim(displayIDs: knownDisplays, persist: persistence())
            armRecoveryIfNeeded()
            cleanupIfRestored()
            onChange?()
        } catch {
            // A failed rollback can leave a panel at zero; recovery input must still work.
            armRecoveryIfNeeded()
            cleanupIfRestored()
            onChange?()
            throw error
        }
    }

    func restore() throws {
        defer {
            cleanupIfRestored()
            onChange?()
        }
        try synchronizeDisplays()
        guard isDimmed else { recoveryNeeded = false; return }
        _ = try transaction.restore(persist: persistence())
        recoveryNeeded = false
    }

    private func persistence() -> ([UInt32: Double]) throws -> Void {
        let file = journal
        let identities = snapshotUUIDs
        let offline = pendingRecovery
        return { snapshots in
            var values = offline
            for (id, brightness) in snapshots {
                guard let uuid = identities[id] else {
                    throw MacServiceError.failed("Could not identify the display for brightness recovery.")
                }
                values[uuid] = brightness
            }
            let data = try JSONEncoder().encode(Recovery(brightnessByUUID: values))
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    private func armRecoveryIfNeeded() {
        guard isDimmed, localMonitor == nil, globalMonitor == nil else { return }
        ignoreInputUntil = ProcessInfo.processInfo.systemUptime + 0.8
        installInputMonitors()
    }

    private func installInputMonitors() {
        removeInputMonitors()
        let events: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved, .scrollWheel]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            Task { @MainActor [weak self] in self?.restoreAfterInput() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.isDimmed, ProcessInfo.processInfo.systemUptime >= self.ignoreInputUntil else { return false }
                self.restoreAfterInput()
                return true
            }
            return consumed ? nil : event
        }
    }

    private func restoreAfterInput() {
        guard isDimmed, ProcessInfo.processInfo.systemUptime >= ignoreInputUntil else { return }
        do { try restore() } catch { reportThrottled(error) }
    }

    private func reportThrottled(_ error: Error) {
        let now = ProcessInfo.processInfo.systemUptime
        let text = error.localizedDescription
        guard text != lastErrorText || now - lastErrorTime >= 60 else { return }
        lastErrorText = text; lastErrorTime = now
        onError?(error)
    }

    private func cleanupIfRestored() {
        if !isDimmed { removeInputMonitors(); releaseAssertion() }
    }

    private func removeInputMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil; globalMonitor = nil
    }

    private func releaseAssertion() {
        if displaySleepAssertion != 0 { IOPMAssertionRelease(displaySleepAssertion); displaySleepAssertion = 0 }
    }
}
