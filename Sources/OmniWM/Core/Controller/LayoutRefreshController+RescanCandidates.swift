// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension LayoutRefreshController {
    func reconcileFullRescanCandidate(
        _ candidate: FullRescanWindowCandidate,
        context: FullRescanMutationContext,
        progress: inout FullRescanProgress
    ) {
        guard let identity = prepareFullRescanCandidateIdentity(candidate, context: context, progress: &progress)
        else { return }
        let decision = prepareFullRescanWindowDecision(candidate, identity: identity, context: context)
        let window = FullRescanEvaluatedWindow(candidate: candidate, identity: identity, decision: decision)
        if shouldYieldFullRescanWindow(window, context: context, progress: &progress) { return }
        guard let trackedMode = decision.effectiveTrackedMode else {
            rejectFullRescanWindow(window, context: context, progress: &progress)
            return
        }
        if trackedMode != .tiling {
            context.controller.axEventHandler.cancelTrackedTilingPromotionRetry(windowId: candidate.windowId)
        }
        if deferFullRescanWindow(window, trackedMode: trackedMode, context: context, progress: &progress) { return }
        reconcileTrackedFullRescanWindow(window, trackedMode: trackedMode, context: context, progress: &progress)
    }

    private func reconcileTrackedFullRescanWindow(
        _ window: FullRescanEvaluatedWindow,
        trackedMode: TrackedWindowMode,
        context: FullRescanMutationContext,
        progress: inout FullRescanProgress
    ) {
        let structuralMatch = fullRescanStructuralMatch(window, trackedMode: trackedMode, context: context)
        if rekeyFullRescanReplacement(
            window,
            trackedMode: trackedMode,
            match: structuralMatch,
            context: context,
            progress: &progress
        ) { return }
        let defaultWorkspace = fullRescanDefaultWorkspace(
            window,
            trackedMode: trackedMode,
            structuralMatch: structuralMatch,
            context: context
        )
        let assignment = fullRescanAdmissionAssignment(window, defaultWorkspace: defaultWorkspace, context: context)
        progress.affectedWorkspaceIds.insert(assignment.workspaceId)
        let admission = prepareFullRescanAdmission(
            window,
            trackedMode: trackedMode,
            assignment: assignment,
            context: context
        )
        let admittedToken = admitFullRescanWindow(window, admission: admission, context: context)
        guard completeFullRescanTracking(
            window,
            admission: admission,
            admittedToken: admittedToken,
            context: context,
            progress: &progress
        ) else { return }
        applyFullRescanGeometry(
            window,
            trackedMode: trackedMode,
            admission: admission,
            admittedToken: admittedToken,
            context: context
        )
        progress.seenKeys.insert(admittedToken)
    }

    private func shouldYieldFullRescanWindow(
        _ window: FullRescanEvaluatedWindow,
        context: FullRescanMutationContext,
        progress: inout FullRescanProgress
    ) -> Bool {
        let enumerationSnapshot = context.enumerationSnapshot
        let scope = context.scope
        let token = window.identity.token
        let existingEntry = window.identity.existingEntry
        let bundleId = window.identity.bundleId
        let evaluation = window.decision.evaluation
        let decision = window.decision.evaluation.decision
        let effectiveTrackedMode = window.decision.effectiveTrackedMode
        return yieldToDeferredCreate(
            .init(
                token: token,
                bundleId: bundleId ?? evaluation.facts.ax.bundleId,
                mode: effectiveTrackedMode,
                factsAreDeferred: decision.disposition == .undecided,
                facts: evaluation.facts,
                entry: existingEntry
            ),
            scope: scope,
            capturedInventory: .init(
                infoByWindowId: enumerationSnapshot.windowServerInfoByWindowId,
                authoritativeWindowIds: enumerationSnapshot.exactWindowIds,
                authoritativePIDs: enumerationSnapshot.authoritativeTargetPIDs
            ),
            seenKeys: &progress.seenKeys
        )
    }

    private func rejectFullRescanWindow(
        _ window: FullRescanEvaluatedWindow,
        context: FullRescanMutationContext,
        progress: inout FullRescanProgress
    ) {
        let controller = context.controller
        let ax = window.candidate.axRef
        let pid = window.identity.token.pid
        let winId = window.identity.token.windowId
        let token = window.identity.token
        let existingEntry = window.identity.existingEntry
        let decision = window.decision.evaluation.decision
        let placementOrigin = window.decision.placementOrigin
        if existingEntry != nil {
            controller.axEventHandler.cancelTrackedTilingPromotionRetry(windowId: winId)
            progress.decisionBasedRemovals.append(existingEntry?.token ?? token)
        } else {
            if decision.disposition == .undecided,
               let windowId = UInt32(exactly: winId)
            {
                let reason: WindowAdmissionPendingReason = decision.deferredReason
                    == .windowServerEvidenceMissing ? .windowServerEvidenceMissing : .factsDeferred
                _ = controller.axEventHandler.scheduleCandidateAdmissionRetry(
                    windowId: windowId,
                    pid: pid,
                    axRef: ax,
                    reason: reason,
                    placementOrigin: placementOrigin
                )
            } else {
                controller.axEventHandler.discardCreatePlacementContext(for: winId)
            }
        }
    }

    private func deferFullRescanWindow(
        _ window: FullRescanEvaluatedWindow,
        trackedMode: TrackedWindowMode,
        context: FullRescanMutationContext,
        progress: inout FullRescanProgress
    ) -> Bool {
        let controller = context.controller
        let ax = window.candidate.axRef
        let token = window.identity.token
        let existingEntry = window.identity.existingEntry
        let evaluation = window.decision.evaluation
        let placementOrigin = window.decision.placementOrigin
        if controller.axEventHandler.deferAdmissionIfNeeded(
            evaluation: evaluation,
            axRef: ax,
            token: token,
            mode: trackedMode,
            existingEntry: existingEntry,
            placementOrigin: placementOrigin
        ) {
            if let existingEntry {
                progress.seenKeys.insert(existingEntry.token)
            }
            return true
        }

        return false
    }
}
