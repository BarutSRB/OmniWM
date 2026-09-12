// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension LayoutRefreshController {
    func preserveCancelledRefreshState(_ refresh: ScheduledRefresh) {
        if refresh.kind == .fullRescan,
           layoutState.inventoryStabilityHoldFullRescans
        {
            holdInventoryStabilityFullRescan(refresh, isNewerThanHeld: false)
            return
        }
        guard var pendingRefresh = layoutState.pendingRefresh else {
            layoutState.pendingRefresh = refresh
            return
        }

        let existingPendingRefresh = pendingRefresh
        let relayoutWorkspaceScope = mergedRelayoutWorkspaceScope(
            scheduledRelayoutWorkspaceScope(refresh),
            scheduledRelayoutWorkspaceScope(existingPendingRefresh)
        )
        mergeCancelledRefreshPriority(refresh, into: &pendingRefresh)

        mergeCancelledRefreshScope(refresh, relayoutScope: relayoutWorkspaceScope, into: &pendingRefresh)

        mergeCancelledRefreshFollowUp(refresh, existingPendingRefresh: existingPendingRefresh, into: &pendingRefresh)

        layoutState.pendingRefresh = pendingRefresh
    }

    private func mergeCancelledRefreshPriority(
        _ refresh: ScheduledRefresh,
        into pendingRefresh: inout ScheduledRefresh
    ) {
        pendingRefresh.suppressesWindowActivation = pendingRefresh.suppressesWindowActivation
            || refresh.suppressesWindowActivation
        pendingRefresh.workspaceMonitorRelocations = mergedWorkspaceMonitorRelocations(
            refresh.workspaceMonitorRelocations,
            pendingRefresh.workspaceMonitorRelocations
        )
        pendingRefresh.reconcilesWorkspaceMonitorState = refresh.reconcilesWorkspaceMonitorState
            || pendingRefresh.reconcilesWorkspaceMonitorState

        if refresh.kind == .fullRescan {
            if pendingRefresh.kind == .fullRescan {
                pendingRefresh.rescanScope = refresh.rescanScope.merged(with: pendingRefresh.rescanScope)
            } else {
                pendingRefresh.rescanScope = refresh.rescanScope
                pendingRefresh.reason = refresh.reason
            }
            pendingRefresh.kind = .fullRescan
        }

        if refresh.kind == .immediateRelayout,
           pendingRefresh.kind != .fullRescan,
           pendingRefresh.kind != .windowRemoval
        {
            pendingRefresh.kind = .immediateRelayout
            pendingRefresh.reason = refresh.reason
        }

        if !refresh.windowRemovalPayloads.isEmpty {
            pendingRefresh.windowRemovalPayloads = mergeWindowRemovalPayloads(
                refresh.windowRemovalPayloads,
                with: pendingRefresh.windowRemovalPayloads
            )
            if refresh.kind == .windowRemoval,
               pendingRefresh.kind != .fullRescan,
               pendingRefresh.kind != .windowRemoval
            {
                pendingRefresh.kind = .windowRemoval
                pendingRefresh.reason = refresh.reason
            }
        }
    }

    private func mergeCancelledRefreshScope(
        _ refresh: ScheduledRefresh,
        relayoutScope relayoutWorkspaceScope: WorkspaceRefreshScope?,
        into pendingRefresh: inout ScheduledRefresh
    ) {
        if pendingRefresh.kind == .fullRescan, let relayoutWorkspaceScope {
            pendingRefresh.subsumesRelayout = true
            pendingRefresh.affectedWorkspaceIds =
                relayoutWorkspaceScope.affectedWorkspaceIds
            pendingRefresh.additionalAffectedWorkspaceIds =
                relayoutWorkspaceScope.additionalAffectedWorkspaceIds
        } else {
            let mergedScope = mergedWorkspaceRefreshScope(
                WorkspaceRefreshScope(
                    affectedWorkspaceIds: pendingRefresh.affectedWorkspaceIds,
                    additionalAffectedWorkspaceIds:
                    pendingRefresh.additionalAffectedWorkspaceIds
                ),
                WorkspaceRefreshScope(
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

    private func mergeCancelledRefreshFollowUp(
        _ refresh: ScheduledRefresh,
        existingPendingRefresh: ScheduledRefresh,
        into pendingRefresh: inout ScheduledRefresh
    ) {
        let refreshIsLayout =
            refresh.kind == .immediateRelayout
                || refresh.kind == .relayout
        pendingRefresh.postLayoutActions.insert(
            contentsOf: refresh.postLayoutActions,
            at: 0
        )

        mergeAbsorbedVisibility(into: &pendingRefresh, from: refresh)
        if refresh.kind == .fullRescan {
            restoreCancelledFullRescanFollowUp(
                refresh,
                existingPendingRefresh: existingPendingRefresh,
                into: &pendingRefresh
            )
        } else if pendingRefresh.kind == .fullRescan {
            mergeFullRescanFollowUp(
                into: &pendingRefresh,
                from: refresh,
                absorbedPrecedesExistingFollowUp: true
            )
            if refreshIsLayout {
                removeSupersededCancelledRelayoutMetadata(
                    refresh,
                    newerFullRescan: existingPendingRefresh,
                    from: &pendingRefresh
                )
            }
        } else if pendingRefresh.kind == .windowRemoval, refreshIsLayout {
            restoreCancelledRelayoutFollowUp(
                refresh,
                existingPendingRefresh: existingPendingRefresh,
                into: &pendingRefresh
            )
        } else {
            pendingRefresh.followUpRefresh = mergeFollowUpRefresh(
                refresh.followUpRefresh,
                with: pendingRefresh.followUpRefresh
            )
        }
    }

    private func restoreCancelledFullRescanFollowUp(
        _ refresh: ScheduledRefresh,
        existingPendingRefresh: ScheduledRefresh,
        into pendingRefresh: inout ScheduledRefresh
    ) {
        pendingRefresh.followUpRefresh = refresh.followUpRefresh
        if existingPendingRefresh.kind == .immediateRelayout
            || existingPendingRefresh.kind == .relayout
        {
            let routedRelayoutMetadataToFollowUp = mergeRelayoutIntoFullRescan(
                existingPendingRefresh,
                fullRescan: &pendingRefresh
            )
            if routedRelayoutMetadataToFollowUp {
                pendingRefresh.workspaceMonitorRelocations =
                    refresh.workspaceMonitorRelocations
                pendingRefresh.reconcilesWorkspaceMonitorState =
                    refresh.reconcilesWorkspaceMonitorState
                pendingRefresh.subsumesRelayout =
                    refresh.subsumesRelayout
                pendingRefresh.affectedWorkspaceIds =
                    refresh.affectedWorkspaceIds
                pendingRefresh.additionalAffectedWorkspaceIds =
                    refresh.additionalAffectedWorkspaceIds
                absorbPostLayoutActionWorkspaceIds(
                    into: &pendingRefresh
                )
            }
        } else {
            mergeFullRescanFollowUp(
                into: &pendingRefresh,
                from: existingPendingRefresh
            )
        }
    }

    private func restoreCancelledRelayoutFollowUp(
        _ refresh: ScheduledRefresh,
        existingPendingRefresh: ScheduledRefresh,
        into pendingRefresh: inout ScheduledRefresh
    ) {
        let cancelledLayoutFollowUp = FollowUpRefresh(
            kind: refresh.kind,
            reason: refresh.reason,
            affectedWorkspaceIds: refresh.affectedWorkspaceIds,
            additionalAffectedWorkspaceIds:
            refresh.additionalAffectedWorkspaceIds,
            workspaceMonitorRelocations: refresh.workspaceMonitorRelocations,
            reconcilesWorkspaceMonitorState: refresh.reconcilesWorkspaceMonitorState,
            suppressesWindowActivation: refresh.suppressesWindowActivation
        )
        let cancelledFollowUp = mergeFollowUpRefresh(
            cancelledLayoutFollowUp,
            with: refresh.followUpRefresh
        )
        pendingRefresh.followUpRefresh = mergeFollowUpRefresh(
            cancelledFollowUp,
            with: pendingRefresh.followUpRefresh
        )
        pendingRefresh.workspaceMonitorRelocations =
            existingPendingRefresh.workspaceMonitorRelocations
        pendingRefresh.reconcilesWorkspaceMonitorState =
            existingPendingRefresh.reconcilesWorkspaceMonitorState
    }
}
