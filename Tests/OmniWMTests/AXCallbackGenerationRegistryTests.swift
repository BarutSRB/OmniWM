// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Dispatch
@testable import OmniWM
import XCTest

final class AXCallbackGenerationRegistryTests: XCTestCase {
    func testRegisteredObserverRunsOnlyInItsGeneration() {
        let registry = AXCallbackGenerationRegistry()
        let generation = registry.currentGeneration
        var callbackCount = 0

        XCTAssertTrue(registry.register(observerKey: 1, generation: generation))
        XCTAssertTrue(registry.performIfCurrent(observerKey: 1) {
            callbackCount += 1
        })
        XCTAssertEqual(callbackCount, 1)
    }

    func testAdvanceRejectsRetiredObserversAndInFlightRegistration() {
        let registry = AXCallbackGenerationRegistry()
        let retiredGeneration = registry.currentGeneration
        XCTAssertTrue(registry.register(observerKey: 1, generation: retiredGeneration))

        let currentGeneration = registry.advance()
        var callbackCount = 0

        XCTAssertFalse(registry.isCurrent(retiredGeneration))
        XCTAssertTrue(registry.isCurrent(currentGeneration))
        XCTAssertFalse(registry.performIfCurrent(observerKey: 1) {
            callbackCount += 1
        })
        XCTAssertFalse(registry.register(observerKey: 2, generation: retiredGeneration))
        XCTAssertFalse(registry.performIfCurrent(observerKey: 2) {
            callbackCount += 1
        })
        XCTAssertEqual(callbackCount, 0)
    }

    func testNewGenerationAcceptsReplacementObserver() {
        let registry = AXCallbackGenerationRegistry()
        let retiredGeneration = registry.currentGeneration
        XCTAssertTrue(registry.register(observerKey: 1, generation: retiredGeneration))

        let currentGeneration = registry.advance()
        var callbackCount = 0

        XCTAssertTrue(registry.register(observerKey: 2, generation: currentGeneration))
        XCTAssertFalse(registry.register(observerKey: 2, generation: retiredGeneration))
        XCTAssertTrue(registry.performIfCurrent(observerKey: 2) {
            callbackCount += 1
        })
        XCTAssertFalse(registry.performIfCurrent(observerKey: 1) {
            callbackCount += 1
        })
        XCTAssertEqual(callbackCount, 1)
    }

    func testUnregisterRejectsObserverWithoutAdvancingGeneration() {
        let registry = AXCallbackGenerationRegistry()
        let generation = registry.currentGeneration
        XCTAssertTrue(registry.register(observerKey: 1, generation: generation))

        registry.unregister(observerKey: 1)

        XCTAssertFalse(registry.performIfCurrent(observerKey: 1) {})
        XCTAssertTrue(registry.isCurrent(generation))
    }

    func testAdvanceWaitsForAdmittedCallbackToLeaveGate() {
        let registry = AXCallbackGenerationRegistry()
        let generation = registry.currentGeneration
        XCTAssertTrue(registry.register(observerKey: 1, generation: generation))

        let callbackEntered = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let advanceStarted = DispatchSemaphore(value: 0)
        let advanceFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            registry.performIfCurrent(observerKey: 1) {
                callbackEntered.signal()
                releaseCallback.wait()
            }
        }
        XCTAssertEqual(callbackEntered.wait(timeout: .now() + 2), .success)

        DispatchQueue.global().async {
            advanceStarted.signal()
            registry.advance()
            advanceFinished.signal()
        }
        XCTAssertEqual(advanceStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(advanceFinished.wait(timeout: .now() + 0.05), .timedOut)

        releaseCallback.signal()

        XCTAssertEqual(advanceFinished.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(registry.performIfCurrent(observerKey: 1) {})
    }
}
