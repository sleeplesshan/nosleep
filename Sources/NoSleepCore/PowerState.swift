import Foundation

/// Whether the global `SleepDisabled` setting is enabled, not whether all sleep blockers are absent.
public enum SleepState: Sendable, Equatable {
    case enabled, disabled, unknown
}

public enum PowerReadError: Error, LocalizedError, Sendable, Equatable {
    case missingSetting
    case invalidValue(String)
    case conflictingValues

    public var errorDescription: String? {
        switch self {
        case .missingSetting: "The system did not return the SleepDisabled setting."
        case .invalidValue(let value): "The system returned an invalid SleepDisabled value: \(value)."
        case .conflictingValues: "The system returned conflicting SleepDisabled values."
        }
    }
}

public enum PowerStateParser {
    public static func parse(_ output: String) throws -> SleepState {
        var result: SleepState?
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let key = fields.first, key.lowercased() == "sleepdisabled" || key.lowercased() == "disablesleep" else { continue }
            guard fields.count == 2, fields[1] == "0" || fields[1] == "1" else {
                throw PowerReadError.invalidValue(fields.dropFirst().joined(separator: " "))
            }
            let value: SleepState = fields[1] == "1" ? .enabled : .disabled
            if let result, result != value { throw PowerReadError.conflictingValues }
            result = value
        }
        guard let result else { throw PowerReadError.missingSetting }
        return result
    }
}

public protocol PowerBackend: Sendable {
    func readState() async throws -> SleepState
    func setDisabledSleep(_ enabled: Bool) async throws
}

public enum PowerControlError: Error, LocalizedError, Sendable, Equatable {
    case busy
    case commandFailed(message: String, observed: SleepState)
    case verificationFailed(expected: SleepState, actual: SleepState)
    case readbackFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case .busy: "Another power operation is in progress."
        case .commandFailed(let message, _): message
        case .verificationFailed(let expected, let actual):
            "The requested setting could not be verified (expected \(expected), observed \(actual))."
        case .readbackFailed(let message): "The current power setting could not be read: \(message)"
        }
    }
}

/// Serializes reads with writes across actor suspension points. System readback is authoritative.
public actor PowerController {
    private let backend: any PowerBackend
    private var busy = false
    public private(set) var lastObservedState: SleepState = .unknown

    public init(backend: any PowerBackend) { self.backend = backend }

    public func readState() async throws -> SleepState {
        guard !busy else { throw PowerControlError.busy }
        busy = true
        defer { busy = false }
        do {
            let state = try await backend.readState()
            lastObservedState = state
            return state
        } catch {
            lastObservedState = .unknown
            throw error
        }
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool) async throws -> SleepState {
        guard !busy else { throw PowerControlError.busy }
        busy = true
        defer { busy = false }
        do {
            try Task.checkCancellation()
            try await backend.setDisabledSleep(enabled)
        } catch {
            let message = error.localizedDescription
            lastObservedState = (try? await backend.readState()) ?? .unknown
            throw PowerControlError.commandFailed(message: message, observed: lastObservedState)
        }
        let observed: SleepState
        do {
            observed = try await backend.readState()
        } catch {
            lastObservedState = .unknown
            throw PowerControlError.readbackFailed(message: error.localizedDescription)
        }
        lastObservedState = observed
        let expected: SleepState = enabled ? .enabled : .disabled
        guard observed == expected else {
            throw PowerControlError.verificationFailed(expected: expected, actual: observed)
        }
        return observed
    }
}
