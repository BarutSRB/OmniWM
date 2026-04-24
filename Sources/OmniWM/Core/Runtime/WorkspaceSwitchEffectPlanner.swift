// SPDX-License-Identifier: GPL-2.0-only
import Foundation

// Translates `WMCommand.WorkspaceSwitchCommand` values into an ordered
// `WMEffectPlan` by consulting the pure `WorkspaceNavigationKernel`.
//
// The translator owns the ordering of effects (previously open-coded in
// `WorkspaceNavigationHandler.applySwitchPlan`). By constructing it here
// and exposing only typed effects, the transaction path is inspectable
// and replay-testable without the handler having to run.
@MainActor
enum WorkspaceSwitchEffectPlanner {
    struct Inputs {
        let controller: WMController
        let transactionEpoch: TransactionEpoch
        // Supplier of fresh, monotonically-increasing `EffectEpoch`s,
        // owned by the runtime.
        let allocateEffectEpoch: () -> EffectEpoch
    }

    static func makePlan(
        for command: WMCommand.WorkspaceSwitchCommand,
        inputs: Inputs
    ) -> WMEffectPlan {
        let intent = makeIntent(for: command, controller: inputs.controller)
        let kernelPlan = WorkspaceNavigationKernel.plan(
            .capture(controller: inputs.controller, intent: intent)
        )
        guard kernelPlan.outcome == .execute else {
            return WMEffectPlan(
                transactionEpoch: inputs.transactionEpoch,
                effects: []
            )
        }
        let hideReason = hideBorderReason(for: command)
        let effects = assembleEffects(
            from: kernelPlan,
            hideReason: hideReason,
            allocateEffectEpoch: inputs.allocateEffectEpoch
        )
        return WMEffectPlan(
            transactionEpoch: inputs.transactionEpoch,
            effects: effects
        )
    }

    private static func makeIntent(
        for command: WMCommand.WorkspaceSwitchCommand,
        controller: WMController
    ) -> WorkspaceNavigationKernel.Intent {
        switch command {
        case let .explicit(rawWorkspaceID):
            return .init(
                operation: .switchWorkspaceExplicit,
                currentWorkspaceId: controller.activeWorkspace()?.id,
                targetWorkspaceId: controller.workspaceManager.workspaceId(
                    for: rawWorkspaceID,
                    createIfMissing: false
                )
            )

        case let .relative(isNext, wrapAround):
            return .init(
                operation: .switchWorkspaceRelative,
                direction: isNext ? .right : .left,
                currentWorkspaceId: controller.activeWorkspace()?.id,
                currentMonitorId: interactionMonitorId(for: controller),
                wrapAround: wrapAround
            )
        }
    }

    private static func hideBorderReason(
        for command: WMCommand.WorkspaceSwitchCommand
    ) -> String {
        switch command {
        case .explicit:
            "switch workspace"
        case .relative:
            "switch workspace relative"
        }
    }

    private static func interactionMonitorId(
        for controller: WMController
    ) -> Monitor.ID? {
        controller.workspaceManager.interactionMonitorId
            ?? controller.monitorForInteraction()?.id
    }

    // Assemble the ordered effect list mirroring
    // `WorkspaceNavigationHandler.applySwitchPlan`. Keeping the shape of
    // the emitted plan identical to the legacy call order is the
    // compatibility contract for Phase 01 Milestone A.
    private static func assembleEffects(
        from plan: WorkspaceNavigationKernel.Plan,
        hideReason: String,
        allocateEffectEpoch: () -> EffectEpoch
    ) -> [WMEffect] {
        var effects: [WMEffect] = []

        if plan.shouldHideFocusBorder {
            effects.append(.hideKeyboardFocusBorder(
                reason: hideReason,
                epoch: allocateEffectEpoch()
            ))
        }

        if !plan.saveWorkspaceIds.isEmpty {
            effects.append(.saveWorkspaceViewports(
                workspaceIds: plan.saveWorkspaceIds,
                epoch: allocateEffectEpoch()
            ))
        }

        if let targetMonitorId = plan.targetMonitorId {
            if plan.shouldActivateTargetWorkspace,
               let targetWorkspaceId = plan.targetWorkspaceId
            {
                effects.append(.activateTargetWorkspace(
                    workspaceId: targetWorkspaceId,
                    monitorId: targetMonitorId,
                    epoch: allocateEffectEpoch()
                ))
            } else if plan.shouldSetInteractionMonitor {
                effects.append(.setInteractionMonitor(
                    monitorId: targetMonitorId,
                    epoch: allocateEffectEpoch()
                ))
            }
        }

        if plan.shouldSyncMonitorsToNiri {
            effects.append(.syncMonitorsToNiri(
                epoch: allocateEffectEpoch()
            ))
        }

        if plan.shouldCommitWorkspaceTransition {
            appendCommitEffects(
                plan: plan,
                into: &effects,
                allocateEffectEpoch: allocateEffectEpoch
            )
        }

        return effects
    }

    private static func appendCommitEffects(
        plan: WorkspaceNavigationKernel.Plan,
        into effects: inout [WMEffect],
        allocateEffectEpoch: () -> EffectEpoch
    ) {
        switch plan.focusAction {
        case .workspaceHandoff:
            appendWorkspaceCommit(
                plan: plan,
                stopScrollOnTargetMonitor: true,
                into: &effects,
                allocateEffectEpoch: allocateEffectEpoch
            )

        case .resolveTargetIfPresent, .clearManagedFocus:
            appendWorkspaceCommit(
                plan: plan,
                stopScrollOnTargetMonitor: false,
                into: &effects,
                allocateEffectEpoch: allocateEffectEpoch
            )

        case .subject, .recoverSource, .none:
            // Focus actions emitted by move-window / column-transfer /
            // miscellaneous paths are out of scope for Phase 01
            // Milestone A (see `docs/RELIABILITY-MIGRATION.md`). These
            // commands never reach this planner today; the branch is
            // kept exhaustive so a future command that returns one of
            // these actions fails loudly in review rather than being
            // silently dropped.
            return
        }
    }

    private static func appendWorkspaceCommit(
        plan: WorkspaceNavigationKernel.Plan,
        stopScrollOnTargetMonitor: Bool,
        into effects: inout [WMEffect],
        allocateEffectEpoch: () -> EffectEpoch
    ) {
        if stopScrollOnTargetMonitor, let targetMonitorId = plan.targetMonitorId {
            effects.append(.stopScrollAnimation(
                monitorId: targetMonitorId,
                epoch: allocateEffectEpoch()
            ))
        }
        if let targetWorkspaceId = plan.targetWorkspaceId,
           let resolvedFocusToken = plan.resolvedFocusToken
        {
            effects.append(.applyWorkspaceSessionPatch(
                workspaceId: targetWorkspaceId,
                rememberedFocusToken: resolvedFocusToken,
                epoch: allocateEffectEpoch()
            ))
        }
        let postAction = makePostAction(plan: plan)
        effects.append(.commitWorkspaceTransition(
            affectedWorkspaceIds: plan.affectedWorkspaceIds,
            postAction: postAction,
            epoch: allocateEffectEpoch()
        ))
    }

    private static func makePostAction(
        plan: WorkspaceNavigationKernel.Plan
    ) -> WMEffect.PostWorkspaceTransitionAction {
        if let resolvedFocusToken = plan.resolvedFocusToken {
            return .focusWindow(resolvedFocusToken)
        }
        if plan.focusAction == .clearManagedFocus {
            return .clearManagedFocusAfterEmptyWorkspaceTransition
        }
        return .none
    }
}
