// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

final class FrameObservationStateTests: XCTestCase {
    func testMismatchReschedulesLatestEventAndStopsAtExistingBudget() throws {
        var state = FrameObservationState(capacity: 2, timeoutNs: 1_000, maxMismatchCount: 2)
        state.beginCapture(generation: 7)
        let request = request(windowId: 42, sequence: 1)
        _ = state.register(request, pid: 99, lane: .ordinary, attempt: 2, startedNs: 10)
        let firstToken = try XCTUnwrap(state.noteFrameChanged(windowId: 42, eventNs: 20))
        XCTAssertNil(state.noteFrameChanged(windowId: 42, eventNs: 30))
        XCTAssertNil(state.noteFrameChanged(windowId: 42, eventNs: 40))

        let first = state.completeObservation(windowId: 42, token: firstToken, observed: .zero, sampledNs: 50)
        let nextToken = try XCTUnwrap(first.rescheduleToken)
        XCTAssertEqual(first.outcome, "server-observation/mismatch/sample")
        XCTAssertFalse(first.terminal)
        XCTAssertEqual(first.pending?.pid, 99)
        XCTAssertEqual(first.pending?.lastEventNs, 20)
        XCTAssertEqual(first.pending?.lastSampleNs, 50)
        XCTAssertEqual(first.pending?.mismatchCount, 1)
        XCTAssertNotEqual(nextToken, firstToken)
        XCTAssertEqual(state.prepareObservation(windowId: 42, token: firstToken), .none)
        XCTAssertEqual(state.prepareObservation(windowId: 42, token: nextToken), .sample)

        XCTAssertNil(state.noteFrameChanged(windowId: 42, eventNs: 60))
        let final = state.completeObservation(windowId: 42, token: nextToken, observed: nil, sampledNs: 70)
        XCTAssertEqual(final.outcome, "server-observation/unavailable")
        XCTAssertTrue(final.terminal)
        XCTAssertNil(final.rescheduleToken)
        XCTAssertEqual(final.pending?.lastEventNs, 40)
        XCTAssertEqual(final.pending?.lastSampleNs, 70)
        XCTAssertEqual(final.pending?.mismatchCount, 2)
        XCTAssertNil(final.pending?.lastObserved)
        XCTAssertEqual(state.pendingCount, 0)
        XCTAssertNil(state.noteFrameChanged(windowId: 42, eventNs: 80))
        XCTAssertEqual(state.prepareObservation(windowId: 42, token: nextToken), .none)
    }

    func testAcceptedTargetRetiresScheduledAndDirtyObservations() throws {
        var state = FrameObservationState(capacity: 2, timeoutNs: 1_000, maxMismatchCount: 3)
        state.beginCapture(generation: 7)
        let request = request(windowId: 42, sequence: 1)
        _ = state.register(request, pid: 99, lane: .ordinary, attempt: 1, startedNs: 10)
        let firstToken = try XCTUnwrap(state.noteFrameChanged(windowId: 42, eventNs: 20))
        let accepted = CGRect(x: 40, y: 50, width: 280, height: 180)
        let sample = state.completeObservation(windowId: 42, token: firstToken, observed: accepted, sampledNs: 30)
        XCTAssertFalse(sample.terminal)
        let staleToken = try XCTUnwrap(state.noteFrameChanged(windowId: 42, eventNs: 40))
        XCTAssertNil(state.noteFrameChanged(windowId: 42, eventNs: 50))

        let matched = try XCTUnwrap(state.updateAcceptedTarget(
            traceRequestId: request.traceRequestId,
            target: accepted
        ))
        XCTAssertEqual(matched.target, accepted)
        XCTAssertEqual(matched.lastObserved, accepted)
        XCTAssertEqual(matched.lastEventNs, 20)
        XCTAssertEqual(matched.lastSampleNs, 30)
        XCTAssertEqual(state.pendingCount, 0)
        XCTAssertEqual(state.prepareObservation(windowId: 42, token: staleToken), .none)
        XCTAssertNil(state.completeObservation(windowId: 42, token: staleToken, observed: accepted, sampledNs: 60)
            .pending)
    }

    func testCapacityEvictionAndExpiryClearOnlyTheirWindowObservations() throws {
        var state = FrameObservationState(capacity: 1, timeoutNs: 100, maxMismatchCount: 2)
        state.beginCapture(generation: 7)
        let first = request(windowId: 41, sequence: 1)
        let second = request(windowId: 42, sequence: 2)
        _ = state.register(first, pid: 99, lane: .ordinary, attempt: 1, startedNs: 10)
        let firstToken = try XCTUnwrap(state.noteFrameChanged(windowId: 41, eventNs: 20))
        XCTAssertNil(state.noteFrameChanged(windowId: 41, eventNs: 30))
        let (superseded, eviction) = state.register(second, pid: 99, lane: .ordinary, attempt: 1, startedNs: 40)
        XCTAssertNil(superseded)
        XCTAssertEqual(eviction?.traceRequestId, first.traceRequestId)
        XCTAssertEqual(state.prepareObservation(windowId: 41, token: firstToken), .none)
        let secondToken = try XCTUnwrap(state.noteFrameChanged(windowId: 42, eventNs: 50))
        XCTAssertNil(state.noteFrameChanged(windowId: 42, eventNs: 60))
        XCTAssertTrue(state.expire(nowNs: 139).isEmpty)
        XCTAssertEqual(state.prepareObservation(windowId: 42, token: secondToken), .sample)
        XCTAssertEqual(state.expire(nowNs: 140).map(\.traceRequestId), [second.traceRequestId])
        XCTAssertEqual(state.pendingCount, 0)
        XCTAssertEqual(state.prepareObservation(windowId: 42, token: secondToken), .none)
        XCTAssertNil(state.noteFrameChanged(windowId: 42, eventNs: 150))
    }

    private func request(windowId: Int, sequence: UInt64) -> AppAXFrameWriteRequest {
        AppAXFrameWriteRequest(
            requestId: sequence,
            pid: 7,
            windowId: windowId,
            expectedWindow: AXWindowRef(element: AXUIElementCreateApplication(7), windowId: windowId),
            frame: CGRect(x: 10, y: 20, width: 300, height: 200),
            currentFrameHint: nil,
            generation: 1,
            verify: false,
            traceRequestId: 7 << 32 | sequence
        )
    }
}
