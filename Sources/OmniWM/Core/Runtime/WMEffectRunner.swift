// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import OSLog

// Runtime-owned serial executor for `WMEffectPlan`s.
//
// Responsibilities:
// - Apply effects in order, on the main actor.
// - Reject entire plans whose `transactionEpoch` has been superseded
//   (`highestObservedTransactionEpoch`).
// - Route `commitWorkspaceTransition` post-layout firings as declarative
//   follow-ups, and drop post-layout firings whose effect/transaction epoch
//   has been superseded by a newer plan.
//
// For Phase 01 Milestone A the runner serves as a compatibility queue:
// its effect handlers delegate to existing services. Later phases tighten
// the contract (e.g. promoting post-layout firings into explicit
// confirmation `WMEvent`s that flow through the transaction path).
@MainActor
protocol WMEffectPlatform: AnyObject {
    func hideKeyboardFocusBorder(reason: String)
    func saveWorkspaceViewport(for workspaceId: WorkspaceDescriptor.ID)
    @discardableResult
    func activateTargetWorkspace(
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID
    ) -> Bool
    func setInteractionMonitor(monitorId: Monitor.ID)
    func syncMonitorsToNiri()
    func stopScrollAnimation(monitorId: Monitor.ID)
    func applyWorkspaceSessionPatch(
        workspaceId: WorkspaceDescriptor.ID,
        rememberedFocusToken: WindowToken?
    )
    func commitWorkspaceTransition(
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        postAction: @escaping @MainActor () -> Void
    )
    func focusWindow(_ token: WindowToken)
    func clearManagedFocusAfterEmptyWorkspaceTransition()
}

@MainActor
final class WMEffectRunner {
    struct ApplyOutcome: Equatable {
        // The effects the runner invoked, in order.
        var appliedEffects: [WMEffect]
        // Rejected effects paired with the reason they were dropped.
        var rejectedEffects: [Rejection]
        // Non-nil when the runner stopped applying effects early because a
        // required prerequisite returned failure (e.g. activating the
        // target workspace).
        var haltReason: HaltReason?

        struct Rejection: Equatable {
            let effect: WMEffect
            let reason: RejectionReason
        }

        enum RejectionReason: Equatable {
            case planSuperseded
            case planEmpty
        }

        enum HaltReason: Equatable {
            case activateTargetWorkspaceFailed(
                workspaceId: WorkspaceDescriptor.ID,
                monitorId: Monitor.ID
            )
        }
    }

    private let platform: WMEffectPlatform
    private let log = Logger(subsystem: "com.omniwm.core", category: "WMEffectRunner")

    // High-water mark of transaction epochs the runner has accepted. Any
    // plan whose `transactionEpoch` is strictly less than this is rejected
    // as superseded.
    private(set) var highestAcceptedTransactionEpoch: TransactionEpoch = .invalid

    init(platform: WMEffectPlatform) {
        self.platform = platform
    }

    @discardableResult
    func apply(_ plan: WMEffectPlan) -> ApplyOutcome {
        if plan.isEmpty {
            return .init(
                appliedEffects: [],
                rejectedEffects: [],
                haltReason: nil
            )
        }

        if plan.transactionEpoch < highestAcceptedTransactionEpoch {
            let txnValue = plan.transactionEpoch.value
            let highValue = highestAcceptedTransactionEpoch.value
            let effectCount = plan.effects.count
            log.debug("plan_superseded txn=\(txnValue) high=\(highValue) effects=\(effectCount)")
            return .init(
                appliedEffects: [],
                rejectedEffects: plan.effects.map {
                    .init(effect: $0, reason: .planSuperseded)
                },
                haltReason: nil
            )
        }

        highestAcceptedTransactionEpoch = plan.transactionEpoch

        var applied: [WMEffect] = []
        var halt: ApplyOutcome.HaltReason?
        applied.reserveCapacity(plan.effects.count)

        for effect in plan.effects {
            if let reason = invoke(effect, transactionEpoch: plan.transactionEpoch) {
                halt = reason
                applied.append(effect)
                break
            }
            applied.append(effect)
        }

        return .init(
            appliedEffects: applied,
            rejectedEffects: [],
            haltReason: halt
        )
    }

    // Returns a halt reason iff the effect short-circuits the plan.
    private func invoke(
        _ effect: WMEffect,
        transactionEpoch: TransactionEpoch
    ) -> ApplyOutcome.HaltReason? {
        switch effect {
        case let .hideKeyboardFocusBorder(reason, _):
            platform.hideKeyboardFocusBorder(reason: reason)
            return nil

        case let .saveWorkspaceViewports(workspaceIds, _):
            for workspaceId in workspaceIds {
                platform.saveWorkspaceViewport(for: workspaceId)
            }
            return nil

        case let .activateTargetWorkspace(workspaceId, monitorId, _):
            let activated = platform.activateTargetWorkspace(
                workspaceId: workspaceId,
                monitorId: monitorId
            )
            if !activated {
                return .activateTargetWorkspaceFailed(
                    workspaceId: workspaceId,
                    monitorId: monitorId
                )
            }
            return nil

        case let .setInteractionMonitor(monitorId, _):
            platform.setInteractionMonitor(monitorId: monitorId)
            return nil

        case .syncMonitorsToNiri:
            platform.syncMonitorsToNiri()
            return nil

        case let .stopScrollAnimation(monitorId, _):
            platform.stopScrollAnimation(monitorId: monitorId)
            return nil

        case let .applyWorkspaceSessionPatch(workspaceId, rememberedFocusToken, _):
            platform.applyWorkspaceSessionPatch(
                workspaceId: workspaceId,
                rememberedFocusToken: rememberedFocusToken
            )
            return nil

        case let .commitWorkspaceTransition(affectedWorkspaceIds, postAction, effectEpoch):
            platform.commitWorkspaceTransition(
                affectedWorkspaceIds: affectedWorkspaceIds
            ) { [weak self] in
                self?.runPostCommitAction(
                    postAction,
                    effectEpoch: effectEpoch,
                    transactionEpoch: transactionEpoch
                )
            }
            return nil
        }
    }

    // Called once the layout-refresh post-layout closure fires. Drops the
    // declared post-action if a newer transaction has been committed since
    // this effect was issued.
    private func runPostCommitAction(
        _ action: WMEffect.PostWorkspaceTransitionAction,
        effectEpoch: EffectEpoch,
        transactionEpoch: TransactionEpoch
    ) {
        guard transactionEpoch >= highestAcceptedTransactionEpoch else {
            let fxValue = effectEpoch.value
            let txnValue = transactionEpoch.value
            let highValue = highestAcceptedTransactionEpoch.value
            log.debug("post_commit_superseded fx=\(fxValue) txn=\(txnValue) high=\(highValue)")
            return
        }

        switch action {
        case .none:
            return

        case let .focusWindow(token):
            platform.focusWindow(token)

        case .clearManagedFocusAfterEmptyWorkspaceTransition:
            platform.clearManagedFocusAfterEmptyWorkspaceTransition()
        }
    }
}
