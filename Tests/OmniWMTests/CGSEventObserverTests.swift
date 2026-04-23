// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing

@testable import OmniWM

@MainActor
private final class RecordingCGSEventDelegate: CGSEventDelegate {
    var events: [CGSWindowEvent] = []

    func cgsEventObserver(_: CGSEventObserver, didReceive event: CGSWindowEvent) {
        events.append(event)
    }
}

private func rawBytes<T>(of value: T) -> [UInt8] {
    withUnsafeBytes(of: value) { Array($0) }
}

private func createdPayload(spaceId: UInt64, windowId: UInt32) -> [UInt8] {
    rawBytes(of: spaceId) + rawBytes(of: windowId)
}

@MainActor
private func waitForMainRunLoopTurn() async {
    await withCheckedContinuation { continuation in
        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) {
            continuation.resume()
        }
        CFRunLoopWakeUp(mainRunLoop)
    }
}

@MainActor
private func waitUntilCGSEvents(
    iterations: Int = 100,
    condition: () -> Bool
) async {
    for _ in 0..<iterations where !condition() {
        await waitForMainRunLoopTurn()
    }

    if !condition() {
        Issue.record("Timed out waiting for scheduled CGS drain")
    }
}

@Suite(.serialized) struct CGSEventObserverTests {
    @Test @MainActor func malformedAndShortPayloadsAreDroppedSafely() {
        let observer = CGSEventObserver.shared
        let recorder = RecordingCGSEventDelegate()
        observer.resetDebugStateForTests()
        observer.delegate = recorder
        defer {
            observer.delegate = nil
            observer.resetDebugStateForTests()
        }

        observer.ingestRawEventForTests(
            eventType: CGSEventType.windowMoved.rawValue,
            bytes: [0xAA, 0xBB, 0xCC]
        )
        observer.ingestRawEventForTests(
            eventType: CGSEventType.spaceWindowCreated.rawValue,
            bytes: Array(repeating: 0, count: 11)
        )
        observer.flushPendingCGSEventsForTests()

        #expect(recorder.events.isEmpty)
        #expect(observer.cgsDebugSnapshot().malformedPayloadDrops == 2)
    }

    @Test @MainActor func rawPayloadsDecodeIntoTypedEvents() {
        let observer = CGSEventObserver.shared
        let recorder = RecordingCGSEventDelegate()
        observer.resetDebugStateForTests()
        observer.delegate = recorder
        defer {
            observer.delegate = nil
            observer.resetDebugStateForTests()
        }

        observer.ingestRawEventForTests(
            eventType: CGSEventType.windowMoved.rawValue,
            bytes: rawBytes(of: UInt32(71))
        )
        observer.ingestRawEventForTests(
            eventType: CGSEventType.spaceWindowCreated.rawValue,
            bytes: createdPayload(spaceId: 55, windowId: 72)
        )
        observer.flushPendingCGSEventsForTests()

        #expect(recorder.events == [
            .frameChanged(windowId: 71),
            .created(windowId: 72, spaceId: 55),
        ])
    }

    @Test @MainActor func frameChangedBurstCoalescesWhileTopologyRemainsFIFO() {
        let observer = CGSEventObserver.shared
        let recorder = RecordingCGSEventDelegate()
        observer.resetDebugStateForTests()
        observer.delegate = recorder
        defer {
            observer.delegate = nil
            observer.resetDebugStateForTests()
        }

        observer.enqueueEventForTests(.created(windowId: 81, spaceId: 10))
        observer.enqueueEventForTests(.frameChanged(windowId: 81))
        observer.enqueueEventForTests(.frameChanged(windowId: 81))
        observer.enqueueEventForTests(.titleChanged(windowId: 81))
        observer.enqueueEventForTests(.frameChanged(windowId: 82))
        observer.flushPendingCGSEventsForTests()

        #expect(recorder.events == [
            .created(windowId: 81, spaceId: 10),
            .frameChanged(windowId: 81),
            .titleChanged(windowId: 81),
            .frameChanged(windowId: 82),
        ])

        let snapshot = observer.cgsDebugSnapshot()
        #expect(snapshot.coalescedFrameEvents == 1)
        #expect(snapshot.drainRuns == 1)
        #expect(snapshot.drainedEvents == 4)
    }

    @Test @MainActor func closeClearsPendingFrameChangeBeforeDelivery() {
        let observer = CGSEventObserver.shared
        let recorder = RecordingCGSEventDelegate()
        observer.resetDebugStateForTests()
        observer.delegate = recorder
        defer {
            observer.delegate = nil
            observer.resetDebugStateForTests()
        }

        observer.enqueueEventForTests(.frameChanged(windowId: 91))
        observer.enqueueEventForTests(.frameChanged(windowId: 92))
        observer.enqueueEventForTests(.closed(windowId: 91))
        observer.flushPendingCGSEventsForTests()

        #expect(recorder.events == [
            .frameChanged(windowId: 92),
            .closed(windowId: 91),
        ])
        #expect(observer.cgsDebugSnapshot().clearedFrameEventsOnDestroy == 1)
    }

    @Test @MainActor func destroyClearsPendingFrameChangeBeforeDelivery() {
        let observer = CGSEventObserver.shared
        let recorder = RecordingCGSEventDelegate()
        observer.resetDebugStateForTests()
        observer.delegate = recorder
        defer {
            observer.delegate = nil
            observer.resetDebugStateForTests()
        }

        observer.enqueueEventForTests(.frameChanged(windowId: 101))
        observer.enqueueEventForTests(.frameChanged(windowId: 102))
        observer.enqueueEventForTests(.destroyed(windowId: 101, spaceId: 44))
        observer.flushPendingCGSEventsForTests()

        #expect(recorder.events == [
            .frameChanged(windowId: 102),
            .destroyed(windowId: 101, spaceId: 44),
        ])
        #expect(observer.cgsDebugSnapshot().clearedFrameEventsOnDestroy == 1)
    }

    @Test @MainActor func scheduledDrainProcessesOneBurstWithoutManualFlush() async {
        let observer = CGSEventObserver.shared
        let recorder = RecordingCGSEventDelegate()
        observer.resetDebugStateForTests()
        observer.delegate = recorder
        defer {
            observer.delegate = nil
            observer.resetDebugStateForTests()
        }

        observer.enqueueEventForTests(.created(windowId: 111, spaceId: 12))
        observer.enqueueEventForTests(.frameChanged(windowId: 111))
        observer.enqueueEventForTests(.frameChanged(windowId: 111))
        observer.enqueueEventForTests(.titleChanged(windowId: 111))

        await waitUntilCGSEvents {
            recorder.events.count == 3
        }

        #expect(recorder.events == [
            .created(windowId: 111, spaceId: 12),
            .frameChanged(windowId: 111),
            .titleChanged(windowId: 111),
        ])

        let snapshot = observer.cgsDebugSnapshot()
        #expect(snapshot.coalescedFrameEvents == 1)
        #expect(snapshot.drainRuns == 1)
        #expect(snapshot.drainedEvents == 3)
    }

    @Test @MainActor func releasingReferenceCountedSubscriptionDropsOwnershipWhenUnsubscribeIsUnavailable() {
        let observer = CGSEventObserver.shared
        var requests: [[UInt32]] = []
        var unrequests: [[UInt32]] = []

        observer.resetDebugStateForTests()
        observer.windowNotificationRequestHandlerForTests = { windowIds in
            requests.append(windowIds)
            return true
        }
        observer.windowNotificationUnrequestHandlerForTests = { windowIds in
            unrequests.append(windowIds)
            return nil
        }
        defer { observer.resetDebugStateForTests() }

        #expect(observer.retainWindowNotificationSubscriptions([501]))

        let releasedWindowIds = observer.releaseWindowNotificationSubscriptions([501])
        let stateAfterRelease = observer.windowNotificationStateForTests()

        #expect(releasedWindowIds == [501])
        #expect(requests == [[501]])
        #expect(unrequests == [[501]])
        #expect(stateAfterRelease.requestedWindowIds == [501])
        #expect(stateAfterRelease.retainedWindowSubscriptionCounts.isEmpty)

        #expect(observer.retainWindowNotificationSubscriptions([501]))
        #expect(requests == [[501]])
        #expect(observer.windowNotificationStateForTests().retainedWindowSubscriptionCounts == [501: 1])
    }

    @Test @MainActor func successfulUnderlyingUnsubscribeClearsStickyRequestState() {
        let observer = CGSEventObserver.shared
        var requests: [[UInt32]] = []
        var unrequests: [[UInt32]] = []

        observer.resetDebugStateForTests()
        observer.windowNotificationRequestHandlerForTests = { windowIds in
            requests.append(windowIds)
            return true
        }
        observer.windowNotificationUnrequestHandlerForTests = { windowIds in
            unrequests.append(windowIds)
            return true
        }
        defer { observer.resetDebugStateForTests() }

        #expect(observer.retainWindowNotificationSubscriptions([601]))
        #expect(observer.releaseWindowNotificationSubscriptions([601]) == [601])

        let stateAfterRelease = observer.windowNotificationStateForTests()
        #expect(requests == [[601]])
        #expect(unrequests == [[601]])
        #expect(stateAfterRelease.requestedWindowIds.isEmpty)
        #expect(stateAfterRelease.retainedWindowSubscriptionCounts.isEmpty)

        #expect(observer.retainWindowNotificationSubscriptions([601]))
        #expect(requests == [[601], [601]])
    }
}
