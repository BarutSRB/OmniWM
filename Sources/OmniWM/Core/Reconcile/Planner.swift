// SPDX-License-Identifier: GPL-2.0-only
import Foundation

struct Planner {
    func plan(
        event: WMEvent,
        existingEntry: WindowModel.Entry?,
        currentSnapshot: ReconcileSnapshot,
        monitors: [Monitor],
        persistedHydration: PersistedHydrationMutation? = nil
    ) -> ActionPlan {
        StateReducer.reduce(
            event: event,
            existingEntry: existingEntry,
            currentSnapshot: currentSnapshot,
            monitors: monitors,
            persistedHydration: persistedHydration
        )
    }
}
