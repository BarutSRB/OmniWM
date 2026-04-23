// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing

@testable import OmniWM

private func makeOrchestrationRefresh(
    cycleId: RefreshCycleId,
    kind: ScheduledRefreshKind,
    reason: RefreshReason,
    affectedWorkspaceIds: Set<WorkspaceDescriptor.ID> = [],
    postLayoutAttachmentIds: [RefreshAttachmentId] = [],
    windowRemovalPayload: WindowRemovalPayload? = nil
) -> ScheduledRefresh {
    ScheduledRefresh(
        cycleId: cycleId,
        kind: kind,
        reason: reason,
        affectedWorkspaceIds: affectedWorkspaceIds,
        postLayoutAttachmentIds: postLayoutAttachmentIds,
        windowRemovalPayload: windowRemovalPayload
    )
}

private func makeOrchestrationSnapshot(
    activeRefresh: ScheduledRefresh? = nil,
    pendingRefresh: ScheduledRefresh? = nil,
    nextManagedRequestId: UInt64 = 1,
    activeManagedRequest: ManagedFocusRequest? = nil,
    pendingFocusedToken: WindowToken? = nil,
    pendingFocusedWorkspaceId: WorkspaceDescriptor.ID? = nil
) -> OrchestrationSnapshot {
    OrchestrationSnapshot(
        refresh: .init(
            activeRefresh: activeRefresh,
            pendingRefresh: pendingRefresh
        ),
        focus: .init(
            nextManagedRequestId: nextManagedRequestId,
            activeManagedRequest: activeManagedRequest,
            pendingFocusedToken: pendingFocusedToken,
            pendingFocusedWorkspaceId: pendingFocusedWorkspaceId,
            isNonManagedFocusActive: false,
            isAppFullscreenActive: false
        )
    )
}

@Test func fullRescanAbsorbsVisibilityRefreshIntoActiveCycle() {
    let workspaceId = WorkspaceDescriptor.ID()
    let activeRefresh = makeOrchestrationRefresh(
        cycleId: 10,
        kind: .fullRescan,
        reason: .startup
    )
    let incomingRefresh = makeOrchestrationRefresh(
        cycleId: 11,
        kind: .visibilityRefresh,
        reason: .appHidden,
        affectedWorkspaceIds: [workspaceId],
        postLayoutAttachmentIds: [99]
    )

    let result = OrchestrationCore.step(
        snapshot: makeOrchestrationSnapshot(activeRefresh: activeRefresh),
        event: .refreshRequested(
            .init(
                refresh: incomingRefresh,
                shouldDropWhileBusy: false,
                isIncrementalRefreshInProgress: false,
                isImmediateLayoutInProgress: false,
                hasActiveAnimationRefreshes: false
            )
        )
    )

    #expect(result.decision == .refreshMerged(cycleId: 10, kind: .fullRescan))
    #expect(result.snapshot.refresh.activeRefresh?.cycleId == 10)
    #expect(result.snapshot.refresh.activeRefresh?.postLayoutAttachmentIds == [99])
    #expect(result.snapshot.refresh.activeRefresh?.needsVisibilityReconciliation == true)
    #expect(result.plan.actions.isEmpty)
}

@Test func cancelledWindowRemovalPreservesRemovalPayloadBeforeRestart() {
    let workspaceId = WorkspaceDescriptor.ID()
    let cancelledRefresh = makeOrchestrationRefresh(
        cycleId: 21,
        kind: .windowRemoval,
        reason: .windowDestroyed,
        postLayoutAttachmentIds: [5],
        windowRemovalPayload: .init(
            workspaceId: workspaceId,
            layoutType: .niri,
            removedNodeId: nil,
            niriOldFrames: [:],
            shouldRecoverFocus: true
        )
    )
    let queuedRefresh = makeOrchestrationRefresh(
        cycleId: 22,
        kind: .relayout,
        reason: .workspaceTransition
    )

    let result = OrchestrationCore.step(
        snapshot: makeOrchestrationSnapshot(
            activeRefresh: cancelledRefresh,
            pendingRefresh: queuedRefresh
        ),
        event: .refreshCompleted(
            .init(
                refresh: cancelledRefresh,
                didComplete: false,
                didExecutePlan: false
            )
        )
    )

    guard let restartedRefresh = result.snapshot.refresh.activeRefresh else {
        Issue.record("expected a restarted refresh")
        return
    }

    #expect(result.decision == .refreshCompleted(cycleId: 21, didComplete: false))
    #expect(restartedRefresh.kind == .windowRemoval)
    #expect(restartedRefresh.windowRemovalPayloads.count == 1)
    #expect(restartedRefresh.postLayoutAttachmentIds == [5])
    #expect(result.plan.actions.contains(.startRefresh(restartedRefresh)))
}

@Test func focusRequestSupersedesExistingManagedRequest() {
    let firstWorkspace = WorkspaceDescriptor.ID()
    let secondWorkspace = WorkspaceDescriptor.ID()
    let oldToken = WindowToken(pid: 77, windowId: 1)
    let newToken = WindowToken(pid: 77, windowId: 2)
    let activeRequest = ManagedFocusRequest(
        requestId: 4,
        token: oldToken,
        workspaceId: firstWorkspace
    )

    let result = OrchestrationCore.step(
        snapshot: makeOrchestrationSnapshot(
            nextManagedRequestId: 9,
            activeManagedRequest: activeRequest,
            pendingFocusedToken: oldToken,
            pendingFocusedWorkspaceId: firstWorkspace
        ),
        event: .focusRequested(
            .init(
                token: newToken,
                workspaceId: secondWorkspace
            )
        )
    )

    #expect(
        result.decision == .focusRequestSuperseded(
            replacedRequestId: 4,
            requestId: 9,
            token: newToken
        )
    )
    #expect(result.snapshot.focus.activeManagedRequest?.requestId == 9)
    #expect(result.snapshot.focus.pendingFocusedToken == newToken)
    #expect(
        result.plan.actions == [
            .clearManagedFocusState(
                requestId: 4,
                token: oldToken,
                workspaceId: firstWorkspace
            ),
            .beginManagedFocusRequest(
                requestId: 9,
                token: newToken,
                workspaceId: secondWorkspace
            ),
            .frontManagedWindow(
                token: newToken,
                workspaceId: secondWorkspace
            )
        ]
    )
}

@Test func unmanagedActivationConflictDefersPendingFocusRequest() {
    let workspaceId = WorkspaceDescriptor.ID()
    let requestedToken = WindowToken(pid: 88, windowId: 3)
    let observedToken = WindowToken(pid: 88, windowId: 4)
    let activeRequest = ManagedFocusRequest(
        requestId: 7,
        token: requestedToken,
        workspaceId: workspaceId
    )

    let result = OrchestrationCore.step(
        snapshot: makeOrchestrationSnapshot(
            nextManagedRequestId: 8,
            activeManagedRequest: activeRequest,
            pendingFocusedToken: requestedToken,
            pendingFocusedWorkspaceId: workspaceId
        ),
        event: .activationObserved(
            .init(
                source: .workspaceDidActivateApplication,
                origin: .external,
                match: .unmanaged(
                    pid: observedToken.pid,
                    token: observedToken,
                    appFullscreen: false,
                    fallbackFullscreen: false
                )
            )
        )
    )

    #expect(
        result.decision == .managedActivationDeferred(
            requestId: 7,
            reason: .pendingFocusUnmanagedToken
        )
    )
    #expect(
        result.plan.actions == [
            .continueManagedFocusRequest(
                requestId: 7,
                reason: .pendingFocusUnmanagedToken,
                source: .workspaceDidActivateApplication,
                origin: .external
            )
        ]
    )
}

@Test func ownedApplicationActivationPreservesUnrelatedPendingRequest() {
    let workspaceId = WorkspaceDescriptor.ID()
    let requestedToken = WindowToken(pid: 88, windowId: 3)
    let ownedPID = pid_t(99)
    let activeRequest = ManagedFocusRequest(
        requestId: 7,
        token: requestedToken,
        workspaceId: workspaceId
    )

    let result = OrchestrationCore.step(
        snapshot: makeOrchestrationSnapshot(
            nextManagedRequestId: 8,
            activeManagedRequest: activeRequest,
            pendingFocusedToken: requestedToken,
            pendingFocusedWorkspaceId: workspaceId
        ),
        event: .activationObserved(
            .init(
                source: .cgsFrontAppChanged,
                origin: .external,
                match: .ownedApplication(pid: ownedPID)
            )
        )
    )

    #expect(result.decision == .managedActivationFallback(pid: ownedPID))
    #expect(result.snapshot.focus.activeManagedRequest == activeRequest)
    #expect(result.snapshot.focus.pendingFocusedToken == requestedToken)
    #expect(result.snapshot.focus.isNonManagedFocusActive == true)
    #expect(
        result.plan.actions == [
            .enterOwnedApplicationFallback(
                pid: ownedPID,
                source: .cgsFrontAppChanged
            )
        ]
    )
}

@Test func ownedApplicationActivationClearsSamePIDPendingRequest() {
    let workspaceId = WorkspaceDescriptor.ID()
    let ownedPID = pid_t(88)
    let requestedToken = WindowToken(pid: ownedPID, windowId: 3)
    let activeRequest = ManagedFocusRequest(
        requestId: 7,
        token: requestedToken,
        workspaceId: workspaceId
    )

    let result = OrchestrationCore.step(
        snapshot: makeOrchestrationSnapshot(
            nextManagedRequestId: 8,
            activeManagedRequest: activeRequest,
            pendingFocusedToken: requestedToken,
            pendingFocusedWorkspaceId: workspaceId
        ),
        event: .activationObserved(
            .init(
                source: .workspaceDidActivateApplication,
                origin: .external,
                match: .ownedApplication(pid: ownedPID)
            )
        )
    )

    #expect(result.decision == .managedActivationFallback(pid: ownedPID))
    #expect(result.snapshot.focus.activeManagedRequest == nil)
    #expect(result.snapshot.focus.pendingFocusedToken == nil)
    #expect(result.snapshot.focus.isNonManagedFocusActive == true)
    #expect(
        result.plan.actions == [
            .clearManagedFocusState(
                requestId: 7,
                token: requestedToken,
                workspaceId: workspaceId
            ),
            .enterOwnedApplicationFallback(
                pid: ownedPID,
                source: .workspaceDidActivateApplication
            )
        ]
    )
}

@Test func ownedApplicationActivationCancelsStrayRetryWithoutActiveRequest() {
    let workspaceId = WorkspaceDescriptor.ID()
    let pendingToken = WindowToken(pid: 88, windowId: 3)
    let ownedPID = pid_t(99)

    let result = OrchestrationCore.step(
        snapshot: makeOrchestrationSnapshot(
            nextManagedRequestId: 8,
            pendingFocusedToken: pendingToken,
            pendingFocusedWorkspaceId: workspaceId
        ),
        event: .activationObserved(
            .init(
                source: .focusedWindowChanged,
                origin: .external,
                match: .ownedApplication(pid: ownedPID)
            )
        )
    )

    #expect(result.decision == .managedActivationFallback(pid: ownedPID))
    #expect(result.snapshot.focus.activeManagedRequest == nil)
    #expect(result.snapshot.focus.pendingFocusedToken == nil)
    #expect(result.snapshot.focus.isNonManagedFocusActive == true)
    #expect(
        result.plan.actions == [
            .cancelActivationRetry(requestId: nil),
            .enterOwnedApplicationFallback(
                pid: ownedPID,
                source: .focusedWindowChanged
            )
        ]
    )
}

@Test func managedActivationUsesDedicatedNativeFullscreenRestoreAction() {
    let workspaceId = WorkspaceDescriptor.ID()
    let token = WindowToken(pid: 90, windowId: 5)
    let activeRequest = ManagedFocusRequest(
        requestId: 12,
        token: token,
        workspaceId: workspaceId
    )

    let result = OrchestrationCore.step(
        snapshot: makeOrchestrationSnapshot(
            nextManagedRequestId: 13,
            activeManagedRequest: activeRequest,
            pendingFocusedToken: token,
            pendingFocusedWorkspaceId: workspaceId
        ),
        event: .activationObserved(
            .init(
                source: .focusedWindowChanged,
                origin: .external,
                match: .managed(
                    token: token,
                    workspaceId: workspaceId,
                    monitorId: nil,
                    isWorkspaceActive: true,
                    appFullscreen: false,
                    requiresNativeFullscreenRestoreRelayout: true
                )
            )
        )
    )

    #expect(result.decision == .managedActivationConfirmed(token: token))
    #expect(result.snapshot.focus.activeManagedRequest == nil)
    #expect(result.snapshot.focus.pendingFocusedToken == token)
    #expect(result.snapshot.focus.pendingFocusedWorkspaceId == workspaceId)
    #expect(
        result.plan.actions == [
            .beginNativeFullscreenRestoreActivation(
                token: token,
                workspaceId: workspaceId,
                monitorId: nil,
                isWorkspaceActive: true,
                source: .focusedWindowChanged
            )
        ]
    )
}

@Test func repeatedPendingRelayoutMergesPreserveAffectedWorkspaceSet() {
    let workspaceId = WorkspaceDescriptor.ID()
    var snapshot = makeOrchestrationSnapshot(
        activeRefresh: makeOrchestrationRefresh(
            cycleId: 1,
            kind: .immediateRelayout,
            reason: .workspaceTransition
        )
    )

    for cycleId in 2...8 {
        let result = OrchestrationCore.step(
            snapshot: snapshot,
            event: .refreshRequested(
                .init(
                    refresh: makeOrchestrationRefresh(
                        cycleId: UInt64(cycleId),
                        kind: .relayout,
                        reason: .workspaceConfigChanged,
                        affectedWorkspaceIds: [workspaceId]
                    ),
                    shouldDropWhileBusy: false,
                    isIncrementalRefreshInProgress: false,
                    isImmediateLayoutInProgress: false,
                    hasActiveAnimationRefreshes: false
                )
            )
        )
        snapshot = result.snapshot
    }

    #expect(snapshot.refresh.pendingRefresh?.affectedWorkspaceIds == [workspaceId])
}

@Test func upgradedPendingRefreshRetainsPreviousAffectedWorkspaceSet() {
    let firstWorkspaceId = WorkspaceDescriptor.ID()
    let secondWorkspaceId = WorkspaceDescriptor.ID()
    let activeRefresh = makeOrchestrationRefresh(
        cycleId: 1,
        kind: .fullRescan,
        reason: .startup
    )
    let pendingRefresh = makeOrchestrationRefresh(
        cycleId: 2,
        kind: .relayout,
        reason: .workspaceConfigChanged,
        affectedWorkspaceIds: [firstWorkspaceId]
    )
    let incomingRefresh = makeOrchestrationRefresh(
        cycleId: 3,
        kind: .immediateRelayout,
        reason: .workspaceTransition,
        affectedWorkspaceIds: [secondWorkspaceId]
    )

    let result = OrchestrationCore.step(
        snapshot: makeOrchestrationSnapshot(
            activeRefresh: activeRefresh,
            pendingRefresh: pendingRefresh
        ),
        event: .refreshRequested(
            .init(
                refresh: incomingRefresh,
                shouldDropWhileBusy: false,
                isIncrementalRefreshInProgress: false,
                isImmediateLayoutInProgress: false,
                hasActiveAnimationRefreshes: false
            )
        )
    )

    #expect(result.decision == .refreshMerged(cycleId: 2, kind: .immediateRelayout))
    #expect(
        result.snapshot.refresh.pendingRefresh?.affectedWorkspaceIds == [
            firstWorkspaceId,
            secondWorkspaceId
        ]
    )
}

@Test func windowRemovalRelayoutMergeAllowsWorkspaceInRefreshAndFollowUp() {
    let workspaceId = WorkspaceDescriptor.ID()
    let activeRefresh = makeOrchestrationRefresh(
        cycleId: 1,
        kind: .fullRescan,
        reason: .startup
    )
    let pendingRefresh = makeOrchestrationRefresh(
        cycleId: 2,
        kind: .windowRemoval,
        reason: .windowDestroyed
    )
    let relayout = makeOrchestrationRefresh(
        cycleId: 3,
        kind: .relayout,
        reason: .workspaceTransition,
        affectedWorkspaceIds: [workspaceId]
    )

    let result = OrchestrationCore.step(
        snapshot: makeOrchestrationSnapshot(
            activeRefresh: activeRefresh,
            pendingRefresh: pendingRefresh
        ),
        event: .refreshRequested(
            .init(
                refresh: relayout,
                shouldDropWhileBusy: false,
                isIncrementalRefreshInProgress: false,
                isImmediateLayoutInProgress: false,
                hasActiveAnimationRefreshes: false
            )
        )
    )

    guard let merged = result.snapshot.refresh.pendingRefresh else {
        Issue.record("expected relayout to merge into the pending window removal")
        return
    }

    #expect(result.decision == .refreshMerged(cycleId: 2, kind: .windowRemoval))
    #expect(merged.kind == .windowRemoval)
    #expect(merged.affectedWorkspaceIds == [workspaceId])
    #expect(merged.followUpRefresh?.kind == .relayout)
    #expect(merged.followUpRefresh?.affectedWorkspaceIds == [workspaceId])
}

@Test func repeatedWindowRemovalBurstsPreserveAllPayloads() {
    let workspaceId = WorkspaceDescriptor.ID()
    var snapshot = makeOrchestrationSnapshot(
        activeRefresh: makeOrchestrationRefresh(
            cycleId: 1,
            kind: .relayout,
            reason: .workspaceTransition
        )
    )

    for cycleId in 2...40 {
        let payload = WindowRemovalPayload(
            workspaceId: workspaceId,
            layoutType: .niri,
            removedNodeId: nil,
            niriOldFrames: [:],
            shouldRecoverFocus: true
        )
        let result = OrchestrationCore.step(
            snapshot: snapshot,
            event: .refreshRequested(
                .init(
                    refresh: makeOrchestrationRefresh(
                        cycleId: UInt64(cycleId),
                        kind: .windowRemoval,
                        reason: .windowDestroyed,
                        affectedWorkspaceIds: [workspaceId],
                        windowRemovalPayload: payload
                    ),
                    shouldDropWhileBusy: false,
                    isIncrementalRefreshInProgress: false,
                    isImmediateLayoutInProgress: false,
                    hasActiveAnimationRefreshes: false
                )
            )
        )
        snapshot = result.snapshot
    }

    #expect(snapshot.refresh.pendingRefresh?.windowRemovalPayloads.count == 39)
}

@Test func managedActivationDeferralIncrementsRetryBudgetInsideKernel() {
    let workspaceId = WorkspaceDescriptor.ID()
    let requestedToken = WindowToken(pid: 55, windowId: 10)
    let observedToken = WindowToken(pid: 55, windowId: 11)
    let activeRequest = ManagedFocusRequest(
        requestId: 3,
        token: requestedToken,
        workspaceId: workspaceId
    )

    let firstResult = OrchestrationCore.step(
        snapshot: makeOrchestrationSnapshot(
            nextManagedRequestId: 4,
            activeManagedRequest: activeRequest,
            pendingFocusedToken: requestedToken,
            pendingFocusedWorkspaceId: workspaceId
        ),
        event: .activationObserved(
            .init(
                source: .workspaceDidActivateApplication,
                origin: .external,
                match: .unmanaged(
                    pid: observedToken.pid,
                    token: observedToken,
                    appFullscreen: false,
                    fallbackFullscreen: false
                )
            )
        )
    )

    #expect(firstResult.snapshot.focus.activeManagedRequest?.retryCount == 1)
    #expect(
        firstResult.snapshot.focus.activeManagedRequest?.lastActivationSource
            == .workspaceDidActivateApplication
    )

    let secondResult = OrchestrationCore.step(
        snapshot: firstResult.snapshot,
        event: .activationObserved(
            .init(
                source: .focusedWindowChanged,
                origin: .retry,
                match: .unmanaged(
                    pid: observedToken.pid,
                    token: observedToken,
                    appFullscreen: false,
                    fallbackFullscreen: false
                )
            )
        )
    )

    #expect(secondResult.snapshot.focus.activeManagedRequest?.retryCount == 1)
    #expect(
        secondResult.snapshot.focus.activeManagedRequest?.lastActivationSource
            == .focusedWindowChanged
    )
}

@Test func managedActivationRetryExhaustionCancelsRequestInsideKernel() {
    let workspaceId = WorkspaceDescriptor.ID()
    let requestedToken = WindowToken(pid: 66, windowId: 12)
    let observedToken = WindowToken(pid: 66, windowId: 13)
    let activeRequest = ManagedFocusRequest(
        requestId: 9,
        token: requestedToken,
        workspaceId: workspaceId,
        retryCount: 5,
        lastActivationSource: .workspaceDidActivateApplication
    )

    let result = OrchestrationCore.step(
        snapshot: makeOrchestrationSnapshot(
            nextManagedRequestId: 10,
            activeManagedRequest: activeRequest,
            pendingFocusedToken: requestedToken,
            pendingFocusedWorkspaceId: workspaceId
        ),
        event: .activationObserved(
            .init(
                source: .workspaceDidActivateApplication,
                origin: .external,
                match: .unmanaged(
                    pid: observedToken.pid,
                    token: observedToken,
                    appFullscreen: false,
                    fallbackFullscreen: false
                )
            )
        )
    )

    #expect(
        result.decision == .focusRequestCancelled(
            requestId: 9,
            token: requestedToken
        )
    )
    #expect(result.snapshot.focus.activeManagedRequest == nil)
    #expect(result.snapshot.focus.pendingFocusedToken == nil)
    #expect(
        result.plan.actions == [
            .clearManagedFocusState(
                requestId: 9,
                token: requestedToken,
                workspaceId: workspaceId
            )
        ]
    )
}

@Test func probeOriginRetryExhaustionLeavesPendingFocusRequestIntact() {
    let workspaceId = WorkspaceDescriptor.ID()
    let requestedToken = WindowToken(pid: 67, windowId: 12)
    let observedToken = WindowToken(pid: 67, windowId: 13)
    let activeRequest = ManagedFocusRequest(
        requestId: 10,
        token: requestedToken,
        workspaceId: workspaceId,
        retryCount: 5,
        lastActivationSource: .focusedWindowChanged
    )

    let result = OrchestrationCore.step(
        snapshot: makeOrchestrationSnapshot(
            nextManagedRequestId: 11,
            activeManagedRequest: activeRequest,
            pendingFocusedToken: requestedToken,
            pendingFocusedWorkspaceId: workspaceId
        ),
        event: .activationObserved(
            .init(
                source: .focusedWindowChanged,
                origin: .probe,
                match: .unmanaged(
                    pid: observedToken.pid,
                    token: observedToken,
                    appFullscreen: false,
                    fallbackFullscreen: false
                )
            )
        )
    )

    #expect(
        result.decision == .managedActivationDeferred(
            requestId: 10,
            reason: .pendingFocusUnmanagedToken
        )
    )
    #expect(result.snapshot.focus.activeManagedRequest == activeRequest)
    #expect(result.snapshot.focus.pendingFocusedToken == requestedToken)
    #expect(result.plan.actions == [
        .continueManagedFocusRequest(
            requestId: 10,
            reason: .pendingFocusUnmanagedToken,
            source: .focusedWindowChanged,
            origin: .probe
        )
    ])
}
