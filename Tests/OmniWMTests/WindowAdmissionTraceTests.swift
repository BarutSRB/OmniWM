// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

final class WindowAdmissionTraceTests: XCTestCase {
    func testInactiveRecorderDoesNotEvaluatePayload() {
        let recorder = WindowAdmissionTrace(capacity: 4)
        var evaluations = 0
        let makeEvent = {
            evaluations += 1
            return WindowAdmissionTraceEvent(action: .cgsCreated, windowId: 41)
        }

        recorder.record(makeEvent())

        XCTAssertEqual(evaluations, 0)
        XCTAssertEqual(recorder.dump(), "none")

        recorder.beginCapture()
        recorder.record(makeEvent())

        XCTAssertEqual(evaluations, 1)
        XCTAssertEqual(recorder.recordsSnapshot().map(\.action), [.cgsCreated])
    }

    func testCapacityEvictsOldestRecords() {
        let recorder = WindowAdmissionTrace(capacity: 3)
        recorder.beginCapture()

        for windowId in 1 ... 4 {
            recorder.record(.init(action: .cgsCreated, windowId: windowId))
        }

        XCTAssertEqual(recorder.recordsSnapshot().map(\.windowId), [2, 3, 4])
    }

    func testProcessWindowAndEndpointGenerationsAdvanceOnReuse() throws {
        let recorder = WindowAdmissionTrace(capacity: 32)
        let pid: pid_t = 8_101
        let windowId = 8_102
        let firstRef = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: windowId
        )
        let replacementRef = AXWindowRef(
            element: AXUIElementCreateApplication(pid + 1),
            windowId: windowId
        )
        recorder.beginCapture()

        recorder.record(.init(action: .processLaunched, pid: pid))
        recorder.record(.init(action: .endpointCreated, pid: pid, callbackGeneration: 3))
        recorder.record(.init(action: .cgsCreated, windowId: windowId))
        recorder.record(
            .init(action: .topLevelAccepted, pid: pid, windowId: windowId, axRef: firstRef)
        )
        recorder.record(
            .init(action: .topLevelAccepted, pid: pid, windowId: windowId, axRef: replacementRef)
        )
        recorder.record(.init(action: .cgsDestroyed, windowId: windowId))
        recorder.record(.init(action: .cgsCreated, windowId: windowId))
        recorder.record(
            .init(action: .topLevelAccepted, pid: pid, windowId: windowId, axRef: replacementRef)
        )
        recorder.record(.init(action: .endpointDestroyed, pid: pid))
        recorder.record(.init(action: .endpointCreated, pid: pid, callbackGeneration: 4))
        recorder.record(.init(action: .processTerminated, pid: pid))
        recorder.record(.init(action: .processLaunched, pid: pid))

        let records = recorder.recordsSnapshot()
        XCTAssertEqual(records[0].processGeneration, 1)
        XCTAssertEqual(records[1].endpointGeneration, 1)
        XCTAssertEqual(records[3].windowGeneration, 1)
        XCTAssertEqual(records[4].windowGeneration, 1)
        XCTAssertEqual(records[6].windowGeneration, 2)
        XCTAssertEqual(records[9].endpointGeneration, 2)
        XCTAssertEqual(records[11].processGeneration, 2)
        XCTAssertEqual(records[9].callbackGeneration, 4)
    }

    func testFinalizationTargetPrioritizesAnomalyAndHonorsExclusion() throws {
        let recorder = WindowAdmissionTrace(capacity: 16)
        let pendingRef = AXWindowRef(
            element: AXUIElementCreateApplication(8_202),
            windowId: 8_212
        )
        let refusalRef = AXWindowRef(
            element: AXUIElementCreateApplication(8_203),
            windowId: 8_213
        )
        recorder.beginCapture()
        recorder.record(
            .init(action: .frontmostObserved, pid: 8_201, bundleId: "example.frontmost")
        )
        recorder.record(
            .init(
                action: .admissionPending,
                pid: 8_202,
                windowId: 8_212,
                reason: "facts_deferred",
                axRef: pendingRef
            )
        )
        recorder.record(
            .init(
                action: .terminalFrameRefusal,
                pid: 8_203,
                windowId: 8_213,
                reason: "sizeWriteFailed",
                axRef: refusalRef
            )
        )
        recorder.endCapture()

        let terminal = try XCTUnwrap(recorder.finalizationTarget(excludingPID: 99))
        XCTAssertEqual(terminal.pid, 8_203)
        XCTAssertEqual(terminal.windowId, 8_213)
        XCTAssertEqual(terminal.reason, "sizeWriteFailed")
        XCTAssertTrue(CFEqual(try XCTUnwrap(terminal.axRef).element, refusalRef.element))

        let pending = try XCTUnwrap(recorder.finalizationTarget(excludingPID: 8_203))
        XCTAssertEqual(pending.pid, 8_202)
        XCTAssertEqual(pending.windowId, 8_212)
        XCTAssertTrue(CFEqual(try XCTUnwrap(pending.axRef).element, pendingRef.element))
    }

    func testResolvedEnumerationFailureFallsBackToLastManagedFocus() throws {
        let recorder = WindowAdmissionTrace(capacity: 16)
        let focusedRef = AXWindowRef(
            element: AXUIElementCreateApplication(8_221),
            windowId: 8_231
        )
        recorder.beginCapture()
        recorder.record(
            .init(
                action: .managedFocusObserved,
                pid: 8_221,
                windowId: 8_231,
                axRef: focusedRef
            )
        )
        recorder.record(
            .init(action: .enumerationFailed, pid: 8_222, reason: "timeout")
        )
        XCTAssertEqual(recorder.finalizationTarget(excludingPID: 99)?.pid, 8_222)

        recorder.record(
            .init(action: .enumerationCompleted, pid: 8_222, count: 1)
        )
        recorder.record(
            .init(action: .admissionTracked, pid: 8_223, windowId: 8_233)
        )

        let target = try XCTUnwrap(recorder.finalizationTarget(excludingPID: 99))
        XCTAssertEqual(target.pid, 8_221)
        XCTAssertEqual(target.windowId, 8_231)
        XCTAssertTrue(CFEqual(try XCTUnwrap(target.axRef).element, focusedRef.element))
    }

    func testProcessTerminationClearsEveryFinalizationTargetForPID() {
        let recorder = WindowAdmissionTrace(capacity: 16)
        let pid: pid_t = 8_241
        recorder.beginCapture()
        recorder.record(.init(action: .processLaunched, pid: pid))
        recorder.record(.init(action: .frontmostObserved, pid: pid))
        recorder.record(.init(action: .managedFocusObserved, pid: pid))
        recorder.record(.init(action: .admissionPending, pid: pid, windowId: 8_242))
        recorder.record(.init(action: .terminalFrameRefusal, pid: pid, windowId: 8_242))

        XCTAssertEqual(recorder.finalizationTarget(excludingPID: 99)?.pid, pid)

        recorder.record(.init(action: .processTerminated, pid: pid))

        XCTAssertNil(recorder.finalizationTarget(excludingPID: 99))
    }

    func testLateDisappearanceCannotReactivateTerminatedProcess() throws {
        let recorder = WindowAdmissionTrace(capacity: 16)
        let pid: pid_t = 8_251
        recorder.beginCapture()
        recorder.record(.init(action: .processLaunched, pid: pid))
        recorder.record(.init(action: .admissionPending, pid: pid, windowId: 8_252))
        recorder.record(.init(action: .processTerminated, pid: pid))
        recorder.record(
            .init(
                action: .admissionDisappeared,
                pid: pid,
                windowId: 8_252,
                reason: "process_terminated"
            )
        )

        XCTAssertNil(recorder.finalizationTarget(excludingPID: 99))
        XCTAssertEqual(recorder.recordsSnapshot().last?.processGeneration, 1)

        recorder.record(.init(action: .processLaunched, pid: pid))
        XCTAssertNil(recorder.finalizationTarget(excludingPID: 99))
        recorder.record(.init(action: .admissionPending, pid: pid, windowId: 8_253))

        let relaunched = try XCTUnwrap(recorder.finalizationTarget(excludingPID: 99))
        XCTAssertEqual(relaunched.windowId, 8_253)
        XCTAssertEqual(relaunched.processGeneration, 2)

        recorder.record(
            .init(
                action: .admissionDisappeared,
                pid: pid,
                windowId: 8_252,
                reason: "process_terminated"
            )
        )

        XCTAssertEqual(recorder.recordsSnapshot().last?.windowId, 8_252)
        XCTAssertEqual(recorder.finalizationTarget(excludingPID: 99)?.windowId, 8_253)
    }

    func testAuxiliaryPruningPreservesTerminatedProcessTombstone() {
        let recorder = WindowAdmissionTrace(capacity: 1)
        let pid: pid_t = 8_261
        recorder.beginCapture()
        recorder.record(.init(action: .processLaunched, pid: pid))
        recorder.record(.init(action: .processTerminated, pid: pid))

        for windowId in 8_300 ..< 8_600 {
            recorder.record(.init(action: .cgsCreated, windowId: windowId))
        }
        recorder.record(.init(action: .admissionPending, pid: pid, windowId: 8_262))

        XCTAssertNil(recorder.finalizationTarget(excludingPID: 99))
    }

    @MainActor
    func testFullRescanPreferenceReportsDecisiveReason() {
        let windowId = 8_301
        let preservedPID: pid_t = 8_302
        let ownerPID: pid_t = 8_303
        let preserved = fullRescanCandidate(pid: preservedPID, windowId: windowId)
        let owner = fullRescanCandidate(pid: ownerPID, windowId: windowId)

        let preference = AXManager.fullRescanCandidatePreference(
            preserved,
            over: owner,
            activationPolicyByPID: [preservedPID: .regular, ownerPID: .regular],
            ownerPID: ownerPID,
            existingPID: preservedPID
        )

        XCTAssertTrue(preference.prefersCandidate)
        XCTAssertEqual(preference.reason, .preservedLogicalPID)
    }

    func testDumpIsStructuredJSONLines() throws {
        let recorder = WindowAdmissionTrace(capacity: 4)
        recorder.beginCapture()
        recorder.record(
            .init(
                action: .admissionPending,
                pid: 8_401,
                windowId: 8_402,
                reason: "window_info_missing",
                attempt: 1,
                retryGeneration: 7
            )
        )

        let line = try XCTUnwrap(recorder.dump().split(separator: "\n").first)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )

        XCTAssertEqual(object["action"] as? String, "admission_pending")
        XCTAssertEqual(object["windowId"] as? Int, 8_402)
        XCTAssertEqual(object["retryGeneration"] as? Int, 7)
    }

    func testRepeatedClassificationObservationsAreRetained() {
        let recorder = WindowAdmissionTrace(capacity: 4)
        let observation = WindowClassificationObservation(
            tokenPid: 8_501,
            tokenWindowId: 8_502,
            appName: "Example",
            bundleId: "example.app",
            workspaceName: nil,
            input: WindowClassificationInput(
                appName: "Example",
                ax: AXWindowFactsDTO(
                    from: AXWindowFacts(
                        role: kAXWindowRole as String,
                        subrole: kAXStandardWindowSubrole as String,
                        title: "Window",
                        hasCloseButton: true,
                        hasFullscreenButton: true,
                        fullscreenButtonEnabled: true,
                        hasZoomButton: true,
                        hasMinimizeButton: true,
                        appPolicy: .regular,
                        bundleId: "example.app",
                        attributeFetchSucceeded: true
                    )
                ),
                sizeConstraints: nil,
                windowServer: nil,
                appFullscreen: false,
                manualOverride: nil,
                rules: []
            ),
            observedDecision: WindowClassificationDecisionDTO(
                from: WindowDecision(
                    disposition: .managed,
                    source: .heuristic,
                    layoutDecisionKind: .fallbackLayout,
                    workspaceName: nil,
                    ruleEffects: .none,
                    admissionHints: .none,
                    heuristicReasons: [],
                    deferredReason: nil
                )
            )
        )
        recorder.beginCapture()

        recorder.record(
            .init(
                action: .classificationObserved,
                pid: observation.tokenPid,
                windowId: observation.tokenWindowId,
                observation: observation
            )
        )
        recorder.record(
            .init(
                action: .classificationObserved,
                pid: observation.tokenPid,
                windowId: observation.tokenWindowId,
                observation: observation
            )
        )

        XCTAssertEqual(recorder.recordsSnapshot().count, 2)
        XCTAssertEqual(recorder.recordsSnapshot().first?.observation, observation)
    }

    private func fullRescanCandidate(pid: pid_t, windowId: Int) -> FullRescanWindowCandidate {
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
                    isSizeSettable: true,
                    frame: CGRect(x: 0, y: 0, width: 800, height: 600)
                )
            ),
            logicalPID: pid,
            windowServerInfo: nil,
            windowServerOwnerPID: nil,
            enumerationRoute: .persistent
        )
    }
}
