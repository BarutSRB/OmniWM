// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct ReconcileTraceRecord: Equatable {
    let sequence: UInt64
    let timestamp: Date
    let event: WMEvent
    let normalizedEvent: WMEvent
    let plan: ActionPlan
    let snapshot: ReconcileSnapshot
    let invariantViolations: [ReconcileInvariantViolation]
}

@MainActor
final class ReconcileTraceRecorder {
    private static let defaultLimit = 256

    private let limit: Int
    private var nextSequence: UInt64 = 1
    private var records: [ReconcileTraceRecord] = []

    init(limit: Int = defaultLimit) {
        self.limit = max(1, limit)
    }

    func append(
        event: WMEvent,
        normalizedEvent: WMEvent? = nil,
        plan: ActionPlan,
        snapshot: ReconcileSnapshot,
        invariantViolations: [ReconcileInvariantViolation] = [],
        timestamp: Date = Date()
    ) {
        let record = ReconcileTraceRecord(
            sequence: nextSequence,
            timestamp: timestamp,
            event: event,
            normalizedEvent: normalizedEvent ?? event,
            plan: plan,
            snapshot: snapshot,
            invariantViolations: invariantViolations
        )
        nextSequence += 1
        if records.count == limit {
            records.removeFirst()
        }
        records.append(record)
    }

    func append(transaction: ReconcileTxn) {
        append(
            event: transaction.event,
            normalizedEvent: transaction.normalizedEvent,
            plan: transaction.plan,
            snapshot: transaction.snapshot,
            invariantViolations: transaction.invariantViolations,
            timestamp: transaction.timestamp
        )
    }

    func snapshot() -> [ReconcileTraceRecord] {
        records
    }

    func reset() {
        records.removeAll(keepingCapacity: true)
        nextSequence = 1
    }
}
