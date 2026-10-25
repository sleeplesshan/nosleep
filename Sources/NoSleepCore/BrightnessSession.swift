import Foundation

public protocol BrightnessBackend: Sendable {
    func readBrightness(displayID: UInt32) throws -> Double
    func setBrightness(_ value: Double, displayID: UInt32) throws
}

public enum BrightnessError: Error, LocalizedError, Sendable {
    case noDisplays
    case invalidBrightness(displayID: UInt32, value: Double)
    case verificationFailed(displayID: UInt32, expected: Double, actual: Double)
    case operationFailed(message: String, unresolvedDisplayIDs: [UInt32])

    public var errorDescription: String? {
        switch self {
        case .noDisplays: "No supported display is available for brightness control."
        case .invalidBrightness(let id, let value): "Display \(id) returned invalid brightness \(value)."
        case .verificationFailed(let id, let expected, let actual): "Display \(id) brightness could not be verified (expected \(expected), observed \(actual))."
        case .operationFailed(let message, let unresolved):
            unresolved.isEmpty ? message : "\(message) Brightness recovery is still pending for displays: \(unresolved.map(String.init).joined(separator: ", "))."
        }
    }
}

public struct BrightnessRestoreReport: Sendable, Equatable {
    public let restoredDisplayIDs: [UInt32]
    public let skippedDisplayIDs: [UInt32]
}

/// Owns only brightness values it changed. Call from one serialized executor.
/// Persist snapshots before dimming so a subsequent launch can recover from a crash.
public struct BrightnessTransaction: Sendable {
    private let backend: any BrightnessBackend
    public private(set) var snapshots: [UInt32: Double]
    private static let zeroTolerance = 0.001
    private static let restoreTolerance = 0.015

    public init(backend: any BrightnessBackend, snapshots: [UInt32: Double] = [:]) throws {
        for (id, value) in snapshots { try Self.validate(value, displayID: id) }
        self.backend = backend
        self.snapshots = snapshots
    }

    public mutating func dim(displayIDs: [UInt32], persist: ([UInt32: Double]) throws -> Void = { _ in }) throws {
        let ids = Array(Set(displayIDs)).sorted()
        guard !ids.isEmpty else { throw BrightnessError.noDisplays }
        // Resolve every display before any mutation, including unsupported/error states.
        var current: [UInt32: Double] = [:]
        for id in ids {
            let value = try backend.readBrightness(displayID: id)
            try Self.validate(value, displayID: id)
            current[id] = value
        }
        let previousSnapshots = snapshots
        for id in ids where snapshots[id] == nil && current[id]! > Self.zeroTolerance {
            snapshots[id] = current[id]!
        }
        do { try persist(snapshots) }
        catch {
            snapshots = previousSnapshots
            throw error
        }
        let recoverySnapshots = snapshots
        var touched: [UInt32] = []
        do {
            for id in ids where current[id]! > Self.zeroTolerance {
                // Include a throwing setter: it may have changed hardware before reporting failure.
                touched.append(id)
                try backend.setBrightness(0, displayID: id)
                let observed = try backend.readBrightness(displayID: id)
                try Self.validate(observed, displayID: id)
                guard observed <= Self.zeroTolerance else {
                    throw BrightnessError.verificationFailed(displayID: id, expected: 0, actual: observed)
                }
            }
        } catch {
            let originalError = error.localizedDescription
            var unresolved: [UInt32] = []
            for id in touched.reversed() {
                do {
                    let observed = try backend.readBrightness(displayID: id)
                    try Self.validate(observed, displayID: id)
                    if observed <= Self.zeroTolerance {
                        try backend.setBrightness(current[id]!, displayID: id)
                        try verifyRestored(displayID: id, expected: current[id]!)
                    }
                    // Nonzero changes belong to the user/another controller; don't overwrite them.
                } catch { unresolved.append(id) }
            }
            for id in ids where !unresolved.contains(id) {
                snapshots[id] = previousSnapshots[id]
            }
            var detail = originalError
            do { try persist(snapshots) }
            catch {
                // Keep an in-memory retry record until durable recovery data can be updated.
                snapshots = recoverySnapshots
                detail += " Recovery journal could not be saved: \(error.localizedDescription)"
            }
            throw BrightnessError.operationFailed(message: detail, unresolvedDisplayIDs: unresolved.sorted())
        }
    }

    @discardableResult
    public mutating func restore(persist: ([UInt32: Double]) throws -> Void = { _ in }) throws -> BrightnessRestoreReport {
        let originalSnapshots = snapshots
        var restored: [UInt32] = []
        var skipped: [UInt32] = []
        var failures: [String] = []
        for id in snapshots.keys.sorted() {
            let saved = snapshots[id]!
            do {
                let current = try backend.readBrightness(displayID: id)
                try Self.validate(current, displayID: id)
                if current > Self.zeroTolerance {
                    skipped.append(id)
                } else {
                    try backend.setBrightness(saved, displayID: id)
                    try verifyRestored(displayID: id, expected: saved)
                    restored.append(id)
                }
                snapshots.removeValue(forKey: id)
            } catch { failures.append(error.localizedDescription) }
        }
        do { try persist(snapshots) }
        catch {
            snapshots = originalSnapshots
            failures.append("Recovery journal could not be saved: \(error.localizedDescription)")
        }
        guard failures.isEmpty else {
            throw BrightnessError.operationFailed(message: failures.joined(separator: " "), unresolvedDisplayIDs: snapshots.keys.sorted())
        }
        return BrightnessRestoreReport(restoredDisplayIDs: restored, skippedDisplayIDs: skipped)
    }

    /// Retire ownership after a user or another controller raised brightness. Never writes hardware.
    /// An unchanged session does not rewrite its recovery journal.
    @discardableResult
    public mutating func reconcileExternalChanges(persist: ([UInt32: Double]) throws -> Void = { _ in }) throws -> [UInt32] {
        var changed: [UInt32] = []
        var failures: [String] = []
        for id in snapshots.keys.sorted() {
            do {
                let current = try backend.readBrightness(displayID: id)
                try Self.validate(current, displayID: id)
                if current > Self.zeroTolerance { changed.append(id) }
            } catch { failures.append(error.localizedDescription) }
        }
        if !changed.isEmpty {
            var remaining = snapshots
            for id in changed { remaining.removeValue(forKey: id) }
            // Commit the journal before relinquishing ownership; a failed write remains retryable.
            try persist(remaining)
            snapshots = remaining
        }
        if !failures.isEmpty {
            throw BrightnessError.operationFailed(message: failures.joined(separator: " "), unresolvedDisplayIDs: snapshots.keys.sorted())
        }
        return changed
    }

    private func verifyRestored(displayID: UInt32, expected: Double) throws {
        let actual = try backend.readBrightness(displayID: displayID)
        try Self.validate(actual, displayID: displayID)
        guard abs(actual - expected) <= Self.restoreTolerance else {
            throw BrightnessError.verificationFailed(displayID: displayID, expected: expected, actual: actual)
        }
    }

    private static func validate(_ value: Double, displayID: UInt32) throws {
        guard value.isFinite, (0...1).contains(value) else {
            throw BrightnessError.invalidBrightness(displayID: displayID, value: value)
        }
    }
}
