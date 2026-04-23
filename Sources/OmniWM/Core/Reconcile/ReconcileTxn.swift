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
}
