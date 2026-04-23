// SPDX-License-Identifier: GPL-2.0-only
import Testing

@testable import OmniWM

@Suite struct RefreshSchedulerTests {
    @Test @MainActor func scheduledRefreshesAllocateMonotonicCycleIds() {
        let scheduler = RefreshScheduler()

        let first = scheduler.makeScheduledRefresh(
            kind: .fullRescan,
            reason: .startup
        )
        let second = scheduler.makeScheduledRefresh(
            kind: .relayout,
            reason: .gapsChanged
        )

        #expect(first.cycleId == 1)
        #expect(second.cycleId == 2)
    }

    @Test @MainActor func synchronizeCycleCounterAdvancesPastObservedRefreshes() {
        let scheduler = RefreshScheduler()

        scheduler.synchronizeCycleCounter(
            activeRefresh: ScheduledRefresh(
                cycleId: 9,
                kind: .fullRescan,
                reason: .startup
            ),
            pendingRefresh: ScheduledRefresh(
                cycleId: 12,
                kind: .relayout,
                reason: .gapsChanged
            )
        )

        let next = scheduler.makeScheduledRefresh(
            kind: .visibilityRefresh,
            reason: .appHidden
        )

        #expect(next.cycleId == 13)
    }

    @Test @MainActor func postLayoutActionsRunOnceAndCanBeDiscarded() {
        let scheduler = RefreshScheduler()
        var runCount = 0

        let attachmentIds = scheduler.registerPostLayoutAttachments {
            runCount += 1
        }

        #expect(scheduler.resolvePostLayoutActions(attachmentIds: attachmentIds).count == 1)

        scheduler.runPostLayoutActions(attachmentIds: attachmentIds)
        scheduler.runPostLayoutActions(attachmentIds: attachmentIds)

        #expect(runCount == 1)

        let discardedAttachmentIds = scheduler.registerPostLayoutAttachments {
            runCount += 1
        }
        scheduler.discardPostLayoutActions(attachmentIds: discardedAttachmentIds)
        scheduler.runPostLayoutActions(attachmentIds: discardedAttachmentIds)

        #expect(runCount == 1)
    }
}
