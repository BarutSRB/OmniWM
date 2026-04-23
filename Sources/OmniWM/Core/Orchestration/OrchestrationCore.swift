// SPDX-License-Identifier: GPL-2.0-only
enum OrchestrationCore {
    static func step(
        snapshot: OrchestrationSnapshot,
        event: OrchestrationEvent
    ) -> OrchestrationResult {
        OrchestrationKernel.step(snapshot: snapshot, event: event)
    }
}
