import Foundation
import Testing
@testable import NoSleepCore

@Test func parsesActualPMSetOutputAndCompatibilitySpelling() throws {
    #expect(try PowerStateParser.parse("System-wide power settings:\n SleepDisabled\t\t0\nCurrently in use:\n sleep 0 (sleep prevented by example)") == .disabled)
    #expect(try PowerStateParser.parse("  DISABLESLEEP 1\r\n") == .enabled)
    #expect(try PowerStateParser.parse("SleepDisabled 1\ndisablesleep 1") == .enabled)
}

@Test func rejectsMissingMalformedAndContradictoryState() {
    #expect(throws: PowerReadError.missingSetting) { try PowerStateParser.parse("sleep 0\nNotSleepDisabled 1") }
    #expect(throws: PowerReadError.conflictingValues) { try PowerStateParser.parse("SleepDisabled 1\ndisablesleep 0") }
    for value in ["", "2", "true", "01", "0 extra"] {
        #expect(throws: PowerReadError.self) { try PowerStateParser.parse("SleepDisabled \(value)") }
    }
}

@Test func lidRequiresTransitionAndPreservesKnownStateAcrossUnknown() {
    var monitor = LidMonitorState()
    #expect(monitor.observe(.closed, sleepState: .enabled, action: .displayOff, now: 0) == nil)
    #expect(monitor.observe(.open, sleepState: .enabled, action: .displayOff, now: 1) == nil)
    #expect(monitor.observe(.unknown, sleepState: .enabled, action: .displayOff, now: 2) == nil)
    #expect(monitor.observe(.closed, sleepState: .enabled, action: .displayOff, now: 3) == .displayOff)
    #expect(monitor.observe(.closed, sleepState: .enabled, action: .displayOff, now: 4) == nil)
}

@Test func lidOnlySuccessfulActionsConsumeCooldown() {
    var monitor = LidMonitorState()
    _ = monitor.observe(.open, sleepState: .enabled, action: .lockAndDisplayOff, now: 0)
    #expect(monitor.observe(.closed, sleepState: .enabled, action: .lockAndDisplayOff, now: 1) == .lockAndDisplayOff)
    // Simulate failure: a new close edge remains eligible.
    _ = monitor.observe(.open, sleepState: .enabled, action: .lockAndDisplayOff, now: 2)
    #expect(monitor.observe(.closed, sleepState: .enabled, action: .lockAndDisplayOff, now: 3) == .lockAndDisplayOff)
    monitor.markActionSucceeded(at: 3)
    _ = monitor.observe(.open, sleepState: .enabled, action: .lockAndDisplayOff, now: 4)
    #expect(monitor.observe(.closed, sleepState: .enabled, action: .lockAndDisplayOff, now: 5) == nil)
    _ = monitor.observe(.open, sleepState: .enabled, action: .lockAndDisplayOff, now: 12)
    #expect(monitor.observe(.closed, sleepState: .enabled, action: .lockAndDisplayOff, now: 13) == .lockAndDisplayOff)
}

@Test func lidDoesNotFireWhenDisabledOrUnknownOrWhenEnablingWhileClosed() {
    for state in [SleepState.disabled, .unknown] {
        var monitor = LidMonitorState()
        _ = monitor.observe(.open, sleepState: state, action: .displayOff, now: 0)
        #expect(monitor.observe(.closed, sleepState: state, action: .displayOff, now: 1) == nil)
        #expect(monitor.observe(.closed, sleepState: .enabled, action: .displayOff, now: 2) == nil)
    }
    var monitor = LidMonitorState()
    _ = monitor.observe(.open, sleepState: .enabled, action: .none, now: 0)
    #expect(monitor.observe(.closed, sleepState: .enabled, action: .none, now: 1) == nil)
}

private enum TestError: Error { case failed }
private actor FakeBackend: PowerBackend {
    var state: SleepState = .disabled
    var failSet = false
    var failRead = false
    var ignoreSet = false
    var blockSet = false
    var setCalls = 0
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var setContinuation: CheckedContinuation<Void, Never>?

    func configure(state: SleepState? = nil, failSet: Bool = false, failRead: Bool = false, ignoreSet: Bool = false, blockSet: Bool = false) {
        if let state { self.state = state }
        self.failSet = failSet; self.failRead = failRead; self.ignoreSet = ignoreSet; self.blockSet = blockSet
    }
    func readState() async throws -> SleepState {
        if failRead { throw TestError.failed }
        return state
    }
    func setDisabledSleep(_ enabled: Bool) async throws {
        setCalls += 1
        started = true
        startWaiters.forEach { $0.resume() }; startWaiters.removeAll()
        if blockSet { await withCheckedContinuation { setContinuation = $0 } }
        if failSet { throw TestError.failed }
        if !ignoreSet { state = enabled ? .enabled : .disabled }
    }
    func waitForSet() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func unblock() { setContinuation?.resume(); setContinuation = nil }
}

@Test func controllerVerifiesWritesAndReflectsExternalChanges() async throws {
    let backend = FakeBackend()
    let controller = PowerController(backend: backend)
    #expect(try await controller.setEnabled(true) == .enabled)
    await backend.configure(state: .disabled)
    #expect(try await controller.readState() == .disabled)
    #expect(await controller.lastObservedState == .disabled)
}

@Test func failedCommandStillReportsObservedStateWithoutClaimingSuccess() async throws {
    let backend = FakeBackend()
    await backend.configure(state: .enabled, failSet: true)
    let controller = PowerController(backend: backend)
    do {
        _ = try await controller.setEnabled(false)
        Issue.record("A failed command must not return success")
    } catch let error as PowerControlError {
        guard case .commandFailed(_, let observed) = error else { Issue.record("Wrong error: \(error)"); return }
        #expect(observed == .enabled)
    }
    #expect(await controller.lastObservedState == .enabled)
    await backend.configure(state: .enabled)
    #expect(try await controller.setEnabled(false) == .disabled)
}

@Test func mismatchedReadbackAndFailedReadsAreNotOptimistic() async throws {
    let backend = FakeBackend()
    let controller = PowerController(backend: backend)
    await backend.configure(ignoreSet: true)
    await #expect(throws: PowerControlError.verificationFailed(expected: .enabled, actual: .disabled)) {
        try await controller.setEnabled(true)
    }
    await backend.configure(failRead: true)
    await #expect(throws: PowerControlError.self) { try await controller.setEnabled(true) }
    #expect(await controller.lastObservedState == .unknown)
    await #expect(throws: TestError.self) { try await controller.readState() }
    await backend.configure(state: .disabled)
    #expect(try await controller.readState() == .disabled)
}

@Test func overlappingWriteAndReadAreRejectedWhileActorIsSuspended() async throws {
    let backend = FakeBackend()
    await backend.configure(blockSet: true)
    let controller = PowerController(backend: backend)
    let first = Task { try await controller.setEnabled(true) }
    await backend.waitForSet()
    await #expect(throws: PowerControlError.busy) { try await controller.setEnabled(false) }
    await #expect(throws: PowerControlError.busy) { try await controller.readState() }
    #expect(await backend.setCalls == 1)
    await backend.unblock()
    #expect(try await first.value == .enabled)
    #expect(try await controller.readState() == .enabled)
}

@Test func controllerErrorsPreserveActionableDetails() {
    let cancelled = PowerControlError.commandFailed(message: "Administrator authentication was cancelled.", observed: .disabled)
    #expect(cancelled.localizedDescription == "Administrator authentication was cancelled.")
    #expect(PowerControlError.readbackFailed(message: "Timed out").localizedDescription.contains("Timed out"))
    #expect(PowerReadError.missingSetting.localizedDescription.contains("SleepDisabled"))
}
