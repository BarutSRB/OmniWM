// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing

import OmniWMIPC
@testable import OmniWM
@testable import OmniWMCtl

private enum CLIRuntimeTestError: Error, LocalizedError {
    case timedOut(
        step: String,
        expectedCount: Int,
        observedCount: Int,
        details: String
    )

    var errorDescription: String? {
        switch self {
        case let .timedOut(step, expectedCount, observedCount, details):
            return """
            Timed out during \(step). Expected at least \(expectedCount) items, observed \(observedCount).
            \(details)
            """
        }
    }
}

private actor WatchEventRecorder {
    private var events: [IPCEventEnvelope] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<[IPCEventEnvelope], Never>)] = []

    func record(_ event: IPCEventEnvelope) -> Int {
        events.append(event)
        let snapshot = events
        let readyIndices = waiters.indices.filter { snapshot.count >= waiters[$0].count }
        for index in readyIndices.reversed() {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: snapshot)
        }
        return snapshot.count
    }

    func waitForCount(_ count: Int) async -> [IPCEventEnvelope] {
        if events.count >= count {
            return events
        }

        return await withCheckedContinuation { continuation in
            waiters.append((count: count, continuation: continuation))
        }
    }

    func snapshot() -> [IPCEventEnvelope] {
        events
    }
}

private func makeCLITestSocketPath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("omniwm-cli-\(UUID().uuidString).sock")
        .path
}

private func linesAtFile(_ url: URL) -> [String] {
    guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8)
    else {
        return []
    }

    return text
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init)
}

private func waitForFileLines(
    at url: URL,
    expectedCount: Int,
    step: String,
    timeout: Duration = .seconds(4)
) async throws -> [String] {
    let deadline = ContinuousClock.now + timeout
    var lastObservedLines: [String] = []

    while ContinuousClock.now < deadline {
        let lines = linesAtFile(url)
        lastObservedLines = lines
        if lines.count >= expectedCount {
            return lines
        }

        try await Task.sleep(for: .milliseconds(25))
    }

    throw CLIRuntimeTestError.timedOut(
        step: step,
        expectedCount: expectedCount,
        observedCount: lastObservedLines.count,
        details: """
        File: \(url.path)
        Current lines:
        \(lastObservedLines.joined(separator: "\n"))
        """
    )
}

private func waitForRecordedEvents(
    _ recorder: WatchEventRecorder,
    expectedCount: Int,
    step: String,
    timeout: Duration = .seconds(2)
) async throws -> [IPCEventEnvelope] {
    try await withThrowingTaskGroup(of: [IPCEventEnvelope].self) { group in
        group.addTask {
            await recorder.waitForCount(expectedCount)
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            let snapshot = await recorder.snapshot()
            throw CLIRuntimeTestError.timedOut(
                step: step,
                expectedCount: expectedCount,
                observedCount: snapshot.count,
                details: """
                Recorded event ids:
                \(snapshot.map(\.id).joined(separator: "\n"))
                """
            )
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

@Suite(.serialized) @MainActor struct CLIRuntimeTests {
    @Test func watchContinuesAfterNonZeroExitWithInjectedChildRunner() async throws {
        let socketPath = makeCLITestSocketPath()
        let fixture = makeTwoMonitorLayoutPlanTestController()

        let server = IPCServer(controller: fixture.controller, socketPath: socketPath)
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: IPCSocketPath.secretPath(forSocketPath: socketPath))
        }
        try server.start()

        let recorder = WatchEventRecorder()
        CLIRuntime.setWatchChildRunnerForTests { event, _, _ in
            let eventCount = await recorder.record(event)
            return CLIRuntime.WatchChildResult(
                terminationReason: .exit,
                terminationStatus: eventCount == 1 ? 7 : 0
            )
        }
        defer {
            CLIRuntime.setWatchChildRunnerForTests(nil)
        }

        let runtimeTask = Task.detached {
            await CLIRuntime.run(
                arguments: [
                    "omniwmctl",
                    "watch",
                    "focused-monitor",
                    "--exec",
                    "/usr/bin/true"
                ],
                client: IPCClient(socketPath: socketPath)
            )
        }
        defer {
            runtimeTask.cancel()
        }

        let initialEvents = try await waitForRecordedEvents(
            recorder,
            expectedCount: 1,
            step: "waiting for initial injected watch event",
            timeout: .seconds(4)
        )
        #expect(initialEvents.count >= 1)
        #expect(fixture.controller.workspaceManager.setInteractionMonitor(fixture.secondaryMonitor.id))

        let secondEvents = try await waitForRecordedEvents(
            recorder,
            expectedCount: 2,
            step: "waiting for secondary monitor injected watch event",
            timeout: .seconds(4)
        )
        #expect(secondEvents.count >= 2)
        #expect(fixture.controller.workspaceManager.setInteractionMonitor(fixture.primaryMonitor.id))

        let events = try await waitForRecordedEvents(
            recorder,
            expectedCount: 3,
            step: "waiting for third injected watch event",
            timeout: .seconds(4)
        )

        runtimeTask.cancel()
        _ = await runtimeTask.value

        #expect(events.count >= 3)
        #expect(events.allSatisfy { $0.channel == .focusedMonitor })

        let firstEvent = events[0]
        let secondEvent = events[1]
        let thirdEvent = events[2]

        if case let .focusedMonitor(payload) = firstEvent.result.payload {
            #expect(payload.display?.id == "display:\(fixture.primaryMonitor.displayId)")
        } else {
            Issue.record("Expected focused-monitor payload for initial injected watch event")
        }

        if case let .focusedMonitor(payload) = secondEvent.result.payload {
            #expect(payload.display?.id == "display:\(fixture.secondaryMonitor.displayId)")
        } else {
            Issue.record("Expected focused-monitor payload for second injected watch event")
        }

        if case let .focusedMonitor(payload) = thirdEvent.result.payload {
            #expect(payload.display?.id == "display:\(fixture.primaryMonitor.displayId)")
        } else {
            Issue.record("Expected focused-monitor payload for third injected watch event")
        }
    }

    @Test func watchExecStreamsFocusedMonitorEventsToSerializedChildrenAndContinuesAfterNonZeroExit() async throws {
        let socketPath = makeCLITestSocketPath()
        let fixture = makeTwoMonitorLayoutPlanTestController()

        let server = IPCServer(controller: fixture.controller, socketPath: socketPath)
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: IPCSocketPath.secretPath(forSocketPath: socketPath))
        }
        try server.start()

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omniwm-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let scriptURL = tempDirectory.appendingPathComponent("watch-child.zsh")
        let outputURL = tempDirectory.appendingPathComponent("watch-output.txt")
        let counterURL = tempDirectory.appendingPathComponent("watch-counter.txt")

        let script = """
        #!/bin/zsh
        set -eu
        output_file="${OMNIWM_WATCH_TEST_OUTPUT:?}"
        counter_file="${OMNIWM_WATCH_TEST_COUNTER:?}"

        count=0
        if [[ -f "$counter_file" ]]; then
          count=$(<"$counter_file")
        fi
        count=$((count + 1))
        print -n -- "$count" > "$counter_file"
        printf '%s\\t%s\\t%s\\t' "$OMNIWM_EVENT_CHANNEL" "$OMNIWM_EVENT_KIND" "$OMNIWM_EVENT_ID" >> "$output_file"
        cat >> "$output_file"
        sleep 0.15
        if [[ "$count" -eq 1 ]]; then
          exit 7
        fi
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        #expect(chmod(scriptURL.path, 0o755) == 0)

        setenv("OMNIWM_WATCH_TEST_OUTPUT", outputURL.path, 1)
        setenv("OMNIWM_WATCH_TEST_COUNTER", counterURL.path, 1)
        defer {
            unsetenv("OMNIWM_WATCH_TEST_OUTPUT")
            unsetenv("OMNIWM_WATCH_TEST_COUNTER")
        }

        let runtimeTask = Task.detached {
            await CLIRuntime.run(
                arguments: [
                    "omniwmctl",
                    "watch",
                    "focused-monitor",
                    "--exec",
                    scriptURL.path
                ],
                client: IPCClient(socketPath: socketPath)
            )
        }
        defer {
            runtimeTask.cancel()
        }

        let initialLines = try await waitForFileLines(
            at: outputURL,
            expectedCount: 1,
            step: "waiting for initial integration watch output"
        )
        #expect(initialLines.count >= 1)
        #expect(fixture.controller.workspaceManager.setInteractionMonitor(fixture.secondaryMonitor.id))
        let secondLines = try await waitForFileLines(
            at: outputURL,
            expectedCount: 2,
            step: "waiting for secondary monitor integration watch output"
        )
        #expect(secondLines.count >= 2)
        #expect(fixture.controller.workspaceManager.setInteractionMonitor(fixture.primaryMonitor.id))

        _ = try await waitForFileLines(
            at: outputURL,
            expectedCount: 3,
            step: "waiting for third integration watch output"
        )
        try await Task.sleep(for: .milliseconds(400))
        let lines = linesAtFile(outputURL)

        runtimeTask.cancel()
        _ = await runtimeTask.value

        #expect(lines.count == 3)

        let firstParts = lines[0].split(separator: "\t", maxSplits: 3).map(String.init)
        let secondParts = lines[1].split(separator: "\t", maxSplits: 3).map(String.init)
        let thirdParts = lines[2].split(separator: "\t", maxSplits: 3).map(String.init)
        #expect(firstParts.count == 4)
        #expect(secondParts.count == 4)
        #expect(thirdParts.count == 4)
        #expect(firstParts[0] == IPCSubscriptionChannel.focusedMonitor.rawValue)
        #expect(firstParts[1] == IPCResultKind.focusedMonitor.rawValue)
        #expect(secondParts[0] == IPCSubscriptionChannel.focusedMonitor.rawValue)
        #expect(secondParts[1] == IPCResultKind.focusedMonitor.rawValue)
        #expect(thirdParts[0] == IPCSubscriptionChannel.focusedMonitor.rawValue)
        #expect(thirdParts[1] == IPCResultKind.focusedMonitor.rawValue)

        let firstEvent = try IPCWire.decodeEvent(from: Data(firstParts[3].utf8))
        let secondEvent = try IPCWire.decodeEvent(from: Data(secondParts[3].utf8))
        let thirdEvent = try IPCWire.decodeEvent(from: Data(thirdParts[3].utf8))
        #expect(firstEvent.channel == .focusedMonitor)
        #expect(secondEvent.channel == .focusedMonitor)
        #expect(thirdEvent.channel == .focusedMonitor)

        if case let .focusedMonitor(payload) = firstEvent.result.payload {
            #expect(payload.display?.id == "display:\(fixture.primaryMonitor.displayId)")
        } else {
            Issue.record("Expected focused-monitor payload for initial watch child")
        }

        if case let .focusedMonitor(payload) = secondEvent.result.payload {
            #expect(payload.display?.id == "display:\(fixture.secondaryMonitor.displayId)")
        } else {
            Issue.record("Expected focused-monitor payload for second watch child")
        }

        if case let .focusedMonitor(payload) = thirdEvent.result.payload {
            #expect(payload.display?.id == "display:\(fixture.primaryMonitor.displayId)")
        } else {
            Issue.record("Expected focused-monitor payload for third watch child")
        }
    }
}
