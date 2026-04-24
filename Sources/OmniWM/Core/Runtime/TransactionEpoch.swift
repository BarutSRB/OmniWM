// SPDX-License-Identifier: GPL-2.0-only
import Foundation

// Monotonic, process-scoped identifier assigned by `WMRuntime` to every
// transaction produced through the authoritative transaction entrypoint.
// Carried on `ReconcileTxn` and on any `WMEffectPlan` emitted by that
// transaction so downstream effect runners and confirmation events can tell
// which transaction they belong to. Used by `WMEffectRunner` to reject
// confirmations whose transaction has been superseded.
//
// Epochs start at 1; `.invalid` (0) is reserved for fixtures and for
// transactions that have not been stamped yet.
struct TransactionEpoch: Hashable, Comparable, Sendable, CustomStringConvertible {
    let value: UInt64

    static let invalid = TransactionEpoch(value: 0)

    init(value: UInt64) {
        self.value = value
    }

    var isValid: Bool {
        value != 0
    }

    static func < (lhs: TransactionEpoch, rhs: TransactionEpoch) -> Bool {
        lhs.value < rhs.value
    }

    var description: String {
        "txn#\(value)"
    }
}

// Monotonic, process-scoped identifier assigned to each `WMEffect` produced
// by the runtime. Unique across all plans emitted by a single runtime.
// Confirmation events reference the originating effect epoch so the runner
// can drop stale confirmations after the corresponding effect has been
// superseded.
struct EffectEpoch: Hashable, Comparable, Sendable, CustomStringConvertible {
    let value: UInt64

    static let invalid = EffectEpoch(value: 0)

    init(value: UInt64) {
        self.value = value
    }

    var isValid: Bool {
        value != 0
    }

    static func < (lhs: EffectEpoch, rhs: EffectEpoch) -> Bool {
        lhs.value < rhs.value
    }

    var description: String {
        "fx#\(value)"
    }
}
