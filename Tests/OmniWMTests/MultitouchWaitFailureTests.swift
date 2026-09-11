// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class MultitouchWaitFailureTests: XCTestCase {
    private enum WaitFailure: Error {
        case rejected
    }

    func testNoncancelledStartupWaitFailureExhaustsAndAllowsFreshWakeEpisode() async {
        let backend = FakeMultitouchBackend()
        var durations: [Duration] = []
        let source = makeSource(backend: backend) { duration in
            durations.append(duration)
            XCTAssertFalse(Task.isCancelled)
            throw WaitFailure.rejected
        }
        defer { source.shutdown() }
        XCTAssertTrue(source.startLifecycle())
        await drainMultitouchTasks()

        let failed = source.diagnosticsSnapshot()
        XCTAssertEqual(failed.state, .exhausted)
        XCTAssertNil(failed.activeGeneration)
        XCTAssertEqual(failed.retryAttempt, 0)
        XCTAssertTrue(failed.retryExhausted)
        XCTAssertNil(failed.nextRetryDelay)
        XCTAssertEqual(backend.callCount(.enumerate), 0)
        XCTAssertEqual(durations, [.milliseconds(100)])

        source.requestRevalidation(.wake)
        await drainMultitouchTasks()

        let rearmed = source.diagnosticsSnapshot()
        XCTAssertEqual(rearmed.state, .exhausted)
        XCTAssertEqual(rearmed.retryEpisode, failed.retryEpisode + 1)
        XCTAssertEqual(rearmed.retryAttempt, 0)
        XCTAssertTrue(rearmed.retryExhausted)
        XCTAssertNil(rearmed.nextRetryDelay)
        XCTAssertEqual(backend.callCount(.enumerate), 0)
        XCTAssertEqual(durations, [.milliseconds(100), .seconds(1)])
    }

    func testNoncancelledWakeWaitFailurePreservesRunningGenerationAndRegistrations() async {
        let backend = FakeMultitouchBackend()
        let device = FakeMultitouchBackend.device(pointer: 0x1001, registryId: 101)
        backend.enumerations = [FakeMultitouchBackend.enumeration([device])]
        var durations: [Duration] = []
        let source = makeSource(backend: backend) { duration in
            durations.append(duration)
            XCTAssertFalse(Task.isCancelled)
            if durations.count > 1 {
                throw WaitFailure.rejected
            }
        }
        defer { source.shutdown() }
        XCTAssertTrue(source.startLifecycle())
        await drainMultitouchTasks()
        let running = source.diagnosticsSnapshot()
        XCTAssertEqual(running.state, .running)
        XCTAssertNotNil(running.activeGeneration)
        let callsBeforeFailure = backend.calls

        source.requestRevalidation(.wake)
        await drainMultitouchTasks()

        let failed = source.diagnosticsSnapshot()
        XCTAssertEqual(failed.state, .running)
        XCTAssertEqual(failed.activeGeneration, running.activeGeneration)
        XCTAssertEqual(failed.registeredDeviceCount, 1)
        XCTAssertEqual(failed.retryAttempt, 0)
        XCTAssertTrue(failed.retryExhausted)
        XCTAssertNil(failed.nextRetryDelay)
        XCTAssertEqual(backend.calls, callsBeforeFailure)
        XCTAssertEqual(durations, [.milliseconds(100), .seconds(1)])
    }

    private func makeSource(
        backend: FakeMultitouchBackend,
        sleep: @escaping @MainActor (Duration) async throws -> Void
    ) -> MultitouchGestureSource {
        let operations = backend.operations(sleeper: ManualMultitouchSleeper())
        return MultitouchGestureSource(
            operations: MultitouchGestureSource.LifecycleOperations(
                enumerate: operations.enumerate,
                register: operations.register,
                start: operations.start,
                isRunning: operations.isRunning,
                stop: operations.stop,
                unregister: operations.unregister,
                sleep: sleep
            ),
            topologyMonitoringEnabled: false
        )
    }
}
