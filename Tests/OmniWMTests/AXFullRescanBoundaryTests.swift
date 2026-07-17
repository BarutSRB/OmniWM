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

private final class AXBoundaryConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var maximum = 0

    func enter() {
        lock.lock()
        active += 1
        maximum = max(maximum, active)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        active -= 1
        lock.unlock()
    }
}

private final class AXRebindCacheBox: @unchecked Sendable {
    var windows: ThreadGuardedValue<[Int: AXUIElement]>?
    var subscriptions: ThreadGuardedValue<[Int: AXUIElement]>?
}

private actor AXBoundaryAsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func releaseAll() {
        isOpen = true
        let pending = continuations
        continuations.removeAll(keepingCapacity: false)
        for continuation in pending {
            continuation.resume()
        }
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

    func testCandidateCapturedFramePrefersWindowServerEvidence() {
        let pid: pid_t = 72_019
        let axFrame = CGRect(x: 10, y: 20, width: 800, height: 600)
        let windowServerFrame = CGRect(x: 30, y: 40, width: 900, height: 700)
        let candidate = FullRescanWindowCandidate(
            enumeratedWindow: AXEnumeratedWindow(
                axRef: AXWindowRef(
                    element: AXUIElementCreateApplication(pid),
                    windowId: 72_020
                ),
                axPid: pid,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                admissionGeometry: WindowAdmissionGeometryEvidence(
                    isSizeSettable: true,
                    frame: axFrame
                )
            ),
            logicalPID: pid,
            windowServerInfo: WindowServerInfo(
                id: 72_020,
                pid: pid,
                level: 0,
                frame: windowServerFrame
            ),
            windowServerOwnerPID: pid,
            enumerationRoute: .persistent
        )

        XCTAssertEqual(candidate.capturedFrame, windowServerFrame)
    }

    func testCapturedDecisionEvidenceEvaluatesWithoutAXReference() {
        let controller = WindowAdmissionTestSupport.controller()
        let token = WindowToken(pid: 72_021, windowId: 72_022)
        let constraints = WindowSizeConstraints(
            minSize: CGSize(width: 320, height: 240),
            maxSize: .zero,
            isFixed: false
        )
        let evidence = AXWindowDecisionEvidence(
            facts: AXWindowFacts(
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: nil,
                hasCloseButton: true,
                hasFullscreenButton: true,
                fullscreenButtonEnabled: true,
                hasZoomButton: true,
                hasMinimizeButton: true,
                appPolicy: .regular,
                bundleId: "example.full-rescan",
                attributeFetchSucceeded: true
            ),
            sizeConstraints: constraints
        )
        let windowInfo = WindowServerInfo(
            id: UInt32(token.windowId),
            pid: token.pid,
            level: 0,
            frame: CGRect(x: 20, y: 30, width: 800, height: 600)
        )
        let evaluation = controller.evaluateWindowDisposition(
            token: token,
            evidence: evidence,
            appFullscreen: false,
            windowInfo: windowInfo,
            admissionGeometry: WindowAdmissionGeometryEvidence(
                isSizeSettable: true,
                frame: windowInfo.frame
            )
        )

        XCTAssertEqual(evaluation.decision.disposition, .managed)
        XCTAssertEqual(evaluation.facts.sizeConstraints, constraints)
        XCTAssertEqual(evaluation.facts.windowServer, windowInfo)
        XCTAssertNil(controller.workspaceManager.cachedConstraints(for: token))
    }

    func testCapturedConstraintParserUsesObservedSizeForFixedWindow() {
        let size = CGSize(width: 420, height: 280)

        let constraints = AXWindowService.resolvedSizeConstraints(
            AXWindowConstraintInputs(
                hasGrowArea: false,
                hasZoomButton: false,
                subrole: kAXDialogSubrole as String,
                minSize: nil,
                maxSize: nil,
                currentSize: size
            )
        )

        XCTAssertEqual(constraints, .fixed(size: size))
    }

    func testCapturedConstraintParserPreservesExplicitBounds() {
        let minSize = CGSize(width: 320, height: 240)
        let maxSize = CGSize(width: 1_600, height: 1_200)

        let constraints = AXWindowService.resolvedSizeConstraints(
            AXWindowConstraintInputs(
                hasGrowArea: true,
                hasZoomButton: false,
                subrole: kAXStandardWindowSubrole as String,
                minSize: minSize,
                maxSize: maxSize,
                currentSize: CGSize(width: 800, height: 600)
            )
        )

        XCTAssertEqual(constraints.minSize, minSize)
        XCTAssertEqual(constraints.maxSize, maxSize)
        XCTAssertFalse(constraints.isFixed)
    }

    func testFullRescanInspectionRequestsTitlesOnlyForMatchingAppRules() {
        let matching = AXManager.fullRescanInspectionContext(
            activationPolicy: .regular,
            bundleId: "example.titled",
            appName: "Titled App",
            requiresTitleForApp: { $0 == "example.titled" && $1 == "Titled App" }
        )
        let nonmatching = AXManager.fullRescanInspectionContext(
            activationPolicy: .accessory,
            bundleId: "example.titled",
            appName: "Other App",
            requiresTitleForApp: { $0 == "example.titled" && $1 == "Titled App" }
        )

        XCTAssertTrue(matching.includeTitle)
        XCTAssertFalse(nonmatching.includeTitle)
        XCTAssertEqual(matching.bundleId, "example.titled")
        XCTAssertEqual(nonmatching.appPolicy, .accessory)
    }

    func testModeTransitionUsesCapturedFrameWithoutLiveAXRead() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 72_023
        let windowId = 72_024
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        let capturedFrame = CGRect(x: 200, y: 200, width: 600, height: 400)

        XCTAssertTrue(
            controller.transitionWindowMode(
                for: token,
                to: .floating,
                applyFloatingFrame: false,
                observedFrame: capturedFrame
            )
        )

        XCTAssertEqual(
            controller.workspaceManager.floatingState(for: token)?.lastFrame,
            capturedFrame.offsetBy(dx: 50, dy: 50)
        )
    }

    func testFloatingSeedUsesCapturedFrameWithoutLiveAXRead() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let pid: pid_t = 72_025
        let windowId = 72_026
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId,
            mode: .floating
        )
        let capturedFrame = CGRect(x: 240, y: 180, width: 700, height: 500)

        controller.seedFloatingGeometryIfNeeded(for: token, observedFrame: capturedFrame)

        XCTAssertEqual(controller.workspaceManager.floatingState(for: token)?.lastFrame, capturedFrame)
    }

    func testFullRescanFloatingUpdatesSkipLiveFrameFallbackWhenCapturedFrameIsMissing() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let transitionPID: pid_t = 72_031
        let transitionWindowId = 72_032
        let transitionToken = controller.workspaceManager.addWindow(
            AXWindowRef(
                element: AXUIElementCreateApplication(transitionPID),
                windowId: transitionWindowId
            ),
            pid: transitionPID,
            windowId: transitionWindowId,
            to: workspaceId
        )

        XCTAssertTrue(
            controller.transitionWindowMode(
                for: transitionToken,
                to: .floating,
                applyFloatingFrame: false,
                observedFrame: nil,
                allowLiveFrameFallback: false
            )
        )
        XCTAssertNil(controller.workspaceManager.floatingState(for: transitionToken))

        let seedPID: pid_t = 72_033
        let seedWindowId = 72_034
        let seedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(seedPID), windowId: seedWindowId),
            pid: seedPID,
            windowId: seedWindowId,
            to: workspaceId,
            mode: .floating
        )

        controller.seedFloatingGeometryIfNeeded(
            for: seedToken,
            observedFrame: nil,
            allowLiveFrameFallback: false
        )

        XCTAssertNil(controller.workspaceManager.floatingState(for: seedToken))
    }

    func testFullRescanPreservesHiddenScratchpadsFromCapturedWindowServerOrPinnedEvidence() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let capturedPID: pid_t = 72_035
        let capturedWindowId = 72_036
        let capturedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(capturedPID), windowId: capturedWindowId),
            pid: capturedPID,
            windowId: capturedWindowId,
            to: workspaceId,
            mode: .floating
        )
        let pinnedPID: pid_t = 72_037
        let pinnedWindowId = 72_038
        let pinnedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pinnedPID), windowId: pinnedWindowId),
            pid: pinnedPID,
            windowId: pinnedWindowId,
            to: workspaceId,
            mode: .floating
        )
        for token in [capturedToken, pinnedToken] {
            controller.workspaceManager.setHiddenState(
                HiddenState(
                    proportionalPosition: .zero,
                    referenceMonitorId: nil,
                    reason: .scratchpad
                ),
                for: token
            )
        }
        var pinnedQueries: [UInt32] = []
        var seenKeys: Set<WindowToken> = []

        controller.layoutRefreshController.preserveScratchpadHiddenWindowsDuringFullRescan(
            controller.workspaceManager.allEntries(),
            windowServerInfoByWindowId: [
                capturedWindowId: WindowServerInfo(
                    id: UInt32(capturedWindowId),
                    pid: capturedPID,
                    level: 0,
                    frame: CGRect(x: -20_000, y: -20_000, width: 640, height: 480)
                )
            ],
            seenKeys: &seenKeys,
            hasPinnedAXElement: { windowId in
                pinnedQueries.append(windowId)
                return windowId == UInt32(pinnedWindowId)
            }
        )

        XCTAssertEqual(seenKeys, [capturedToken, pinnedToken])
        XCTAssertEqual(pinnedQueries, [UInt32(pinnedWindowId)])
        XCTAssertTrue(controller.workspaceManager.hiddenState(for: capturedToken)?.isScratchpad == true)
        XCTAssertTrue(controller.workspaceManager.hiddenState(for: pinnedToken)?.isScratchpad == true)
    }

    func testBoundedAsyncMapCapsConcurrencyAndPreservesInputOrder() async throws {
        let probe = AXBoundaryConcurrencyProbe()
        let inputs = Array(0 ..< 12)

        let output = try await boundedFullRescanMap(inputs, maxConcurrent: 4) { input in
            probe.enter()
            defer { probe.leave() }
            try await Task.sleep(for: .milliseconds(20))
            return input
        }

        XCTAssertEqual(output, inputs)
        XCTAssertEqual(probe.maximum, 4)
    }

    func testBoundedAsyncMapStopsEnqueueingAfterCancellation() async {
        let started = DispatchSemaphore(value: 0)
        let gate = AXBoundaryAsyncGate()
        let startedCount = AXBoundaryCounter()
        let task = Task.detached {
            try await boundedFullRescanMap(Array(0 ..< 12), maxConcurrent: 4) { input in
                startedCount.increment()
                started.signal()
                await gate.wait()
                try Task.checkCancellation()
                return input
            }
        }

        for _ in 0 ..< 4 {
            XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        }
        task.cancel()
        await gate.releaseAll()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(startedCount.value, 4)
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

    func testOneShotPromotionBatchesAreDeterministicAndSerializedBySortedPID() async {
        let firstPID: pid_t = 72_039
        let secondPID: pid_t = 72_040
        let thirdPID: pid_t = 72_041
        let candidates = [
            candidate(pid: thirdPID, windowId: 72_042, route: .oneShot, isManageable: true),
            candidate(pid: firstPID, windowId: 72_043, route: .oneShot, isManageable: true),
            candidate(pid: secondPID, windowId: 72_044, route: .persistent, isManageable: true),
            candidate(pid: firstPID, windowId: 72_045, route: .oneShot, isManageable: true),
            candidate(pid: secondPID, windowId: 72_046, route: .oneShot, isManageable: true)
        ]
        var active = 0
        var maximumActive = 0
        var observedPIDs: [pid_t] = []
        var observedWindowIds: [[Int]] = []

        await AXManager.forEachOneShotPromotionBatch(candidates) { pid, batch in
            active += 1
            maximumActive = max(maximumActive, active)
            observedPIDs.append(pid)
            observedWindowIds.append(batch.map(\.windowId))
            await Task.yield()
            active -= 1
        }

        XCTAssertEqual(observedPIDs, [firstPID, secondPID, thirdPID])
        XCTAssertEqual(observedWindowIds, [[72_043, 72_045], [72_046], [72_042]])
        XCTAssertEqual(maximumActive, 1)
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

    func testGenerationMoveInvalidatesExistingDestinationResult() {
        let generations = LockedWindowGenerationMap()
        let oldWindowId = 72_027
        let newWindowId = 72_028
        _ = generations.nextGeneration(for: oldWindowId)
        _ = generations.nextGeneration(for: newWindowId)
        let destinationGeneration = generations.nextGeneration(for: newWindowId)

        generations.invalidateAndMoveValue(from: oldWindowId, to: newWindowId)

        XCTAssertFalse(generations.isCurrent(destinationGeneration, for: newWindowId))
    }

    func testSuppressionMoveRetainsNewWindowAndClearsOldWindow() {
        let suppression = LockedWindowIdSet()
        let oldWindowId = 72_029
        let newWindowId = 72_030
        suppression.insert(oldWindowId)

        suppression.moveIfPresent(from: oldWindowId, to: newWindowId)

        XCTAssertFalse(suppression.contains(oldWindowId))
        XCTAssertTrue(suppression.contains(newWindowId))
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
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            let port = NSMachPort()
            RunLoop.current.add(port, forMode: .default)
            ready.signal()
            CFRunLoopRun()
        }
        thread.start()
        XCTAssertEqual(ready.wait(timeout: .now() + 1), .success)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let cacheMutation = AXBoundaryCounter()

        do {
            _ = try await thread.runInLoop(timeout: .milliseconds(250)) { job in
                defer { finished.signal() }
                started.signal()
                release.wait()
                try job.checkCancellation()
                cacheMutation.increment()
                return true
            }
            XCTFail("Expected timeout")
        } catch {
            XCTAssertTrue(error is RunLoopTimeoutError)
        }

        XCTAssertEqual(started.wait(timeout: .now()), .success)
        XCTAssertEqual(finished.wait(timeout: .now()), .timedOut)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(cacheMutation.value, 0)
        thread.runInLoopAsync { _ in
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    func testTimedOutRebindCommitCannotMutateCachesAfterBodyRelease() async {
        let ready = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let unchanged = AXBoundaryCounter()
        let cacheBox = AXRebindCacheBox()
        let pid: pid_t = 469_100
        let oldWindowId = 469_101
        let newWindowId = 469_102
        let oldWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: oldWindowId
        )
        let newWindow = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: newWindowId
        )
        let thread = Thread {
            $appThreadToken.withValue(AppThreadToken(pid: pid)) {
                cacheBox.windows = ThreadGuardedValue([oldWindowId: oldWindow.element])
                cacheBox.subscriptions = ThreadGuardedValue([oldWindowId: oldWindow.element])
                let port = NSMachPort()
                RunLoop.current.add(port, forMode: .default)
                ready.signal()
                CFRunLoopRun()
            }
        }
        thread.start()
        XCTAssertEqual(ready.wait(timeout: .now() + 1), .success)

        do {
            _ = try await thread.runInLoop(timeout: .milliseconds(250)) { job in
                guard let windows = cacheBox.windows,
                      let subscriptions = cacheBox.subscriptions
                else {
                    throw CancellationError()
                }
                defer {
                    if windows[newWindowId] == nil,
                       subscriptions[newWindowId] == nil,
                       windows[oldWindowId].map({ CFEqual($0, oldWindow.element) }) == true,
                       subscriptions[oldWindowId].map({ CFEqual($0, oldWindow.element) }) == true
                    {
                        unchanged.increment()
                    }
                    finished.signal()
                }
                started.signal()
                release.wait()
                _ = try AppAXContext.commitWindowRebindCache(
                    oldWindow: oldWindow,
                    newWindow: newWindow,
                    retireOldWindowState: true,
                    hasObserver: true,
                    windows: windows,
                    subscribedWindows: subscriptions,
                    job: job
                )
                return true
            }
            XCTFail("Expected timeout")
        } catch {
            XCTAssertTrue(error is RunLoopTimeoutError)
        }

        XCTAssertEqual(started.wait(timeout: .now()), .success)
        XCTAssertEqual(finished.wait(timeout: .now()), .timedOut)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(unchanged.value, 1)
        thread.runInLoopAsync { _ in
            cacheBox.windows?.destroy()
            cacheBox.subscriptions?.destroy()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    func testRebindCommitWaitsForSubscriptionCleanup() async throws {
        let ready = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let thread = Thread {
            let port = NSMachPort()
            RunLoop.current.add(port, forMode: .default)
            ready.signal()
            CFRunLoopRun()
        }
        thread.start()
        XCTAssertEqual(ready.wait(timeout: .now() + 1), .success)
        nonisolated(unsafe) let appThread = thread

        let completion = Task {
            try await AppAXContext.awaitWindowRebindCleanup(
                thread: appThread,
                timeout: .seconds(2)
            ) { job in
                started.signal()
                release.wait()
                try job.checkCancellation()
            }
            completed.signal()
        }

        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(completed.wait(timeout: .now()), .timedOut)
        release.signal()
        try await completion.value
        XCTAssertEqual(completed.wait(timeout: .now()), .success)
        appThread.runInLoopAsync { _ in
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }
}
