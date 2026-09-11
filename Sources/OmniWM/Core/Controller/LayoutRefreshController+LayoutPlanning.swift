// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension LayoutRefreshController {
    func buildWorkspacePlansInBatch(_ build: () -> [WorkspaceLayoutPlan]) -> [WorkspaceLayoutPlan] {
        guard let controller else { return [] }
        return controller.withRuntimeFrameJobCancellationSuppressed {
            controller.workspaceManager.withBatchedLayoutBuild(build)
        }
    }

    func buildRelayoutEffectPlan(
        useScrollAnimationPath: Bool,
        recoverFocus: Bool,
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        emptyScopeUsesActiveWorkspaces: Bool = true
    ) -> EffectPlan {
        guard let controller else { return .init() }

        let activeWorkspaceIds = currentActiveWorkspaceIds()
        let layoutWorkspaceIds = affectedWorkspaceIds.isEmpty && emptyScopeUsesActiveWorkspaces
            ? activeWorkspaceIds
            : liveLayoutWorkspaceIds(affectedWorkspaceIds, controller: controller)
        if !affectedWorkspaceIds.isEmpty || !emptyScopeUsesActiveWorkspaces,
           layoutWorkspaceIds.isEmpty
        {
            var effects = EffectPlanEffects()
            effects.visibility = .init()
            return EffectPlan(effects: effects)
        }
        let (niriWorkspaces, dwindleWorkspaces) = partitionWorkspacesByLayoutType(layoutWorkspaceIds)

        let workspacePlans = buildWorkspacePlansInBatch {
            var plans: [WorkspaceLayoutPlan] = []
            plans.reserveCapacity(niriWorkspaces.count + dwindleWorkspaces.count)
            if !niriWorkspaces.isEmpty {
                plans.append(contentsOf: self.niriHandler.layoutWithNiriEngine(
                    activeWorkspaces: niriWorkspaces,
                    useScrollAnimationPath: useScrollAnimationPath
                ))
            }
            if !dwindleWorkspaces.isEmpty {
                plans.append(
                    contentsOf: self.dwindleHandler.layoutWithDwindleEngine(activeWorkspaces: dwindleWorkspaces)
                )
            }
            return plans
        }

        var effects = EffectPlanEffects()
        effects.visibility = .init()

        if recoverFocus,
           let focusedWorkspaceId = controller.activeWorkspace()?.id,
           !controller.workspaceManager.hasPendingNativeFullscreenTransition(in: focusedWorkspaceId),
           !controller.shouldSuppressManagedFocusRecovery,
           layoutWorkspaceIds.contains(focusedWorkspaceId)
        {
            effects.focusValidationWorkspaceIds = [focusedWorkspaceId]
        }

        return EffectPlan(workspacePlans: workspacePlans, effects: effects)
    }

    func buildWindowRemovalEffectPlan(
        payloads: [WindowRemovalPayload]
    ) -> EffectPlan {
        guard let controller else { return .init() }

        var dwindleWorkspaces: Set<WorkspaceDescriptor.ID> = []
        var focusedWorkspacesToRecover: Set<WorkspaceDescriptor.ID> = []
        var workspacesAllowingPreferredRecovery: Set<WorkspaceDescriptor.ID> = []
        let niriRemovalSeeds = makeNiriRemovalSeeds(from: payloads)

        for payload in payloads {
            switch payload.layoutType {
            case .dwindle:
                dwindleWorkspaces.insert(payload.workspaceId)
            case .niri,
                 .defaultLayout:
                break
            }

            if payload.shouldRecoverFocus {
                focusedWorkspacesToRecover.insert(payload.workspaceId)
            }
            if payload.allowsPreferredRecoveryToken {
                workspacesAllowingPreferredRecovery.insert(payload.workspaceId)
            }
        }

        let workspacePlans = buildWorkspacePlansInBatch {
            var plans: [WorkspaceLayoutPlan] = []
            plans.reserveCapacity(dwindleWorkspaces.count + niriRemovalSeeds.count)
            if !niriRemovalSeeds.isEmpty {
                plans.append(contentsOf: self.niriHandler.layoutWithNiriEngine(
                    activeWorkspaces: Set(niriRemovalSeeds.keys),
                    useScrollAnimationPath: true,
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

        let effects = windowRemovalFocusEffects(
            workspacePlans: workspacePlans,
            focusedWorkspacesToRecover: focusedWorkspacesToRecover,
            workspacesAllowingPreferredRecovery: workspacesAllowingPreferredRecovery,
            controller: controller
        )

        return EffectPlan(workspacePlans: workspacePlans, effects: effects)
    }

    func partitionWorkspacesByLayoutType(
        _ workspaces: Set<WorkspaceDescriptor.ID>
    ) -> (niri: Set<WorkspaceDescriptor.ID>, dwindle: Set<WorkspaceDescriptor.ID>) {
        guard let controller else { return ([], []) }

        var niriWorkspaces: Set<WorkspaceDescriptor.ID> = []
        var dwindleWorkspaces: Set<WorkspaceDescriptor.ID> = []

        for wsId in workspaces {
            guard let ws = controller.workspaceManager.descriptor(for: wsId) else {
                continue
            }
            let layoutType = controller.settings.workspaces.layoutType(for: ws.name)
            switch layoutType {
            case .dwindle:
                dwindleWorkspaces.insert(wsId)
            case .niri,
                 .defaultLayout:
                niriWorkspaces.insert(wsId)
            }
        }

        return (niriWorkspaces, dwindleWorkspaces)
    }

    func liveLayoutWorkspaceIds(
        _ workspaceIds: Set<WorkspaceDescriptor.ID>,
        controller: WMController
    ) -> Set<WorkspaceDescriptor.ID> {
        var liveWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        liveWorkspaceIds.reserveCapacity(workspaceIds.count)
        for workspaceId in workspaceIds
            where controller.workspaceManager.descriptor(for: workspaceId) != nil
            && controller.workspaceManager.monitor(for: workspaceId) != nil
        {
            liveWorkspaceIds.insert(workspaceId)
        }
        return liveWorkspaceIds
    }

    func currentActiveWorkspaceIds() -> Set<WorkspaceDescriptor.ID> {
        guard let controller else { return [] }

        var activeWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        for monitor in controller.workspaceManager.monitors {
            if let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
                activeWorkspaceIds.insert(workspace.id)
            }
        }
        return activeWorkspaceIds
    }

    func buildVisibilityEffectPlan(
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        recoverFocus: Bool
    ) -> EffectPlan {
        buildRelayoutEffectPlan(
            useScrollAnimationPath: false,
            recoverFocus: recoverFocus,
            affectedWorkspaceIds: affectedWorkspaceIds,
            emptyScopeUsesActiveWorkspaces: false
        )
    }

    private func windowRemovalFocusEffects(
        workspacePlans: [WorkspaceLayoutPlan],
        focusedWorkspacesToRecover: Set<WorkspaceDescriptor.ID>,
        workspacesAllowingPreferredRecovery: Set<WorkspaceDescriptor.ID>,
        controller: WMController
    ) -> EffectPlanEffects {
        let activeWorkspaceIds = currentActiveWorkspaceIds()
        let focusValidationWorkspaceIds = focusedWorkspacesToRecover
            .intersection(activeWorkspaceIds)
            .filter {
                !controller.workspaceManager.hasPendingNativeFullscreenTransition(in: $0)
                    && !controller.shouldSuppressManagedFocusRecovery
            }
            .sorted { $0.uuidString < $1.uuidString }

        let focusValidationPreferredTokens = workspacePlans.reduce(
            into: [WorkspaceDescriptor.ID: WindowToken]()
        ) { result, plan in
            guard let rememberedFocusToken = plan.sessionPatch.rememberedFocusToken,
                  focusValidationWorkspaceIds.contains(plan.workspaceId),
                  workspacesAllowingPreferredRecovery.contains(plan.workspaceId)
            else {
                return
            }
            result[plan.workspaceId] = rememberedFocusToken
        }

        var effects = EffectPlanEffects()
        effects.visibility = .init()

        effects.focusValidationWorkspaceIds = focusValidationWorkspaceIds
        effects.focusValidationPreferredTokens = focusValidationPreferredTokens

        return effects
    }
}
