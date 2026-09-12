// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

extension LayoutRefreshController {
    func handleRefresh(
        _ refresh: ScheduledRefresh,
        whileActive activeRefresh: ScheduledRefresh
    ) {
        switch (activeRefresh.kind, refresh.kind) {
        case (.fullRescan, .fullRescan):
            mergePendingRefresh(refresh)
        case (.fullRescan, .visibilityRefresh):
            mergePendingRefresh(refresh)
        case (.fullRescan, .windowRemoval),
             (.fullRescan, .immediateRelayout),
             (.fullRescan, .relayout):
            mergePendingRefresh(refresh)
        case (.visibilityRefresh, .visibilityRefresh):
            mergePendingRefresh(refresh)
        case (.visibilityRefresh, .fullRescan),
             (.visibilityRefresh, .windowRemoval),
             (.visibilityRefresh, .immediateRelayout),
             (.visibilityRefresh, .relayout):
            mergePendingRefresh(refresh)
            layoutState.activeRefreshTask?.cancel()
        case (.windowRemoval, .fullRescan):
            mergePendingRefresh(refresh)
        case (.windowRemoval, _):
            mergePendingRefresh(refresh)
        case (.immediateRelayout, .fullRescan):
            mergePendingRefresh(refresh)
            layoutState.activeRefreshTask?.cancel()
        case (.immediateRelayout, .immediateRelayout):
            mergePendingRefresh(refresh)
        case (.immediateRelayout, .relayout):
            mergePendingRefresh(refresh)
        case (.immediateRelayout, .visibilityRefresh):
            mergePendingRefresh(refresh)
        case (.immediateRelayout, .windowRemoval):
            mergePendingRefresh(refresh)
            layoutState.activeRefreshTask?.cancel()
        case (.relayout, .fullRescan),
             (.relayout, .immediateRelayout),
             (.relayout, .windowRemoval):
            mergePendingRefresh(refresh)
            layoutState.activeRefreshTask?.cancel()
        case (.relayout, .relayout):
            mergePendingRefresh(refresh)
        case (.relayout, .visibilityRefresh):
            mergePendingRefresh(refresh)
        }
    }

    func mergeFullRescanFollowUp(
        into fullRescan: inout ScheduledRefresh,
        from absorbed: ScheduledRefresh,
        absorbedPrecedesExistingFollowUp: Bool = false
    ) {
        guard fullRescan.kind == .fullRescan else { return }
        fullRescan.followUpRefresh = absorbedPrecedesExistingFollowUp
            ? mergeFollowUpRefresh(absorbed.followUpRefresh, with: fullRescan.followUpRefresh)
            : mergeFollowUpRefresh(fullRescan.followUpRefresh, with: absorbed.followUpRefresh)
        guard let followUpRefresh = fullRescan.followUpRefresh else { return }
        fullRescan.suppressesWindowActivation =
            fullRescan.suppressesWindowActivation
                || followUpRefresh.suppressesWindowActivation
        absorbPostLayoutActionWorkspaceIds(into: &fullRescan)
    }

    func mergeRelayoutIntoFullRescan(
        _ relayout: ScheduledRefresh,
        fullRescan: inout ScheduledRefresh
    ) -> Bool {
        guard fullRescan.kind == .fullRescan,
              relayout.kind == .immediateRelayout || relayout.kind == .relayout
        else {
            return false
        }
        guard fullRescan.followUpRefresh != nil else {
            mergeFullRescanFollowUp(into: &fullRescan, from: relayout)
            return false
        }
        let routesMetadataToFollowUp = relayout.postLayoutActions.isEmpty
        if !routesMetadataToFollowUp {
            for token in relayout.workspaceMonitorRelocations.keys {
                fullRescan.followUpRefresh?
                    .workspaceMonitorRelocations
                    .removeValue(forKey: token)
            }
        }
        fullRescan.followUpRefresh = mergeFollowUpRefresh(
            fullRescan.followUpRefresh,
            with: FollowUpRefresh(
                kind: relayout.kind,
                reason: relayout.reason,
                affectedWorkspaceIds: relayout.affectedWorkspaceIds,
                additionalAffectedWorkspaceIds: relayout.additionalAffectedWorkspaceIds,
                workspaceMonitorRelocations: routesMetadataToFollowUp
                    ? relayout.workspaceMonitorRelocations
                    : [:],
                reconcilesWorkspaceMonitorState: routesMetadataToFollowUp
                    && relayout.reconcilesWorkspaceMonitorState,
                suppressesWindowActivation: relayout.suppressesWindowActivation
            )
        )
        fullRescan.followUpRefresh = mergeFollowUpRefresh(
            fullRescan.followUpRefresh,
            with: relayout.followUpRefresh
        )
        fullRescan.suppressesWindowActivation =
            fullRescan.suppressesWindowActivation
                || (fullRescan.followUpRefresh?.suppressesWindowActivation ?? false)
        absorbPostLayoutActionWorkspaceIds(into: &fullRescan)
        return routesMetadataToFollowUp
    }

    func absorbPostLayoutActionWorkspaceIds(
        into fullRescan: inout ScheduledRefresh
    ) {
        guard fullRescan.kind == .fullRescan else { return }
        let workspaceIds = Set(
            fullRescan.postLayoutActions.flatMap(\.workspaceSeqs.keys)
        )
        guard !workspaceIds.isEmpty else { return }
        absorbRelayoutWorkspaceIds(workspaceIds, into: &fullRescan)
    }

    func resolvedScheduledWorkspaceIds(
        _ refresh: ScheduledRefresh
    ) -> Set<WorkspaceDescriptor.ID> {
        resolvedWorkspaceIds(
            affectedWorkspaceIds: refresh.affectedWorkspaceIds,
            additionalAffectedWorkspaceIds: refresh.additionalAffectedWorkspaceIds
        )
    }

    func resolvedFollowUpWorkspaceIds(
        _ followUpRefresh: FollowUpRefresh
    ) -> Set<WorkspaceDescriptor.ID> {
        resolvedWorkspaceIds(
            affectedWorkspaceIds: followUpRefresh.affectedWorkspaceIds,
            additionalAffectedWorkspaceIds: followUpRefresh.additionalAffectedWorkspaceIds
        )
    }

    func resolvedWorkspaceIds(
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        additionalAffectedWorkspaceIds: Set<WorkspaceDescriptor.ID>
    ) -> Set<WorkspaceDescriptor.ID> {
        guard affectedWorkspaceIds.isEmpty else {
            return affectedWorkspaceIds.union(additionalAffectedWorkspaceIds)
        }
        return currentActiveWorkspaceIds().union(additionalAffectedWorkspaceIds)
    }

    func removeSupersededCancelledRelayoutMetadata(
        _ cancelledRelayout: ScheduledRefresh,
        newerFullRescan: ScheduledRefresh,
        from mergedFullRescan: inout ScheduledRefresh
    ) {
        guard cancelledRelayout.postLayoutActions.isEmpty,
              let newerFollowUp = newerFullRescan.followUpRefresh
        else {
            return
        }
        for token in cancelledRelayout.workspaceMonitorRelocations.keys
            where newerFollowUp.workspaceMonitorRelocations[token] != nil
        {
            if let primaryRelocation =
                newerFullRescan.workspaceMonitorRelocations[token]
            {
                mergedFullRescan.workspaceMonitorRelocations[token] =
                    primaryRelocation
            } else {
                mergedFullRescan.workspaceMonitorRelocations.removeValue(
                    forKey: token
                )
            }
        }
    }

    func scheduledRelayoutWorkspaceScope(
        _ refresh: ScheduledRefresh
    ) -> WorkspaceRefreshScope? {
        switch refresh.kind {
        case .immediateRelayout,
             .relayout:
            WorkspaceRefreshScope(
                affectedWorkspaceIds: refresh.affectedWorkspaceIds,
                additionalAffectedWorkspaceIds: refresh.additionalAffectedWorkspaceIds
            )
        case .fullRescan:
            refresh.subsumesRelayout
                ? WorkspaceRefreshScope(
                    affectedWorkspaceIds: refresh.affectedWorkspaceIds,
                    additionalAffectedWorkspaceIds: refresh.additionalAffectedWorkspaceIds
                )
                : nil
        case .visibilityRefresh,
             .windowRemoval:
            nil
        }
    }

    func mergedRelayoutWorkspaceScope(
        _ existing: WorkspaceRefreshScope?,
        _ incoming: WorkspaceRefreshScope?
    ) -> WorkspaceRefreshScope? {
        switch (existing, incoming) {
        case (nil, nil):
            nil
        case let (scope?, nil),
             let (nil, scope?):
            scope
        case let (existing?, incoming?):
            mergedWorkspaceRefreshScope(existing, incoming)
        }
    }

    func absorbRelayoutWorkspaceIds(
        _ workspaceIds: Set<WorkspaceDescriptor.ID>,
        into fullRescan: inout ScheduledRefresh
    ) {
        guard fullRescan.kind == .fullRescan else { return }
        if fullRescan.subsumesRelayout {
            let mergedScope = mergedWorkspaceRefreshScope(
                WorkspaceRefreshScope(
                    affectedWorkspaceIds: fullRescan.affectedWorkspaceIds,
                    additionalAffectedWorkspaceIds: fullRescan.additionalAffectedWorkspaceIds
                ),
                WorkspaceRefreshScope(
                    affectedWorkspaceIds: workspaceIds,
                    additionalAffectedWorkspaceIds: []
                )
            )
            fullRescan.affectedWorkspaceIds = mergedScope.affectedWorkspaceIds
            fullRescan.additionalAffectedWorkspaceIds =
                mergedScope.additionalAffectedWorkspaceIds
        } else {
            fullRescan.affectedWorkspaceIds = workspaceIds
            fullRescan.additionalAffectedWorkspaceIds = []
            fullRescan.subsumesRelayout = true
        }
    }
}
