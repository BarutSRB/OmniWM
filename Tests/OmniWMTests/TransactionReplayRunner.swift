// SPDX-License-Identifier: GPL-2.0-only
import Foundation

@testable import OmniWM

// Minimal replay driver for the authoritative transaction path.
//
// The driver feeds a sequence of `Step`s (observation events or
// commands) into a `WMRuntime`, captures the committed transactions,
// emitted effect plans, and recorded effect-platform events, and
// exposes them for assertions. It also validates a small set of
// transaction invariants after every step so regressions in epoch
// stamping or ordering surface without each test re-asserting them.
//
// This driver covers Phase 01 Milestone A. Phase 05 expands it into the
// full `VirtualWindowServer` simulator suite described in the rewrite
// plan.
@MainActor
final class TransactionReplayRunner {
    enum Step: Equatable {
        case event(WMEvent)
        case command(WMCommand)
    }

    struct Outcome {
        let step: Step
        let transactionEpoch: TransactionEpoch
        let plan: WMEffectPlan?
        let txn: ReconcileTxn?
        let platformEventsAfter: [RecordingEffectPlatform.Event]
    }

    struct InvariantViolation: Error, Equatable {
        let stepIndex: Int
        let message: String
    }

    private let runtime: WMRuntime
    private let platform: RecordingEffectPlatform
    private(set) var outcomes: [Outcome] = []
    private var lastTransactionEpoch: TransactionEpoch = .invalid

    init(runtime: WMRuntime, platform: RecordingEffectPlatform) {
        self.runtime = runtime
        self.platform = platform
    }

    func replay(_ steps: [Step]) throws {
        for (index, step) in steps.enumerated() {
            let outcome = process(step)
            try validate(outcome: outcome, index: index)
            outcomes.append(outcome)
            lastTransactionEpoch = outcome.transactionEpoch
        }
    }

    private func process(_ step: Step) -> Outcome {
        switch step {
        case let .event(event):
            let beforeCount = platform.events.count
            let txn = runtime.submit(event)
            let delta = Array(platform.events[beforeCount..<platform.events.count])
            return Outcome(
                step: step,
                transactionEpoch: txn.transactionEpoch,
                plan: nil,
                txn: txn,
                platformEventsAfter: delta
            )

        case let .command(command):
            let beforeCount = platform.events.count
            let result = runtime.submit(command: command)
            let delta = Array(platform.events[beforeCount..<platform.events.count])
            return Outcome(
                step: step,
                transactionEpoch: result.transactionEpoch,
                plan: result.plan,
                txn: result.txn,
                platformEventsAfter: delta
            )
        }
    }

    private func validate(outcome: Outcome, index: Int) throws {
        guard outcome.transactionEpoch.isValid else {
            throw InvariantViolation(
                stepIndex: index,
                message: "transaction epoch was not stamped by WMRuntime"
            )
        }
        if lastTransactionEpoch.isValid,
           outcome.transactionEpoch <= lastTransactionEpoch
        {
            throw InvariantViolation(
                stepIndex: index,
                message: "transaction epoch did not strictly increase (\(lastTransactionEpoch) -> \(outcome.transactionEpoch))"
            )
        }
        if let plan = outcome.plan {
            if plan.transactionEpoch != outcome.transactionEpoch {
                throw InvariantViolation(
                    stepIndex: index,
                    message: "effect plan txn epoch mismatch"
                )
            }
            var previous: EffectEpoch = .invalid
            for effect in plan.effects {
                if previous.isValid, !(previous < effect.epoch) {
                    throw InvariantViolation(
                        stepIndex: index,
                        message: "effect epochs must strictly increase within a plan"
                    )
                }
                previous = effect.epoch
            }
        }
    }
}
