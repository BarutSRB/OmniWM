// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension LayoutRefreshController {
    func buildFullRescanLayoutPlan(
        _ request: FullRescanLayoutRequest,
        context: FullRescanMutationContext,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>
    ) -> EffectPlan {
        let removalPayloads = request.removalPayloads
        let postLayoutActions = request.postLayoutActions
        let niriRemovalSeeds = makeNiriRemovalSeeds(from: removalPayloads)
        let layoutWorkspaceIds = fullRescanLayoutWorkspaceIds(
            request,
            context: context,
            affectedWorkspaceIds: affectedWorkspaceIds
        )
        let (niriWorkspaces, dwindleWorkspaces) = partitionWorkspacesByLayoutType(layoutWorkspaceIds)

        let workspacePlans = buildWorkspacePlansInBatch {
            var plans: [WorkspaceLayoutPlan] = []
            plans.reserveCapacity(niriWorkspaces.count + dwindleWorkspaces.count)
            if !niriWorkspaces.isEmpty {
                plans.append(contentsOf: self.niriHandler.layoutWithNiriEngine(
                    activeWorkspaces: niriWorkspaces,
                    useScrollAnimationPath: false,
                    removalSeeds: niriRemovalSeeds
                ))
            }
            if !dwindleWorkspaces.isEmpty {
                plans.append(
                    contentsOf: self.dwindleHandler.layoutWithDwindleEngine(activeWorkspaces: dwindleWorkspaces)
                )
            }
            return plans
        }

        let effects = fullRescanCompletionEffects(context: context)

        if postLayoutActions.isEmpty {
            return EffectPlan(workspacePlans: workspacePlans, effects: effects)
        }
        let forwardedPostLayoutActions = forwardedFullRescanActions(
            request,
            layoutWorkspaceIds: layoutWorkspaceIds,
            context: context
        )
        return EffectPlan(
            workspacePlans: workspacePlans,
            effects: effects,
            postLayoutActions: forwardedPostLayoutActions
        )
    }

    private func fullRescanLayoutWorkspaceIds(
        _ request: FullRescanLayoutRequest,
        context: FullRescanMutationContext,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>
    ) -> Set<WorkspaceDescriptor.ID> {
        let controller = context.controller
        let scope = context.scope
        let removalPayloads = request.removalPayloads
        let relayoutWorkspaceIds = request.relayoutWorkspaceIds
        let activeWorkspaceIds = currentActiveWorkspaceIds()
        let scanLayoutWorkspaceIds = switch scope {
        case .all:
            activeWorkspaceIds.union(removalPayloads.map(\.workspaceId))
        case .targeted:
            activeWorkspaceIds.intersection(affectedWorkspaceIds)
                .union(removalPayloads.map(\.workspaceId))
        }
        let explicitRelayoutWorkspaceIds = if let relayoutWorkspaceIds {
            relayoutWorkspaceIds.isEmpty
                ? activeWorkspaceIds
                : liveLayoutWorkspaceIds(relayoutWorkspaceIds, controller: controller)
        } else {
            Set<WorkspaceDescriptor.ID>()
        }
        let layoutWorkspaceIds = scanLayoutWorkspaceIds.union(explicitRelayoutWorkspaceIds)
        return layoutWorkspaceIds
    }

    private func fullRescanCompletionEffects(
        context: FullRescanMutationContext
    ) -> EffectPlanEffects {
        let controller = context.controller
        let focusValidationWorkspaceId = context.focusedWorkspaceId
        var effects = EffectPlanEffects()
        effects.visibility = .init()

        if let focusValidationWorkspaceId,
           !controller.workspaceManager.hasPendingNativeFullscreenTransition(in: focusValidationWorkspaceId),
           !controller.shouldSuppressManagedFocusRecovery
        {
            effects.focusValidationWorkspaceIds = [focusValidationWorkspaceId]
        }
        effects.suppressWindowActivation = false
        effects.markInitialRefreshComplete = true
        effects.drainDeferredCreatedWindows = true
        effects.subscribeManagedWindows = true

        return effects
    }

    private func forwardedFullRescanActions(
        _ request: FullRescanLayoutRequest,
        layoutWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        context: FullRescanMutationContext
    ) -> [RefreshPostLayoutAction] {
        let controller = context.controller
        let postLayoutActions = request.postLayoutActions
        let postLayoutActionWorkspacesCurrentAtMutation = request.postLayoutActionWorkspacesCurrentAtMutation
        let acceptedSeqs = Dictionary(
            uniqueKeysWithValues: layoutWorkspaceIds.map {
                (
                    $0,
                    AcceptedSeq(
                        after: controller.workspaceManager.worldSeq,
                        domains: .layoutCommit.union(.focusCommit)
                    )
                )
            }
        )
        let forwardedPostLayoutActions = zip(
            postLayoutActions,
            postLayoutActionWorkspacesCurrentAtMutation
        ).map { action, currentAtMutation in
            action.forwarded(
                by: acceptedSeqs,
                currentAtEntry: currentAtMutation
            )
        }
        return forwardedPostLayoutActions
    }
}
