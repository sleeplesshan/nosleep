import Foundation

public enum LidState: Sendable, Equatable { case open, closed, unknown }
public enum LidAction: String, CaseIterable, Sendable { case none, displayOff, lockAndDisplayOff }

public struct LidMonitorState: Sendable {
    public private(set) var lastKnownState: LidState = .unknown
    public private(set) var lastSuccessfulActionTime: TimeInterval?
    public let cooldown: TimeInterval

    public init(cooldown: TimeInterval = 10) {
        self.cooldown = cooldown.isFinite ? max(0, cooldown) : 10
    }

    /// Pass a monotonic time (e.g. systemUptime). Unknown samples retain the last valid lid state.
    public mutating func observe(_ state: LidState, sleepState: SleepState, action: LidAction, now: TimeInterval) -> LidAction? {
        guard state != .unknown else { return nil }
        let previous = lastKnownState
        lastKnownState = state
        guard previous == .open, state == .closed, sleepState == .enabled,
              action != .none, now.isFinite else { return nil }
        if let lastSuccessfulActionTime, now - lastSuccessfulActionTime < cooldown { return nil }
        return action
    }

    /// Only call after the requested operation succeeds; failure must not consume cooldown.
    public mutating func markActionSucceeded(at now: TimeInterval) {
        guard now.isFinite else { return }
        lastSuccessfulActionTime = now
    }
}
