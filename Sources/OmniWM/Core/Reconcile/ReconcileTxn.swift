// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct ReconcileInvariantViolation: Equatable {
    let code: String
    let message: String

    var traceNote: String {
        "invariant[\(code)]=\(message)"
    }
}

struct ReconcileTxn: Equatable {
    let timestamp: Date
    let event: WMEvent
    let normalizedEvent: WMEvent
    let plan: ActionPlan
    let snapshot: ReconcileSnapshot
    let invariantViolations: [ReconcileInvariantViolation]
}
