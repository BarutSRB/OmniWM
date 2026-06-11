import Foundation
import os

enum IntakeEvent: Sendable {
    case cgs(CGSWindowEvent)
}

struct StampedIntakeEvent: Sendable {
    let seq: UInt64
    let event: IntakeEvent
}

@MainActor
protocol EventIntakeSink: AnyObject {
    func handleIntakeEvent(_ stamped: StampedIntakeEvent)
}

@MainActor
final class EventIntake {
    private struct Buffer {
        var isOpen = false
        var drainScheduled = false
        var nextSeq: UInt64 = 1
        var orderedEvents: [StampedIntakeEvent] = []
        var pendingCGSFrameWindowIds: Set<UInt32> = []
    }

    private nonisolated let buffer = OSAllocatedUnfairLock(initialState: Buffer())
    private weak var sink: EventIntakeSink?

    nonisolated static func post(_ event: IntakeEvent) {
        activeIntake.withLock { $0 }?.enqueue(event)
    }

    func open(sink: EventIntakeSink) {
        self.sink = sink
        buffer.withLock { $0.isOpen = true }
        activeIntake.withLock { $0 = self }
    }

    func close() {
        activeIntake.withLock { active in
            if active === self {
                active = nil
            }
        }
        buffer.withLock { state in
            state.isOpen = false
            state.drainScheduled = false
            state.orderedEvents.removeAll(keepingCapacity: false)
            state.pendingCGSFrameWindowIds.removeAll(keepingCapacity: false)
        }
        sink = nil
    }

    nonisolated func enqueue(_ event: IntakeEvent) {
        let shouldScheduleDrain = buffer.withLock { state -> Bool in
            guard state.isOpen else { return false }
            stampAndCoalesce(event, into: &state)
            guard !state.drainScheduled else { return false }
            state.drainScheduled = true
            return true
        }
        if shouldScheduleDrain {
            scheduleDrain()
        }
    }

    func drainNow() {
        drainPendingEventsOnMainRunLoop()
    }

    private nonisolated func stampAndCoalesce(_ event: IntakeEvent, into state: inout Buffer) {
        switch event {
        case let .cgs(.frameChanged(windowId)):
            guard state.pendingCGSFrameWindowIds.insert(windowId).inserted else { return }

        case let .cgs(.closed(windowId)),
             let .cgs(.destroyed(windowId, _)):
            removePendingCGSFrameEvents(windowId: windowId, state: &state)

        default:
            break
        }

        state.orderedEvents.append(StampedIntakeEvent(seq: state.nextSeq, event: event))
        state.nextSeq += 1
    }

    private nonisolated func removePendingCGSFrameEvents(windowId: UInt32, state: inout Buffer) {
        guard state.pendingCGSFrameWindowIds.remove(windowId) != nil else { return }
        state.orderedEvents.removeAll { stamped in
            if case let .cgs(.frameChanged(pendingWindowId)) = stamped.event {
                return pendingWindowId == windowId
            }
            return false
        }
    }

    private nonisolated func scheduleDrain() {
        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                self.drainPendingEventsOnMainRunLoop()
            }
        }
        CFRunLoopWakeUp(mainRunLoop)
    }

    private func drainPendingEventsOnMainRunLoop() {
        let events = buffer.withLock { state -> [StampedIntakeEvent] in
            let events = state.orderedEvents
            state.orderedEvents.removeAll(keepingCapacity: true)
            state.pendingCGSFrameWindowIds.removeAll(keepingCapacity: true)
            state.drainScheduled = false
            return events
        }
        guard let sink else { return }
        for stamped in events {
            sink.handleIntakeEvent(stamped)
        }
    }
}

private let activeIntake = OSAllocatedUnfairLock<EventIntake?>(initialState: nil)
