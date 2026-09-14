// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

private struct EventCategoryPerformanceCounters {
    var acceptedEvents: UInt64 = 0
    var coalescedEvents: UInt64 = 0
    var deliveredEvents: UInt64 = 0

    var snapshot: EventIntake.EventCategoryPerformanceSnapshot {
        EventIntake.EventCategoryPerformanceSnapshot(
            acceptedEvents: acceptedEvents,
            coalescedEvents: coalescedEvents,
            deliveredEvents: deliveredEvents
        )
    }
}

struct IntakePerformanceCounters {
    var acceptedEvents: UInt64 = 0
    var coalescedEvents: UInt64 = 0
    var deliveredEvents: UInt64 = 0
    var drainBatches: UInt64 = 0
    var maximumQueueDepth = 0
    var maximumBatchSize = 0
    private var cgsCreatedEvents = EventCategoryPerformanceCounters()
    private var cgsDestroyedEvents = EventCategoryPerformanceCounters()
    private var cgsFrameChangedEvents = EventCategoryPerformanceCounters()
    private var cgsTitleChangedEvents = EventCategoryPerformanceCounters()
    private var axLifecycleEvents = EventCategoryPerformanceCounters()
    private var axFocusedWindowChangedEvents = EventCategoryPerformanceCounters()

    init(maximumQueueDepth: Int) {
        self.maximumQueueDepth = maximumQueueDepth
    }

    func snapshot(currentQueueDepth: Int) -> EventIntake.PerformanceSnapshot {
        EventIntake.PerformanceSnapshot(
            acceptedEvents: acceptedEvents,
            coalescedEvents: coalescedEvents,
            deliveredEvents: deliveredEvents,
            drainBatches: drainBatches,
            currentQueueDepth: currentQueueDepth,
            maximumQueueDepth: maximumQueueDepth,
            maximumBatchSize: maximumBatchSize,
            cgsCreatedEvents: cgsCreatedEvents.snapshot,
            cgsDestroyedEvents: cgsDestroyedEvents.snapshot,
            cgsFrameChangedEvents: cgsFrameChangedEvents.snapshot,
            cgsTitleChangedEvents: cgsTitleChangedEvents.snapshot,
            axLifecycleEvents: axLifecycleEvents.snapshot,
            axFocusedWindowChangedEvents: axFocusedWindowChangedEvents.snapshot
        )
    }

    mutating func recordAccepted(
        _ event: IntakeEvent,
        coalesced: Bool,
        queueDepth: Int
    ) {
        acceptedEvents &+= 1
        if coalesced {
            coalescedEvents &+= 1
        }
        maximumQueueDepth = max(maximumQueueDepth, queueDepth)
        guard let keyPath = Self.performanceCategoryKeyPath(for: event) else { return }
        self[keyPath: keyPath].acceptedEvents &+= 1
        if coalesced {
            self[keyPath: keyPath].coalescedEvents &+= 1
        }
    }

    mutating func recordDelivered(_ event: IntakeEvent) {
        guard let keyPath = Self.performanceCategoryKeyPath(for: event) else { return }
        self[keyPath: keyPath].deliveredEvents &+= 1
    }

    mutating func recordDrain(_ events: [StampedIntakeEvent]) {
        guard !events.isEmpty else { return }
        drainBatches &+= 1
        deliveredEvents &+= UInt64(events.count)
        maximumBatchSize = max(maximumBatchSize, events.count)
        for stamped in events {
            recordDelivered(stamped.event)
        }
    }

    private static func performanceCategoryKeyPath(
        for event: IntakeEvent
    ) -> WritableKeyPath<IntakePerformanceCounters, EventCategoryPerformanceCounters>? {
        switch event {
        case .cgs(.created):
            \.cgsCreatedEvents
        case .cgs(.destroyed),
             .cgs(.closed):
            \.cgsDestroyedEvents
        case .cgs(.frameChanged):
            \.cgsFrameChangedEvents
        case .cgs(.titleChanged):
            \.cgsTitleChangedEvents
        case .axWindow(.windowDestroyed),
             .axWindow(.windowMiniaturized):
            \.axLifecycleEvents
        case .axWindow(.focusedWindowChanged):
            \.axFocusedWindowChangedEvents
        default:
            nil
        }
    }
}
