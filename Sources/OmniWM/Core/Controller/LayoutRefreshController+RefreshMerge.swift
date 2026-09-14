// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension LayoutRefreshController {
    @MainActor
    struct RefreshMerge {
        private let controller: LayoutRefreshController
        private let refresh: ScheduledRefresh
        private var pendingRefresh: ScheduledRefresh
        private var relayoutWorkspaceScope: LayoutRefreshController.WorkspaceRefreshScope?
        private let existingAffectedWorkspaceIds: Set<WorkspaceDescriptor.ID>
        private let existingAdditionalAffectedWorkspaceIds: Set<WorkspaceDescriptor.ID>
        private let windowRemovalPayloads: [WindowRemovalPayload]
        private var workspaceMonitorRelocations: [WindowToken: ScheduledWorkspaceMonitorRelocation]
        private var reconcilesWorkspaceMonitorState: Bool
        private let suppressesWindowActivation: Bool
        private let existingWorkspaceMonitorRelocations: [WindowToken: ScheduledWorkspaceMonitorRelocation]
        private let existingReconcilesWorkspaceMonitorState: Bool
        private var routedRelayoutMetadataToFollowUp: Bool
        init(existing: ScheduledRefresh, incoming: ScheduledRefresh, controller: LayoutRefreshController) {
            self.controller = controller
            refresh = incoming
            pendingRefresh = existing
            self.relayoutWorkspaceScope = controller.mergedRelayoutWorkspaceScope(
                controller.scheduledRelayoutWorkspaceScope(pendingRefresh),
                controller.scheduledRelayoutWorkspaceScope(refresh)
            )
            self.existingAffectedWorkspaceIds = pendingRefresh.affectedWorkspaceIds
            self.existingAdditionalAffectedWorkspaceIds =
                pendingRefresh.additionalAffectedWorkspaceIds
            self.windowRemovalPayloads = controller.mergeWindowRemovalPayloads(
                pendingRefresh.windowRemovalPayloads,
                with: refresh.windowRemovalPayloads
            )
            self.workspaceMonitorRelocations = controller.mergedWorkspaceMonitorRelocations(
                pendingRefresh.workspaceMonitorRelocations,
                refresh.workspaceMonitorRelocations
            )
            self.reconcilesWorkspaceMonitorState = pendingRefresh.reconcilesWorkspaceMonitorState
                || refresh.reconcilesWorkspaceMonitorState
            self.suppressesWindowActivation = pendingRefresh.suppressesWindowActivation
                || refresh.suppressesWindowActivation
            self.existingWorkspaceMonitorRelocations = pendingRefresh.workspaceMonitorRelocations
            self.existingReconcilesWorkspaceMonitorState =
                pendingRefresh.reconcilesWorkspaceMonitorState
            self.routedRelayoutMetadataToFollowUp = false
        }

        mutating func execute() -> ScheduledRefresh {
            switch pendingRefresh.kind {
            case .fullRescan: mergeFullRescan()
            case .visibilityRefresh: mergeVisibilityRefresh()
            case .windowRemoval: mergeWindowRemoval()
            case .immediateRelayout: mergeImmediateRelayout()
            case .relayout: mergeRelayout()
            }
            resolveWorkspaceScope()
            resolveMetadata()
            return pendingRefresh
        }
    }
}

extension LayoutRefreshController.RefreshMerge {
    private mutating func resolveWorkspaceScope() {
        if routedRelayoutMetadataToFollowUp {
            relayoutWorkspaceScope =
                controller.scheduledRelayoutWorkspaceScope(pendingRefresh)
        }
        let resolvedRelayoutWorkspaceScope = pendingRefresh.kind == .fullRescan
            ? controller.mergedRelayoutWorkspaceScope(
                relayoutWorkspaceScope,
                controller.scheduledRelayoutWorkspaceScope(pendingRefresh)
            )
            : nil
        if let resolvedRelayoutWorkspaceScope {
            pendingRefresh.subsumesRelayout = true
            pendingRefresh.affectedWorkspaceIds =
                resolvedRelayoutWorkspaceScope.affectedWorkspaceIds
            pendingRefresh.additionalAffectedWorkspaceIds =
                resolvedRelayoutWorkspaceScope.additionalAffectedWorkspaceIds
        } else {
            var mergedScope = controller.mergedWorkspaceRefreshScope(
                LayoutRefreshController.WorkspaceRefreshScope(
                    affectedWorkspaceIds: pendingRefresh.affectedWorkspaceIds,
                    additionalAffectedWorkspaceIds:
                    pendingRefresh.additionalAffectedWorkspaceIds
                ),
                LayoutRefreshController.WorkspaceRefreshScope(
                    affectedWorkspaceIds: existingAffectedWorkspaceIds,
                    additionalAffectedWorkspaceIds:
                    existingAdditionalAffectedWorkspaceIds
                )
            )
            mergedScope = controller.mergedWorkspaceRefreshScope(
                mergedScope,
                LayoutRefreshController.WorkspaceRefreshScope(
                    affectedWorkspaceIds: refresh.affectedWorkspaceIds,
                    additionalAffectedWorkspaceIds:
                    refresh.additionalAffectedWorkspaceIds
                )
            )
            pendingRefresh.affectedWorkspaceIds = mergedScope.affectedWorkspaceIds
            pendingRefresh.additionalAffectedWorkspaceIds =
                mergedScope.additionalAffectedWorkspaceIds
        }
    }

    private mutating func resolveMetadata() {
        pendingRefresh.windowRemovalPayloads = windowRemovalPayloads
        pendingRefresh.workspaceMonitorRelocations = controller.mergedWorkspaceMonitorRelocations(
            pendingRefresh.workspaceMonitorRelocations,
            workspaceMonitorRelocations
        )
        pendingRefresh.reconcilesWorkspaceMonitorState =
            pendingRefresh.reconcilesWorkspaceMonitorState
                || reconcilesWorkspaceMonitorState
        pendingRefresh.suppressesWindowActivation =
            pendingRefresh.suppressesWindowActivation
                || suppressesWindowActivation
        if routedRelayoutMetadataToFollowUp {
            pendingRefresh.workspaceMonitorRelocations =
                existingWorkspaceMonitorRelocations
            pendingRefresh.reconcilesWorkspaceMonitorState =
                existingReconcilesWorkspaceMonitorState
        }
    }

    private mutating func mergeFullRescan() {
        switch refresh.kind {
        case .fullRescan:
            pendingRefresh.reason = refresh.reason
            pendingRefresh.rescanScope = pendingRefresh.rescanScope.merged(with: refresh.rescanScope)
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            controller.mergeFullRescanFollowUp(into: &pendingRefresh, from: refresh)
            controller.mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case .immediateRelayout,
             .relayout:
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            routedRelayoutMetadataToFollowUp = controller.mergeRelayoutIntoFullRescan(
                refresh,
                fullRescan: &pendingRefresh
            )
            controller.mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case .visibilityRefresh,
             .windowRemoval:
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            controller.mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        }
    }

    private mutating func mergeVisibilityRefresh() {
        switch refresh.kind {
        case .fullRescan,
             .windowRemoval,
             .immediateRelayout,
             .relayout:
            var upgradedRefresh = refresh
            upgradedRefresh.postLayoutActions.append(contentsOf: pendingRefresh.postLayoutActions)
            controller.mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
            controller.mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
            pendingRefresh = upgradedRefresh
        case .visibilityRefresh:
            pendingRefresh.reason = refresh.reason
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
        }
    }

    private mutating func mergeWindowRemoval() {
        switch refresh.kind {
        case .fullRescan:
            upgradeToFullRescan()
        case .windowRemoval:
            pendingRefresh.reason = refresh.reason
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            controller.mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case .immediateRelayout:
            mergeWindowRemovalWithImmediateRelayout()
        case .relayout:
            mergeWindowRemovalWithRelayout()
        case .visibilityRefresh:
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            controller.mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        }
    }

    private mutating func mergeImmediateRelayout() {
        switch refresh.kind {
        case .fullRescan:
            upgradeToFullRescan()
        case .windowRemoval:
            upgradeToWindowRemoval()
        case .visibilityRefresh:
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            controller.mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case .immediateRelayout:
            pendingRefresh.reason = refresh.reason
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            pendingRefresh.followUpRefresh = controller.mergeFollowUpRefresh(
                pendingRefresh.followUpRefresh,
                with: refresh.followUpRefresh
            )
            controller.mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case .relayout:
            mergeImmediateRelayoutWithRelayout()
        }
    }

    private mutating func mergeRelayout() {
        switch refresh.kind {
        case .fullRescan:
            upgradeToFullRescan()
        case .windowRemoval:
            upgradeToWindowRemoval()
        case .visibilityRefresh:
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            controller.mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case .relayout:
            pendingRefresh.reason = refresh.reason
            pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
            pendingRefresh.followUpRefresh = controller.mergeFollowUpRefresh(
                pendingRefresh.followUpRefresh,
                with: refresh.followUpRefresh
            )
            controller.mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        case .immediateRelayout:
            mergeRelayoutWithImmediateRelayout()
        }
    }

    private mutating func upgradeToFullRescan() {
        var upgradedRefresh = refresh
        upgradedRefresh.postLayoutActions.insert(
            contentsOf: pendingRefresh.postLayoutActions,
            at: 0
        )
        controller.mergeFullRescanFollowUp(
            into: &upgradedRefresh,
            from: pendingRefresh,
            absorbedPrecedesExistingFollowUp: true
        )
        controller.mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
        controller.mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
        pendingRefresh = upgradedRefresh
    }

    private mutating func mergeWindowRemovalWithImmediateRelayout() {
        pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
        controller.mergeFollowUp(
            into: &pendingRefresh,
            kind: .immediateRelayout,
            reason: refresh.reason,
            affectedWorkspaceIds: refresh.affectedWorkspaceIds,
            additionalAffectedWorkspaceIds:
            refresh.additionalAffectedWorkspaceIds,
            workspaceMonitorRelocations: refresh.workspaceMonitorRelocations,
            reconcilesWorkspaceMonitorState: refresh.reconcilesWorkspaceMonitorState,
            suppressesWindowActivation: refresh.suppressesWindowActivation
        )
        workspaceMonitorRelocations = pendingRefresh.workspaceMonitorRelocations
        reconcilesWorkspaceMonitorState =
            pendingRefresh.reconcilesWorkspaceMonitorState
        controller.mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
    }

    private mutating func mergeWindowRemovalWithRelayout() {
        pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
        controller.mergeFollowUp(
            into: &pendingRefresh,
            kind: .relayout,
            reason: refresh.reason,
            affectedWorkspaceIds: refresh.affectedWorkspaceIds,
            additionalAffectedWorkspaceIds:
            refresh.additionalAffectedWorkspaceIds,
            workspaceMonitorRelocations: refresh.workspaceMonitorRelocations,
            reconcilesWorkspaceMonitorState: refresh.reconcilesWorkspaceMonitorState,
            suppressesWindowActivation: refresh.suppressesWindowActivation
        )
        workspaceMonitorRelocations = pendingRefresh.workspaceMonitorRelocations
        reconcilesWorkspaceMonitorState =
            pendingRefresh.reconcilesWorkspaceMonitorState
        controller.mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
    }

    private mutating func upgradeToWindowRemoval() {
        var upgradedRefresh = refresh
        upgradedRefresh.postLayoutActions.append(contentsOf: pendingRefresh.postLayoutActions)
        controller.mergeDeferredLayout(
            into: &upgradedRefresh,
            from: pendingRefresh
        )
        controller.mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
        controller.mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
        pendingRefresh = upgradedRefresh
        workspaceMonitorRelocations = refresh.workspaceMonitorRelocations
        reconcilesWorkspaceMonitorState =
            refresh.reconcilesWorkspaceMonitorState
    }

    private mutating func mergeImmediateRelayoutWithRelayout() {
        pendingRefresh.postLayoutActions.append(contentsOf: refresh.postLayoutActions)
        controller.mergeFollowUp(
            into: &pendingRefresh,
            kind: .relayout,
            reason: refresh.reason,
            affectedWorkspaceIds: refresh.affectedWorkspaceIds,
            additionalAffectedWorkspaceIds:
            refresh.additionalAffectedWorkspaceIds,
            reconcilesWorkspaceMonitorState: refresh.reconcilesWorkspaceMonitorState,
            suppressesWindowActivation: refresh.suppressesWindowActivation
        )
        controller.mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
    }

    private mutating func mergeRelayoutWithImmediateRelayout() {
        var upgradedRefresh = refresh
        upgradedRefresh.postLayoutActions.append(contentsOf: pendingRefresh.postLayoutActions)
        upgradedRefresh.followUpRefresh = controller.mergeFollowUpRefresh(
            pendingRefresh.followUpRefresh,
            with: refresh.followUpRefresh
        )
        controller.mergeFollowUp(
            into: &upgradedRefresh,
            kind: .relayout,
            reason: pendingRefresh.reason,
            affectedWorkspaceIds: pendingRefresh.affectedWorkspaceIds,
            additionalAffectedWorkspaceIds:
            pendingRefresh.additionalAffectedWorkspaceIds,
            reconcilesWorkspaceMonitorState: pendingRefresh.reconcilesWorkspaceMonitorState,
            suppressesWindowActivation: pendingRefresh.suppressesWindowActivation
        )
        controller.mergeAbsorbedVisibility(into: &upgradedRefresh, from: pendingRefresh)
        controller.mergeAbsorbedVisibility(into: &upgradedRefresh, from: refresh)
        pendingRefresh = upgradedRefresh
    }
}
