import Foundation
import Testing
@testable import NoSleepCore

private enum BrightnessTestError: Error { case unsupported, writeFailed, journalFailed }
private final class BrightnessFake: BrightnessBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt32: Double]
    private var writes: [(UInt32, Double)] = []
    private var failedZeroID: UInt32?
    private var failedRestoreID: UInt32?
    private var ignoredZeroID: UInt32?
    init(_ values: [UInt32: Double]) { self.values = values }
    func readBrightness(displayID: UInt32) throws -> Double {
        try lock.withLock {
            guard let value = values[displayID] else { throw BrightnessTestError.unsupported }
            return value
        }
    }
    func setBrightness(_ value: Double, displayID: UInt32) throws {
        try lock.withLock {
            writes.append((displayID, value))
            if value > 0 && displayID == failedRestoreID { throw BrightnessTestError.writeFailed }
            if !(value == 0 && displayID == ignoredZeroID) { values[displayID] = value }
            if value == 0 && displayID == failedZeroID { throw BrightnessTestError.writeFailed }
        }
    }
    func manuallySet(_ value: Double, id: UInt32) { lock.withLock { values[id] = value } }
    func failZero(afterApplying id: UInt32) { lock.withLock { failedZeroID = id } }
    func failRestore(id: UInt32?) { lock.withLock { failedRestoreID = id } }
    func ignoreZero(id: UInt32) { lock.withLock { ignoredZeroID = id } }
    var writeCount: Int { lock.withLock { writes.count } }
}

@Test func brightnessSnapshotsArePersistedBeforeMutationAndNotOverwritten() throws {
    let backend = BrightnessFake([1: 0.8])
    var transaction = try BrightnessTransaction(backend: backend)
    var journal: [UInt32: Double] = [:]
    try transaction.dim(displayIDs: [1]) { snapshot in
        #expect(backend.writeCount == 0)
        #expect(snapshot == [1: 0.8])
        journal = snapshot
    }
    #expect(try backend.readBrightness(displayID: 1) == 0)
    try transaction.dim(displayIDs: [1, 1])
    #expect(transaction.snapshots == [1: 0.8])
    #expect(backend.writeCount == 1)
    // A newly launched instance can restore from the pre-mutation journal.
    var relaunched = try BrightnessTransaction(backend: backend, snapshots: journal)
    let result = try relaunched.restore { journal = $0 }
    #expect(result.restoredDisplayIDs == [1])
    #expect(try backend.readBrightness(displayID: 1) == 0.8)
    #expect(journal.isEmpty)
}

@Test func brightnessPreflightRejectsUnsupportedTargetsWithoutPartialChanges() throws {
    let backend = BrightnessFake([1: 0.7])
    var transaction = try BrightnessTransaction(backend: backend)
    #expect(throws: BrightnessTestError.self) { try transaction.dim(displayIDs: [1, 2]) }
    #expect(backend.writeCount == 0)
    #expect(transaction.snapshots.isEmpty)
    #expect(throws: BrightnessError.self) { try transaction.dim(displayIDs: []) }
}

@Test func invalidBrightnessNeverReachesSetterOrRecoveryJournal() throws {
    for value in [Double.nan, .infinity, -.infinity, -0.1, 1.1] {
        let backend = BrightnessFake([1: value])
        var transaction = try BrightnessTransaction(backend: backend)
        #expect(throws: BrightnessError.self) { try transaction.dim(displayIDs: [1]) }
        #expect(backend.writeCount == 0)
        #expect(transaction.snapshots.isEmpty)
        #expect(throws: BrightnessError.self) { try BrightnessTransaction(backend: backend, snapshots: [1: value]) }
    }
}

@Test func dimFailureRollsBackEvenWhenFailingSetterAlreadyChangedHardware() throws {
    let backend = BrightnessFake([1: 0.8, 2: 0.6, 3: 0.4])
    backend.failZero(afterApplying: 2)
    var transaction = try BrightnessTransaction(backend: backend)
    var journal: [UInt32: Double] = [:]
    #expect(throws: BrightnessError.self) { try transaction.dim(displayIDs: [1, 2, 3]) { journal = $0 } }
    #expect(try backend.readBrightness(displayID: 1) == 0.8)
    #expect(try backend.readBrightness(displayID: 2) == 0.6)
    #expect(try backend.readBrightness(displayID: 3) == 0.4)
    #expect(transaction.snapshots.isEmpty)
    #expect(journal.isEmpty)
}

@Test func dimFailureRetainsOnlyUnresolvedRollbackSnapshot() throws {
    let backend = BrightnessFake([1: 0.8, 2: 0.6])
    backend.failZero(afterApplying: 2)
    backend.failRestore(id: 1)
    var transaction = try BrightnessTransaction(backend: backend)
    #expect(throws: BrightnessError.self) { try transaction.dim(displayIDs: [1, 2]) }
    #expect(transaction.snapshots == [1: 0.8])
    #expect(try backend.readBrightness(displayID: 1) == 0)
    #expect(try backend.readBrightness(displayID: 2) == 0.6)
    backend.failRestore(id: nil)
    #expect(try transaction.restore().restoredDisplayIDs == [1])
}

@Test func restoreDoesNotOverwriteManualBrightnessChanges() throws {
    let backend = BrightnessFake([1: 0.8, 2: 0.6])
    var transaction = try BrightnessTransaction(backend: backend)
    try transaction.dim(displayIDs: [1, 2])
    backend.manuallySet(0.3, id: 1)
    let report = try transaction.restore()
    #expect(report.skippedDisplayIDs == [1])
    #expect(report.restoredDisplayIDs == [2])
    #expect(try backend.readBrightness(displayID: 1) == 0.3)
    #expect(try backend.readBrightness(displayID: 2) == 0.6)
    #expect(transaction.snapshots.isEmpty)
}

@Test func brightnessJournalFailurePreventsAnyDimming() throws {
    let backend = BrightnessFake([1: 0.8])
    var transaction = try BrightnessTransaction(backend: backend)
    #expect(throws: BrightnessTestError.self) {
        try transaction.dim(displayIDs: [1]) { _ in throw BrightnessTestError.journalFailed }
    }
    #expect(backend.writeCount == 0)
    #expect(transaction.snapshots.isEmpty)
}

@Test func brightnessReadbackMustConfirmZero() throws {
    let backend = BrightnessFake([1: 0.8])
    backend.ignoreZero(id: 1)
    var transaction = try BrightnessTransaction(backend: backend)
    #expect(throws: BrightnessError.self) { try transaction.dim(displayIDs: [1]) }
    #expect(try backend.readBrightness(displayID: 1) == 0.8)
    #expect(transaction.snapshots.isEmpty)
}

@Test func restoreFailuresRetainRecoveryAndDoNotBlockOtherDisplays() throws {
    let backend = BrightnessFake([1: 0.8, 2: 0.6])
    var transaction = try BrightnessTransaction(backend: backend)
    try transaction.dim(displayIDs: [1, 2])
    backend.failRestore(id: 1)
    #expect(throws: BrightnessError.self) { try transaction.restore() }
    #expect(transaction.snapshots == [1: 0.8])
    #expect(try backend.readBrightness(displayID: 2) == 0.6)
    backend.failRestore(id: nil)
    try transaction.restore()
    #expect(transaction.snapshots.isEmpty)
}

@Test func alreadyZeroBrightnessIsNotClaimedOrChanged() throws {
    let backend = BrightnessFake([1: 0])
    var transaction = try BrightnessTransaction(backend: backend)
    try transaction.dim(displayIDs: [1])
    #expect(backend.writeCount == 0)
    #expect(transaction.snapshots.isEmpty)
    #expect(try transaction.restore().restoredDisplayIDs.isEmpty)
}

@Test func reconcileRetiresManualChangesWithoutWritingHardware() throws {
    let backend = BrightnessFake([1: 0.8, 2: 0.6])
    var transaction = try BrightnessTransaction(backend: backend)
    try transaction.dim(displayIDs: [1, 2])
    let writesBefore = backend.writeCount
    backend.manuallySet(0.2, id: 1)
    var journal: [UInt32: Double] = [:]
    #expect(try transaction.reconcileExternalChanges { journal = $0 } == [1])
    #expect(transaction.snapshots == [2: 0.6])
    #expect(journal == [2: 0.6])
    #expect(backend.writeCount == writesBefore)
    #expect(try backend.readBrightness(displayID: 2) == 0)
}

@Test func reconcileUnchangedSessionDoesNotRewriteJournal() throws {
    let backend = BrightnessFake([1: 0.8])
    var transaction = try BrightnessTransaction(backend: backend)
    try transaction.dim(displayIDs: [1])
    var journalWrites = 0
    for _ in 0..<10 {
        #expect(try transaction.reconcileExternalChanges { _ in journalWrites += 1 }.isEmpty)
    }
    #expect(journalWrites == 0)
    #expect(backend.writeCount == 1)
}

@Test func reconcileJournalFailureRemainsRetryableWithoutHardwareWrites() throws {
    let backend = BrightnessFake([1: 0.8])
    var transaction = try BrightnessTransaction(backend: backend)
    try transaction.dim(displayIDs: [1])
    backend.manuallySet(0.2, id: 1)
    #expect(throws: BrightnessTestError.self) {
        try transaction.reconcileExternalChanges { _ in throw BrightnessTestError.journalFailed }
    }
    #expect(transaction.snapshots == [1: 0.8])
    #expect(try transaction.reconcileExternalChanges() == [1])
    #expect(backend.writeCount == 1)
}

@Test func restoredHardwareRetainsJournalRetryWithoutOverwritingLaterManualChanges() throws {
    let backend = BrightnessFake([1: 0.8])
    var transaction = try BrightnessTransaction(backend: backend)
    try transaction.dim(displayIDs: [1])
    #expect(throws: BrightnessError.self) {
        try transaction.restore { _ in throw BrightnessTestError.journalFailed }
    }
    #expect(try backend.readBrightness(displayID: 1) == 0.8)
    #expect(transaction.snapshots == [1: 0.8])
    let writesBefore = backend.writeCount
    backend.manuallySet(0.3, id: 1)
    var persisted: [UInt32: Double] = [1: 0.8]
    #expect(try transaction.reconcileExternalChanges { persisted = $0 } == [1])
    #expect(persisted.isEmpty)
    #expect(backend.writeCount == writesBefore)
    #expect(try backend.readBrightness(displayID: 1) == 0.3)
}
