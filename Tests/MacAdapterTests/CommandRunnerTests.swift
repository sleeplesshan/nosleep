import Darwin
import Foundation
import Testing
@testable import NoSleep
import NoSleepCore

@Suite(.timeLimit(.minutes(1)))
struct CommandRunnerTests {
    @Test func capturesIndependentStreamsAndExitStatus() async throws {
        let result = try await CommandRunner.run("/bin/sh", ["-c", "printf 'standard output'; printf 'diagnostic detail' >&2; exit 17"], timeout: 2)
        #expect(result.status == 17)
        #expect(result.output == "standard output")
        #expect(result.error == "diagnostic detail")
    }

    @Test func passesArgumentsLiterallyAndPinsLocale() async throws {
        let text = "space ' quote $HOME $(echo unexpected) ; end"
        let result = try await CommandRunner.run("/usr/bin/printf", ["%s", text], timeout: 2)
        #expect(result.status == 0)
        #expect(result.output == text)
        let locale = try await CommandRunner.run("/bin/sh", ["-c", "printf '%s/%s' \"$LC_ALL\" \"$LANG\""], timeout: 2)
        #expect(locale.output == "C/C")
    }

    @Test func reportsMissingExecutablePromptly() async {
        let start = ProcessInfo.processInfo.systemUptime
        await #expect(throws: (any Error).self) {
            try await CommandRunner.run("/nonexistent/nosleep-test-executable", [], timeout: 1)
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 3)
    }

    @Test func rejectsOversizedCompletedOutput() async {
        do {
            _ = try await CommandRunner.run("/usr/bin/head", ["-c", "262145", "/dev/zero"], timeout: 2)
            Issue.record("Oversized output must throw")
        } catch MacServiceError.oversizedOutput {
            // Expected; output is bounded before it is loaded into the app.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func timeoutKillsOwnedProcessAndReturnsWithinBound() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nosleep-runner-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let start = ProcessInfo.processInfo.systemUptime
        do {
            // exec keeps the recorded PID as the process owned by CommandRunner; ignored TERM exercises KILL fallback.
            _ = try await CommandRunner.run("/bin/sh", ["-c", "trap '' TERM; printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 15", "test", pidFile.path], timeout: 0.3)
            Issue.record("Sleep must time out")
        } catch MacServiceError.timeout {
            // Expected.
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 4)
        let contents = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(Int32(contents))
        // Clean up the test process if a regression leaves it behind; never touch other processes.
        defer { if kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) } }
        for _ in 0..<20 {
            if kill(pid, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func repeatedSequentialCommandsDoNotStickAfterTermination() async throws {
        for index in 0..<20 {
            let result = try await CommandRunner.run("/usr/bin/printf", ["%s", "run-\(index)"], timeout: 2)
            #expect(result.status == 0)
            #expect(result.output == "run-\(index)")
        }
    }

    @Test func concurrentCommandsHaveIndependentCompletionAndOutput() async throws {
        try await withThrowingTaskGroup(of: (Int, CommandResult).self) { group in
            for index in 0..<24 {
                group.addTask {
                    (index, try await CommandRunner.run("/usr/bin/printf", ["%s", "parallel-\(index)"], timeout: 3))
                }
            }
            var completed = Set<Int>()
            for try await (index, result) in group {
                #expect(result.status == 0)
                #expect(result.output == "parallel-\(index)")
                #expect(result.error.isEmpty)
                completed.insert(index)
            }
            #expect(completed.count == 24)
        }
    }

    @Test func repeatedReadOnlyPowerQueriesReturnKnownStates() async throws {
        let backend = MacPowerBackend()
        for _ in 0..<5 {
            let state = try await backend.readState()
            #expect(state == .enabled || state == .disabled)
        }
    }
}
