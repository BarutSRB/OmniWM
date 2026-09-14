// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class AXFullRescanResponsivenessTests: XCTestCase {
    func testBothRoutesSkipOnlyPositiveResultsAndRecheckRecovery() async throws {
        let app = NSRunningApplication.current
        let pid = app.processIdentifier
        WindowAdmissionTrace.shared.beginCapture()
        defer { WindowAdmissionTrace.shared.endCapture() }

        for route in [FullRescanEnumerationRoute.persistent, .oneShot] {
            for decision in [true, false, nil, true, false] as [Bool?] {
                let queries = Mutex(0)
                let start = WindowAdmissionTrace.shared.recordsSnapshot().count
                let result = try await AXManager.enumerateFullRescanApp(
                    app,
                    route: route,
                    inspectionContext: .unidentified,
                    includedWindowIds: [],
                    isAppUnresponsive: { queriedPID in
                        XCTAssertFalse(Thread.isMainThread)
                        XCTAssertEqual(queriedPID, pid)
                        queries.withLock { $0 += 1 }
                        return decision
                    }
                )
                XCTAssertEqual(queries.withLock { $0 }, 1)
                XCTAssertEqual(result.pid, pid)
                XCTAssertEqual(result.route, route)
                let records = Array(WindowAdmissionTrace.shared.recordsSnapshot().dropFirst(start))
                if decision == true {
                    XCTAssertTrue(result.failed)
                    XCTAssertTrue(result.windows.isEmpty)
                    XCTAssertNil(result.callbackGeneration)
                    XCTAssertEqual(records.map(\.reason), ["app_unresponsive"])
                    XCTAssertEqual(records.map(\.action), [.enumerationFailed])
                } else {
                    XCTAssertFalse(records.contains { $0.reason == "app_unresponsive" })
                    if route == .persistent, result.callbackGeneration == nil {
                        XCTAssertEqual(records.last?.reason, "context_unavailable")
                    } else {
                        XCTAssertTrue(records.contains { $0.action == .enumerationStarted })
                    }
                }
            }
        }
    }

    func testCancellationIsCheckedBeforeAndAfterQuery() async {
        let app = NSRunningApplication.current
        for cancelBeforeQuery in [true, false] {
            let queries = Mutex(0)
            let task = Task {
                if cancelBeforeQuery {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                do {
                    _ = try await AXManager.enumerateFullRescanApp(
                        app,
                        route: .oneShot,
                        inspectionContext: .unidentified,
                        includedWindowIds: [],
                        isAppUnresponsive: { _ in
                            queries.withLock { $0 += 1 }
                            withUnsafeCurrentTask { $0?.cancel() }
                            return true
                        }
                    )
                    XCTFail("Cancellation must propagate")
                } catch is CancellationError {
                } catch {
                    XCTFail("Unexpected error: \(error)")
                }
            }
            await task.value
            XCTAssertEqual(queries.withLock { $0 }, cancelBeforeQuery ? 0 : 1)
        }
    }

    func testGuardedFailurePreservesManagedWindowsAndCannotAuthorizeRetirement() async throws {
        let app = NSRunningApplication.current
        let pid = app.processIdentifier
        let manager = AXManager()
        defer { manager.cleanup() }
        for route in [FullRescanEnumerationRoute.persistent, .oneShot] {
            let result = try await AXManager.enumerateFullRescanApp(
                app,
                route: route,
                inspectionContext: .unidentified,
                includedWindowIds: nil,
                isAppUnresponsive: { _ in true }
            )
            let snapshot = try await manager.finalizeFullRescanSnapshot(
                .init(
                    appTargets: [.init(
                        app: app,
                        route: route,
                        inspectionContext: .unidentified,
                        includedWindowIds: nil
                    )],
                    results: [result],
                    coverage: .init(
                        targetPIDs: [pid], dependencyPIDs: [], targetPIDsByDependencyPID: [:],
                        unavailableTargetPIDs: [], unavailableDependencyPIDs: [], exactWindowIds: nil
                    ),
                    discoveryEvidence: .init(
                        pidsWithWindows: [],
                        windowServerInfoByWindowId: [:],
                        ownerPIDByWindowId: [:]
                    )
                ),
                preservingPIDsByWindowId: [:]
            )
            XCTAssertTrue(snapshot.windows.isEmpty)
            XCTAssertEqual(snapshot.failedPIDs, [pid])
            XCTAssertTrue(snapshot.successfullyEnumeratedPIDs.isEmpty)
            XCTAssertTrue(snapshot.authoritativeTargetPIDs.isEmpty)
            try assertManagedWindowSurvives(snapshot, pid: pid)
        }
    }

    private func assertManagedWindowSurvives(_ snapshot: AXManager.FullRescanEnumerationSnapshot, pid: pid_t) throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer { controller.layoutRefreshController.resetState() }
        let workspaceID = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let token = WindowToken(pid: pid, windowId: 73_701)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceID, controller: controller)
        var progress = FullRescanProgress(affectedWorkspaceIds: [])
        controller.layoutRefreshController.retireFullRescanWindows(
            context: .init(
                controller: controller, enumerationSnapshot: snapshot, scope: .all,
                focusedWorkspaceId: workspaceID, screenFrames: []
            ),
            hadNativeFullscreenLifecycleContextAtStart: false,
            permitsMissingRetirement: true,
            progress: &progress
        )
        XCTAssertTrue(progress.seenKeys.contains(token))
        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
    }
}
