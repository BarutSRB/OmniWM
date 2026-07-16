// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

private final class AXBoundaryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@MainActor
final class AXFullRescanBoundaryTests: XCTestCase {
    func testFullRescanRoutesEvidenceAndPreservedStateToPersistentContexts() {
        XCTAssertEqual(
            AXManager.fullRescanEnumerationRoute(
                activationPolicy: .regular,
                hasDiscoveryEvidence: true,
                hasContext: false,
                hasPreservedState: false
            ),
            .persistent
        )
        XCTAssertEqual(
            AXManager.fullRescanEnumerationRoute(
                activationPolicy: .accessory,
                hasDiscoveryEvidence: false,
                hasContext: true,
                hasPreservedState: false
            ),
            .persistent
        )
        XCTAssertEqual(
            AXManager.fullRescanEnumerationRoute(
                activationPolicy: .accessory,
                hasDiscoveryEvidence: false,
                hasContext: false,
                hasPreservedState: true
            ),
            .persistent
        )
    }

    func testFullRescanRoutesOnlyEvidenceFreeRegularAppsToOneShotProbes() {
        XCTAssertEqual(
            AXManager.fullRescanEnumerationRoute(
                activationPolicy: .regular,
                hasDiscoveryEvidence: false,
                hasContext: false,
                hasPreservedState: false
            ),
            .oneShot
        )
        XCTAssertNil(
            AXManager.fullRescanEnumerationRoute(
                activationPolicy: .accessory,
                hasDiscoveryEvidence: false,
                hasContext: false,
                hasPreservedState: false
            )
        )
        XCTAssertNil(
            AXManager.fullRescanEnumerationRoute(
                activationPolicy: .prohibited,
                hasDiscoveryEvidence: true,
                hasContext: true,
                hasPreservedState: true
            )
        )
    }

    func testCandidateManageabilityUsesCapturedGeometryEvidence() {
        let pid: pid_t = 72_001
        let windowId = 72_002
        let candidate = FullRescanWindowCandidate(
            enumeratedWindow: AXEnumeratedWindow(
                axRef: AXWindowRef(
                    element: AXUIElementCreateApplication(pid),
                    windowId: windowId
                ),
                axPid: pid,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                admissionGeometry: WindowAdmissionGeometryEvidence(
                    isSizeSettable: true,
                    frame: CGRect(x: 10, y: 20, width: 800, height: 600)
                )
            ),
            logicalPID: pid,
            windowServerInfo: nil,
            windowServerOwnerPID: nil,
            enumerationRoute: .oneShot
        )

        XCTAssertTrue(candidate.isManageable)
    }

    func testCandidateFullscreenUsesCapturedEvidenceWithoutLiveAXFallback() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let explicitWindowed = candidate(
            pid: 72_013,
            windowId: 72_014,
            route: .persistent,
            isManageable: true,
            frame: screenFrame,
            fullscreenAttribute: false
        )
        let frameFallback = candidate(
            pid: 72_015,
            windowId: 72_016,
            route: .persistent,
            isManageable: true,
            frame: screenFrame,
            fullscreenAttribute: nil
        )

        XCTAssertFalse(explicitWindowed.isFullscreen(screenFrames: [screenFrame]))
        XCTAssertTrue(frameFallback.isFullscreen(screenFrames: [screenFrame]))
    }

    func testPromotionIncludesOnlySelectedOneShotWinners() {
        let windowId = 72_010
        let persistentPID: pid_t = 72_011
        let oneShotPID: pid_t = 72_012
        let persistent = candidate(
            pid: persistentPID,
            windowId: windowId,
            route: .persistent,
            isManageable: true
        )
        let losingProbe = candidate(
            pid: oneShotPID,
            windowId: windowId,
            route: .oneShot,
            isManageable: false
        )

        let selected = AXManager.selectFullRescanCandidates(
            [windowId: [losingProbe, persistent]],
            activationPolicyByPID: [persistentPID: .regular, oneShotPID: .regular],
            preservingPIDsByWindowId: [:]
        )
        let promotions = AXManager.oneShotPromotionCandidatesByPID(selected)

        XCTAssertEqual(selected.map(\.pid), [persistentPID])
        XCTAssertTrue(promotions.isEmpty)
    }

    func testFrameSuccessCallbackRejectsStaleResults() throws {
        let ledger = AXFrameApplicationLedger()
        let pid: pid_t = 72_003
        let windowId = 72_004
        let firstTarget = CGRect(x: 10, y: 20, width: 800, height: 600)
        let secondTarget = CGRect(x: 30, y: 40, width: 900, height: 700)
        let firstRequest = try XCTUnwrap(
            ledger.prepareFrameApplication(
                pid: pid,
                windowId: windowId,
                frame: firstTarget,
                isRetry: false,
                terminalObserver: nil
            ).request
        )
        let secondRequest = try XCTUnwrap(
            ledger.prepareFrameApplication(
                pid: pid,
                windowId: windowId,
                frame: secondTarget,
                isRetry: false,
                terminalObserver: nil
            ).request
        )
        var acceptedWindowIds: [Int] = []

        _ = ledger.handleFrameApplyResults([successfulResult(for: firstRequest)]) {
            acceptedWindowIds.append($0.windowId)
        }
        XCTAssertTrue(acceptedWindowIds.isEmpty)

        _ = ledger.handleFrameApplyResults([successfulResult(for: secondRequest)]) {
            acceptedWindowIds.append($0.windowId)
        }
        XCTAssertEqual(acceptedWindowIds, [windowId])
    }

    func testIncarnationResetRejectsOldResultAndForcesSameFrameWrite() throws {
        let ledger = AXFrameApplicationLedger()
        let oldPID: pid_t = 72_005
        let newPID: pid_t = 72_006
        let windowId = 72_007
        let target = CGRect(x: 10, y: 20, width: 800, height: 600)
        let oldRequest = try XCTUnwrap(
            ledger.prepareFrameApplication(
                pid: oldPID,
                windowId: windowId,
                frame: target,
                isRetry: false,
                terminalObserver: nil
            ).request
        )
        _ = ledger.removeWindowState(windowId: windowId)
        ledger.forceApplyNextFrame(for: windowId)
        let newRequest = try XCTUnwrap(
            ledger.prepareFrameApplication(
                pid: newPID,
                windowId: windowId,
                frame: target,
                isRetry: false,
                terminalObserver: nil
            ).request
        )
        var accepted: [AXFrameApplyResult] = []

        _ = ledger.handleFrameApplyResults([successfulResult(for: oldRequest)]) {
            accepted.append($0)
        }
        XCTAssertTrue(accepted.isEmpty)

        _ = ledger.handleFrameApplyResults([successfulResult(for: newRequest)]) {
            accepted.append($0)
        }
        XCTAssertEqual(accepted.map(\.pid), [newPID])
    }

    func testGenerationMoveInvalidatesLateOldWindowResult() {
        let generations = LockedWindowGenerationMap()
        let oldWindowId = 72_017
        let newWindowId = 72_018
        let inFlightGeneration = generations.nextGeneration(for: oldWindowId)

        generations.invalidateAndMoveValue(from: oldWindowId, to: newWindowId)

        XCTAssertFalse(generations.isCurrent(inFlightGeneration, for: oldWindowId))
        XCTAssertFalse(generations.isCurrent(inFlightGeneration, for: newWindowId))
    }

    func testManagerDoesNotRecordRejectedRawSuccessAsFrameActivity() {
        let manager = AXManager()
        let pid: pid_t = 72_008
        let windowId = 72_009
        let target = CGRect(x: 10, y: 20, width: 800, height: 600)
        manager.recordParkCommand(for: windowId)

        manager.handleFrameApplyResults([
            AXFrameApplyResult(
                requestId: 999,
                pid: pid,
                windowId: windowId,
                targetFrame: target,
                currentFrameHint: nil,
                writeResult: AXFrameWriteResult(
                    targetFrame: target,
                    observedFrame: target,
                    writeOrder: .sizeThenPosition,
                    sizeError: .success,
                    positionError: .success,
                    failureReason: nil
                )
            )
        ])

        XCTAssertTrue(manager.parkQuietSinceCommand(for: windowId))
        manager.cleanup()
    }

    private func successfulResult(for request: AXFrameApplicationRequest) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: request.requestId,
            pid: request.pid,
            windowId: request.windowId,
            targetFrame: request.frame,
            currentFrameHint: request.currentFrameHint,
            writeResult: AXFrameWriteResult(
                targetFrame: request.frame,
                observedFrame: request.frame,
                writeOrder: .sizeThenPosition,
                sizeError: .success,
                positionError: .success,
                failureReason: nil
            )
        )
    }

    private func candidate(
        pid: pid_t,
        windowId: Int,
        route: FullRescanEnumerationRoute,
        isManageable: Bool,
        frame: CGRect? = nil,
        fullscreenAttribute: Bool? = nil
    ) -> FullRescanWindowCandidate {
        FullRescanWindowCandidate(
            enumeratedWindow: AXEnumeratedWindow(
                axRef: AXWindowRef(
                    element: AXUIElementCreateApplication(pid),
                    windowId: windowId
                ),
                axPid: pid,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                admissionGeometry: WindowAdmissionGeometryEvidence(
                    isSizeSettable: isManageable,
                    frame: frame ?? (isManageable ? CGRect(x: 0, y: 0, width: 800, height: 600) : nil)
                ),
                fullscreenAttribute: fullscreenAttribute
            ),
            logicalPID: pid,
            windowServerInfo: nil,
            windowServerOwnerPID: nil,
            enumerationRoute: route
        )
    }
}

final class AXRunLoopTimeoutBoundaryTests: XCTestCase {
    func testStartedBodyRemainsTimeBounded() async {
        let thread = Thread {
            let port = NSMachPort()
            RunLoop.current.add(port, forMode: .default)
            CFRunLoopRun()
        }
        thread.start()
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let cacheMutation = AXBoundaryCounter()
        let start = ContinuousClock.now

        do {
            _ = try await thread.runInLoop(timeout: .milliseconds(25)) { job in
                defer { finished.signal() }
                started.signal()
                Thread.sleep(forTimeInterval: 0.15)
                try job.checkCancellation()
                cacheMutation.increment()
                return true
            }
            XCTFail("Expected timeout")
        } catch {
            XCTAssertTrue(error is RunLoopTimeoutError)
        }

        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(120))
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(cacheMutation.value, 0)
        thread.runInLoopAsync { _ in
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }
}
