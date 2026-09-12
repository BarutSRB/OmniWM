// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension LayoutRefreshController {
    func prepareFullRescanCandidateIdentity(
        _ candidate: FullRescanWindowCandidate,
        context: FullRescanMutationContext,
        progress: inout FullRescanProgress
    ) -> FullRescanCandidateIdentity? {
        let controller = context.controller
        let enumerationSnapshot = context.enumerationSnapshot
        let ax = candidate.axRef
        let pid = candidate.pid
        let winId = candidate.windowId
        let token = WindowToken(pid: pid, windowId: winId)
        progress.observedTopLevelInventoryTokens.insert(token)
        let existingEntry: WindowState?
        switch controller.axEventHandler.resolveFullRescanIdentity(
            axRef: ax,
            pid: pid,
            windowId: winId,
            observedAliases: enumerationSnapshot.identityAliasesByWindowId[winId],
            failedPIDs: enumerationSnapshot.failedPIDs,
            sizeConstraints: candidate.enumeratedWindow.decisionEvidence.sizeConstraints
        ) {
        case let .process(entry):
            existingEntry = entry
        case let .preserve(token):
            progress.seenKeys.insert(token)
            if let entry = controller.workspaceManager.entry(for: token) {
                progress.affectedWorkspaceIds.insert(entry.workspaceId)
            }
            return nil
        }
        if let existingEntry {
            progress.affectedWorkspaceIds.insert(existingEntry.workspaceId)
        }
        let bundleId = controller.appInfoCache.bundleId(for: pid)
            ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        guard isEligibleFullRescanCandidate(
            candidate,
            existingEntry: existingEntry,
            bundleId: bundleId,
            controller: controller
        ) else { return nil }
        return FullRescanCandidateIdentity(token: token, existingEntry: existingEntry, bundleId: bundleId)
    }

    private func isEligibleFullRescanCandidate(
        _ candidate: FullRescanWindowCandidate,
        existingEntry: WindowState?,
        bundleId: String?,
        controller: WMController
    ) -> Bool {
        let winId = candidate.windowId
        let ax = candidate.axRef
        if let bundleId {
            if bundleId == LockScreenObserver.lockScreenAppBundleId {
                return false
            }
        }

        if existingEntry == nil,
           controller.axEventHandler.isAdmissionQuarantined(windowId: winId, axRef: ax)
        {
            controller.axEventHandler.discardCreatePlacementContext(for: winId)
            return false
        }
        return true
    }

    func prepareFullRescanWindowDecision(
        _ candidate: FullRescanWindowCandidate,
        identity: FullRescanCandidateIdentity,
        context: FullRescanMutationContext
    ) -> FullRescanWindowDecision {
        let controller = context.controller
        let screenFrames = context.screenFrames
        let token = identity.token
        let existingEntry = identity.existingEntry
        let winId = candidate.windowId
        let appFullscreen = candidate.isFullscreen(screenFrames: screenFrames)
        let evaluation = controller.evaluateWindowDisposition(
            token: token,
            evidence: candidate.enumeratedWindow.decisionEvidence,
            appFullscreen: appFullscreen,
            windowInfo: candidate.windowServerInfo,
            admissionGeometry: candidate.enumeratedWindow.admissionGeometry
        )
        let decision = evaluation.decision
        let deferredTrackedEntry = decision.disposition == .undecided
            ? existingEntry
            : nil
        let createPlacementContext = existingEntry == nil
            ? controller.axEventHandler.pendingCreatePlacementContext(for: winId)
            : nil
        let placementOrigin: WorkspacePlacementOrigin = createPlacementContext == nil
            ? .discovery
            : .liveCreate
        let shouldPreservePreFullscreenState = preservesPreFullscreenState(
            existingEntry,
            appFullscreen: appFullscreen,
            controller: controller
        )
        let effectiveTrackedMode: TrackedWindowMode?
        if shouldPreservePreFullscreenState {
            effectiveTrackedMode = existingEntry?.mode
        } else {
            effectiveTrackedMode = controller.trackedModePreservingAutomaticFallbackState(
                decision: decision,
                existingEntry: existingEntry,
                context: .automatic
            )
        }

        return FullRescanWindowDecision(
            appFullscreen: appFullscreen,
            evaluation: evaluation,
            deferredTrackedEntry: deferredTrackedEntry,
            createPlacementContext: createPlacementContext,
            placementOrigin: placementOrigin,
            shouldPreservePreFullscreenState: shouldPreservePreFullscreenState,
            effectiveTrackedMode: effectiveTrackedMode
        )
    }

    private func preservesPreFullscreenState(
        _ existingEntry: WindowState?,
        appFullscreen: Bool,
        controller: WMController
    ) -> Bool {
        return existingEntry.map { existingEntry in
            !appFullscreen
                && (
                    controller.workspaceManager.nativeFullscreenRecord(for: existingEntry.token) != nil
                        || existingEntry.layoutReason == .nativeFullscreen
                )
        } ?? false
    }
}
