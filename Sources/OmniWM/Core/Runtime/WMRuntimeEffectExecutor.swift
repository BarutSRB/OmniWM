// SPDX-License-Identifier: GPL-2.0-only
import Foundation

@MainActor
final class WMRuntimeEffectExecutor: EffectExecutor {
    func execute(
        _ result: OrchestrationResult,
        on controller: WMController,
        context: WMRuntimeEffectContext
    ) {
        switch context {
        case .focusRequest:
            controller.applyRuntimeFocusRequestResult(result)

        case let .activationObserved(observedAXRef, managedEntry, source, confirmRequest):
            controller.axEventHandler.applyActivationOrchestrationResult(
                result,
                observedAXRef: observedAXRef,
                managedEntry: managedEntry,
                source: source,
                confirmRequest: confirmRequest
            )

        case .refresh:
            controller.layoutRefreshController.applyRuntimeRefreshResult(result)
        }
    }
}
