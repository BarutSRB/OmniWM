// SPDX-License-Identifier: GPL-2.0-only
import Foundation

// Ordered, inspectable effect plan produced by the authoritative transaction
// path. Stamped with the `TransactionEpoch` of the transaction that emitted
// it; individual effects carry their own `EffectEpoch` (monotonic across
// plans, owned by `WMRuntime`).
//
// `WMEffectPlan` does NOT carry `nextEffectEpoch` or any closures. Effect
// epoch allocation lives on the runtime/transaction side; post-effect
// follow-ups are modeled declaratively on `WMEffect` so a plan can be
// serialized, diffed, and replayed by transcript tests.
struct WMEffectPlan: Equatable {
    let transactionEpoch: TransactionEpoch
    let effects: [WMEffect]

    static let empty = WMEffectPlan(
        transactionEpoch: .invalid,
        effects: []
    )

    var isEmpty: Bool { effects.isEmpty }

    init(
        transactionEpoch: TransactionEpoch,
        effects: [WMEffect]
    ) {
        self.transactionEpoch = transactionEpoch
        self.effects = effects
    }

    var summary: String {
        if effects.isEmpty {
            return "plan \(transactionEpoch) empty"
        }
        let joined = effects
            .map { "\($0.kind)@\($0.epoch.value)" }
            .joined(separator: ",")
        return "plan \(transactionEpoch) effects=[\(joined)]"
    }
}
