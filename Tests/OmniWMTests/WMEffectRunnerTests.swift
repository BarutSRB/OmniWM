// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing

@testable import OmniWM

@Suite(.serialized) struct WMEffectRunnerTests {
    @MainActor
    private func makePlan(
        transactionEpoch: UInt64,
        effects: [WMEffect]
    ) -> WMEffectPlan {
        WMEffectPlan(
            transactionEpoch: TransactionEpoch(value: transactionEpoch),
            effects: effects
        )
    }

    @MainActor
    private let monitorA = Monitor.ID(displayId: 10_001)

    @MainActor
    private let workspaceA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!

    @MainActor
    private let workspaceB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

    @Test @MainActor func emptyPlanIsIgnored() {
        let platform = RecordingEffectPlatform()
        let runner = WMEffectRunner(platform: platform)

        let outcome = runner.apply(.empty)

        #expect(outcome.appliedEffects.isEmpty)
        #expect(outcome.rejectedEffects.isEmpty)
        #expect(platform.events.isEmpty)
        #expect(!runner.highestAcceptedTransactionEpoch.isValid)
    }

    @Test @MainActor func effectsAreAppliedInOrderAndEpochAdvances() {
        let platform = RecordingEffectPlatform()
        let runner = WMEffectRunner(platform: platform)

        let plan = makePlan(
            transactionEpoch: 1,
            effects: [
                .hideKeyboardFocusBorder(reason: "switch workspace", epoch: EffectEpoch(value: 1)),
                .syncMonitorsToNiri(epoch: EffectEpoch(value: 2))
            ]
        )

        let outcome = runner.apply(plan)

        #expect(outcome.appliedEffects.count == 2)
        #expect(outcome.rejectedEffects.isEmpty)
        #expect(outcome.haltReason == nil)
        #expect(platform.events == [
            .hideKeyboardFocusBorder(reason: "switch workspace"),
            .syncMonitorsToNiri
        ])
        #expect(runner.highestAcceptedTransactionEpoch == TransactionEpoch(value: 1))
    }

    @Test @MainActor func planWithSupersededTransactionEpochIsRejectedWholesale() {
        let platform = RecordingEffectPlatform()
        let runner = WMEffectRunner(platform: platform)

        // Accept a newer plan first.
        _ = runner.apply(makePlan(
            transactionEpoch: 5,
            effects: [.syncMonitorsToNiri(epoch: EffectEpoch(value: 1))]
        ))
        #expect(platform.events.count == 1)

        // Now a stale plan arrives. The runner must drop the entire plan.
        let stalePlan = makePlan(
            transactionEpoch: 3,
            effects: [
                .hideKeyboardFocusBorder(reason: "stale", epoch: EffectEpoch(value: 2)),
                .setInteractionMonitor(monitorId: monitorA, epoch: EffectEpoch(value: 3))
            ]
        )
        let staleOutcome = runner.apply(stalePlan)

        #expect(staleOutcome.appliedEffects.isEmpty)
        #expect(staleOutcome.rejectedEffects.count == 2)
        #expect(staleOutcome.rejectedEffects.allSatisfy { $0.reason == .planSuperseded })
        #expect(platform.events.count == 1, "no new events recorded for superseded plan")
        #expect(runner.highestAcceptedTransactionEpoch == TransactionEpoch(value: 5))
    }

    @Test @MainActor func activateFailureHaltsPlanAndReportsReason() {
        let platform = RecordingEffectPlatform()
        platform.activateTargetWorkspaceResult = false
        let runner = WMEffectRunner(platform: platform)

        let plan = makePlan(
            transactionEpoch: 1,
            effects: [
                .hideKeyboardFocusBorder(reason: "switch workspace", epoch: EffectEpoch(value: 1)),
                .activateTargetWorkspace(
                    workspaceId: workspaceA,
                    monitorId: monitorA,
                    epoch: EffectEpoch(value: 2)
                ),
                // Following effects must NOT be applied once activation fails.
                .syncMonitorsToNiri(epoch: EffectEpoch(value: 3))
            ]
        )

        let outcome = runner.apply(plan)

        #expect(outcome.haltReason == .activateTargetWorkspaceFailed(
            workspaceId: workspaceA,
            monitorId: monitorA
        ))
        #expect(outcome.appliedEffects.count == 2)
        #expect(platform.events == [
            .hideKeyboardFocusBorder(reason: "switch workspace"),
            .activateTargetWorkspace(workspaceId: workspaceA, monitorId: monitorA)
        ])
    }

    @Test @MainActor func postCommitActionRunsWhenStillCurrent() {
        let platform = RecordingEffectPlatform()
        let runner = WMEffectRunner(platform: platform)

        let focusToken = WindowToken(pid: 42, windowId: 99)
        let plan = makePlan(
            transactionEpoch: 7,
            effects: [
                .commitWorkspaceTransition(
                    affectedWorkspaceIds: [workspaceA],
                    postAction: .focusWindow(focusToken),
                    epoch: EffectEpoch(value: 1)
                )
            ]
        )

        _ = runner.apply(plan)

        #expect(platform.events == [
            .commitWorkspaceTransition(affectedWorkspaceIds: [workspaceA]),
            .focusWindow(token: focusToken)
        ])
    }

    @Test @MainActor func postCommitActionIsDroppedWhenSupersededBeforeFiring() {
        let platform = RecordingEffectPlatform()
        platform.synchronousPostActions = false
        let runner = WMEffectRunner(platform: platform)

        // First plan registers a post-layout closure.
        let focusToken = WindowToken(pid: 42, windowId: 99)
        _ = runner.apply(makePlan(
            transactionEpoch: 3,
            effects: [
                .commitWorkspaceTransition(
                    affectedWorkspaceIds: [workspaceA],
                    postAction: .focusWindow(focusToken),
                    epoch: EffectEpoch(value: 1)
                )
            ]
        ))
        #expect(platform.pendingPostActionCount == 1)

        // Before the post-layout fires, a newer plan is applied, which
        // advances the runner's high-water mark.
        _ = runner.apply(makePlan(
            transactionEpoch: 5,
            effects: [
                .commitWorkspaceTransition(
                    affectedWorkspaceIds: [workspaceB],
                    postAction: .none,
                    epoch: EffectEpoch(value: 2)
                )
            ]
        ))

        // Now fire the first plan's deferred post-layout. It MUST NOT
        // call `focusWindow` because the transaction it belongs to has
        // been superseded.
        platform.runPendingPostActions()

        let focusEvents = platform.events.filter {
            if case .focusWindow = $0 { true } else { false }
        }
        #expect(focusEvents.isEmpty, "stale post-layout must not focus window")
    }

    @Test @MainActor func idempotentReapplyUsesSameEpoch() {
        let platform = RecordingEffectPlatform()
        let runner = WMEffectRunner(platform: platform)

        let plan = makePlan(
            transactionEpoch: 1,
            effects: [.syncMonitorsToNiri(epoch: EffectEpoch(value: 1))]
        )
        _ = runner.apply(plan)
        _ = runner.apply(plan)

        // The runner does not dedupe identical plans — each invocation
        // of `apply` emits the effects once. Re-applying the same plan
        // at the same epoch is allowed (>= high-water mark) and simply
        // invokes the platform again. This documents the contract.
        #expect(platform.events.count == 2)
        #expect(runner.highestAcceptedTransactionEpoch == TransactionEpoch(value: 1))
    }
}
