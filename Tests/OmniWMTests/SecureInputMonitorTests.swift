// SPDX-License-Identifier: GPL-2.0-only
import Testing

@testable import OmniWM

@Suite(.serialized) @MainActor struct SecureInputMonitorTests {
    private func makeMonitorForTests() -> SecureInputMonitor {
        let monitor = SecureInputMonitor()
        monitor.secureInputStateProviderForTests = { true }
        monitor.eventTapInstallerForTests = { (tap: nil, runLoopSource: nil) }
        return monitor
    }

    @Test func stopClearsCachedStateBeforeRestart() {
        let monitor = makeMonitorForTests()
        var states: [Bool] = []

        monitor.start { states.append($0) }
        monitor.stop()
        monitor.start { states.append($0) }
        monitor.stop()

        #expect(states == [true, true])
    }

    @Test func repeatedStartRefreshesCachedStateAndCallback() {
        let monitor = makeMonitorForTests()
        var states: [String] = []

        monitor.start { states.append("first:\($0)") }
        monitor.start { states.append("second:\($0)") }
        monitor.stop()

        #expect(states == ["first:true", "second:true"])
    }
}
