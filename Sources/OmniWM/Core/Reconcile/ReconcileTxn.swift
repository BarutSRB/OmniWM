// SPDX-License-Identifier: GPL-2.0-only
import Foundation

struct ReconcileInvariantViolation: Equatable {
    let code: String
    let message: String
}

struct ReconcileTxn: Equatable {
    let timestamp: Date
    let event: WMEvent
    let normalizedEvent: WMEvent
    let plan: ActionPlan
    let snapshot: ReconcileSnapshot
    let invariantViolations: [ReconcileInvariantViolation]
    // Transaction epoch stamped by the authoritative transaction
    // entrypoint. `.invalid` indicates the txn was produced by a
    // direct-mutation path that has not yet been migrated to
    // `WMRuntime.submit(...)` — see `docs/RELIABILITY-MIGRATION.md` for
    // the open inventory.
    let transactionEpoch: TransactionEpoch

    init(
        timestamp: Date,
        event: WMEvent,
        normalizedEvent: WMEvent,
        plan: ActionPlan,
        snapshot: ReconcileSnapshot,
        invariantViolations: [ReconcileInvariantViolation],
        transactionEpoch: TransactionEpoch = .invalid
    ) {
        self.timestamp = timestamp
        self.event = event
        self.normalizedEvent = normalizedEvent
        self.plan = plan
        self.snapshot = snapshot
        self.invariantViolations = invariantViolations
        self.transactionEpoch = transactionEpoch
    }
}
