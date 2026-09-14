// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

extension InteractionMonitorWriteRecorder {
    @MainActor
    func recordFocusTransition(
        previousInteraction: Monitor.ID?,
        previousPrevious: Monitor.ID?,
        to next: FocusSessionSnapshot,
        event: WMEvent?
    ) {
        let interactionChanged = previousInteraction != next.interactionMonitorId
        let previousChanged = previousPrevious != next.previousInteractionMonitorId
        guard interactionChanged || previousChanged else { return }
        let reason = event?.summary ?? "unknown"
        if interactionChanged {
            record(
                field: .interaction,
                oldValue: previousInteraction,
                newValue: next.interactionMonitorId,
                reason: reason
            )
        }
        if previousChanged {
            record(
                field: .previous,
                oldValue: previousPrevious,
                newValue: next.previousInteractionMonitorId,
                reason: reason
            )
        }
    }
}
