import Foundation
import Testing

import OmniWMIPC
@testable import OmniWM
@testable import OmniWMCtl

private enum CLIRuntimeTestError: Error {
    case timedOut
}

private func makeCLITestSocketPath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("omniwm-cli-\(UUID().uuidString).sock")
        .path
}

private func waitForFileLines(
    at url: URL,
    expectedCount: Int,
    timeout: Duration = .seconds(2)
) async throws -> [String] {
    let deadline = ContinuousClock.now + timeout

    while ContinuousClock.now < deadline {
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8)
        {
            let lines = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            if lines.count >= expectedCount {
                return lines
            }
        }

        try await Task.sleep(for: .milliseconds(25))
    }

    throw CLIRuntimeTestError.timedOut
}

@Suite(.serialized) @MainActor struct CLIRuntimeTests {
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

        let runtimeTask = Task {
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

        let initialLines = try await waitForFileLines(at: outputURL, expectedCount: 1)
        #expect(initialLines.count >= 1)
        #expect(fixture.controller.workspaceManager.setInteractionMonitor(fixture.secondaryMonitor.id))
        let secondLines = try await waitForFileLines(at: outputURL, expectedCount: 2)
        #expect(secondLines.count >= 2)
        #expect(fixture.controller.workspaceManager.setInteractionMonitor(fixture.primaryMonitor.id))

        _ = try await waitForFileLines(at: outputURL, expectedCount: 3)
        try await Task.sleep(for: .milliseconds(250))
        let lines = try await waitForFileLines(at: outputURL, expectedCount: 3, timeout: .milliseconds(200))

        runtimeTask.cancel()
        _ = await runtimeTask.value

        #expect(lines.count >= 3)

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
