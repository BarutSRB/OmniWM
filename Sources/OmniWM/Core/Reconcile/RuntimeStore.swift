// SPDX-License-Identifier: GPL-2.0-only
import Foundation

@MainActor
final class RuntimeStore {
    private let planner: Planner
    private let nowProvider: () -> Date

    init(
        planner: Planner = Planner(),
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.planner = planner
        self.nowProvider = nowProvider
    }

    @discardableResult
    func transact(
        event: WMEvent,
        existingEntry: WindowModel.Entry?,
        monitors: [Monitor],
        persistedHydration: PersistedHydrationMutation? = nil,
        transactionEpoch: TransactionEpoch = .invalid,
        snapshot: () -> ReconcileSnapshot,
        applyPlan: (ActionPlan, WindowToken?) -> ActionPlan
    ) -> ReconcileTxn {
        let currentSnapshot = snapshot()
        let normalizedEvent = EventNormalizer.normalize(
            event: event,
            existingEntry: existingEntry,
            monitors: monitors
        )
        let plan = planner.plan(
            event: normalizedEvent,
            existingEntry: existingEntry,
            currentSnapshot: currentSnapshot,
            monitors: monitors,
            persistedHydration: persistedHydration
        )
        let resolvedPlan = applyPlan(plan, normalizedEvent.token)
        return record(
            event: event,
            normalizedEvent: normalizedEvent,
            plan: resolvedPlan,
            snapshot: snapshot(),
            transactionEpoch: transactionEpoch
        )
    }

    @discardableResult
    func record(
        event: WMEvent,
        normalizedEvent: WMEvent? = nil,
        plan: ActionPlan,
        snapshot: ReconcileSnapshot,
        transactionEpoch: TransactionEpoch = .invalid
    ) -> ReconcileTxn {
        let invariantViolations = InvariantChecks.validate(snapshot: snapshot)
        return ReconcileTxn(
            timestamp: nowProvider(),
            event: event,
            normalizedEvent: normalizedEvent ?? event,
            plan: plan,
            snapshot: snapshot,
            invariantViolations: invariantViolations,
            transactionEpoch: transactionEpoch
        )
    }
}
