// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension LayoutRefreshController {
    func resolveNativeSpaceRescanEvidence(
        scope: RescanScope
    ) throws -> NativeSpaceRescanEvidence {
        guard case let .targeted(_, nativeSpaceIds, _) = scope,
              !nativeSpaceIds.isEmpty
        else {
            return .init()
        }

        let inventory: [UInt64: [WindowServerInfo]]
        switch nativeSpaceWindowInventoryProvider(nativeSpaceIds) {
        case let .authoritative(authoritativeInventory):
            inventory = authoritativeInventory
        case .queryFailed,
             .unavailable:
            requestFullRescan(reason: .staleFullRescan, scope: .all)
            throw CancellationError()
        }

        var evidence = NativeSpaceRescanEvidence()
        for info in inventory.values.joined() {
            let windowId = Int(info.id)
            evidence.windowIds.insert(windowId)
            evidence.windowServerInfoByWindowId[windowId] = info
            if SkyLight.isSuitableNativeSpaceWindow(info) {
                evidence.resolvedPIDs.insert(info.pid)
            }
        }
        return evidence
    }

    func buildFullEffectPlan(
        removalPayloads: [WindowRemovalPayload],
        scope: RescanScope,
        permitsMissingRetirement: Bool,
        relayoutWorkspaceIds: Set<WorkspaceDescriptor.ID>?,
        postLayoutActions: [RefreshPostLayoutAction]
    ) async throws -> EffectPlan {
        guard let controller else { return .init() }

        let start = FullRescanStartState(controller: controller)
        var progress = initialFullRescanProgress(
            removalPayloads: removalPayloads,
            scope: scope,
            entriesAtStart: start.entries
        )
        let nativeSpaceEvidence = try resolveNativeSpaceRescanEvidence(scope: scope)
        let enumerationSnapshot = try await enumerateFullRescan(
            scope: scope,
            nativeSpaceEvidence: nativeSpaceEvidence,
            preservingPIDsByWindowId: start.preservingPIDsByWindowId,
            entriesAtStart: start.entries,
            controller: controller
        )
        try validateFullRescanMutation(start.seq, controller: controller)
        let postLayoutActionWorkspacesCurrentAtMutation = postLayoutActions.map {
            $0.currentWorkspaces(using: controller.workspaceManager)
        }
        progress.observedTopLevelInventoryTokens.reserveCapacity(enumerationSnapshot.windows.count)
        let focusedWorkspaceId = controller.activeWorkspace()?.id
        let screenFrames = NSScreen.screens.map(\.frame)

        let mutationContext = FullRescanMutationContext(
            controller: controller,
            enumerationSnapshot: enumerationSnapshot,
            scope: scope,
            focusedWorkspaceId: focusedWorkspaceId,
            screenFrames: screenFrames
        )
        for candidate in enumerationSnapshot.windows {
            reconcileFullRescanCandidate(candidate, context: mutationContext, progress: &progress)
        }

        retireFullRescanWindows(
            context: mutationContext,
            hadNativeFullscreenLifecycleContextAtStart: start.hadNativeFullscreenLifecycleContext,
            permitsMissingRetirement: permitsMissingRetirement,
            progress: &progress
        )

        reconcileFullRescanBindings(context: mutationContext)

        try Task.checkCancellation()

        return buildFullRescanLayoutPlan(
            FullRescanLayoutRequest(
                removalPayloads: removalPayloads,
                relayoutWorkspaceIds: relayoutWorkspaceIds,
                postLayoutActions: postLayoutActions,
                postLayoutActionWorkspacesCurrentAtMutation: postLayoutActionWorkspacesCurrentAtMutation
            ),
            context: mutationContext,
            affectedWorkspaceIds: progress.affectedWorkspaceIds
        )
    }

    private func enumerateFullRescan(
        scope: RescanScope,
        nativeSpaceEvidence: NativeSpaceRescanEvidence,
        preservingPIDsByWindowId: [Int: pid_t],
        entriesAtStart: [WindowState],
        controller: WMController
    ) async throws -> AXManager.FullRescanEnumerationSnapshot {
        if let snapshot = fullRescanEnumerationSnapshotForTests {
            return snapshot
        } else {
            return try await controller.axManager.fullRescanEnumerationSnapshot(
                scope: scope,
                resolvedTargetPIDs: nativeSpaceEvidence.resolvedPIDs.union(
                    scope.nativeSpaceWindowIdsByPID.keys
                ),
                resolvedTargetWindowIds: nativeSpaceEvidence.windowIds.union(
                    scope.nativeSpaceWindowIds
                ),
                supplementalWindowServerInfoByWindowId: nativeSpaceEvidence.windowServerInfoByWindowId,
                preservingPIDsByWindowId: preservingPIDsByWindowId,
                identityDependencyPIDsByWindowId: controller.axEventHandler
                    .fullRescanIdentityDependencyPIDsByWindowId(entries: entriesAtStart),
                requiresTitleForApp: {
                    controller.windowRuleEngine.requiresTitle(for: $0, appName: $1)
                }
            )
        }
    }

    private func initialFullRescanProgress(
        removalPayloads: [WindowRemovalPayload],
        scope: RescanScope,
        entriesAtStart: [WindowState]
    ) -> FullRescanProgress {
        var progress = FullRescanProgress(affectedWorkspaceIds: Set(removalPayloads.map(\.workspaceId)))
        if case let .targeted(appPIDs, _, nativeSpaceWindowIdsByPID) = scope {
            for entry in entriesAtStart
                where appPIDs.contains(entry.pid)
                || nativeSpaceWindowIdsByPID[entry.pid]?.contains(entry.windowId) == true
            {
                progress.affectedWorkspaceIds.insert(entry.workspaceId)
            }
        }
        return progress
    }

    private func validateFullRescanMutation(_ seq: UInt64, controller: WMController) throws {
        try Task.checkCancellation()
        guard controller.workspaceManager.isSeqEpochCurrent(seq, domains: .layoutCommit) else {
            throw CancellationError()
        }
    }
}
