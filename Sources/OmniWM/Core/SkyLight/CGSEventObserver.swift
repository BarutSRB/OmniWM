// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import os

enum CGSWindowEvent: Equatable {
    case created(windowId: UInt32, spaceId: UInt64)
    case destroyed(windowId: UInt32, spaceId: UInt64)
    case frameChanged(windowId: UInt32)
    case closed(windowId: UInt32)
    case frontAppChanged(pid: pid_t)
    case titleChanged(windowId: UInt32)
}

@MainActor
protocol CGSEventDelegate: AnyObject {
    func cgsEventObserver(_ observer: CGSEventObserver, didReceive event: CGSWindowEvent)
}

@MainActor
final class CGSEventObserver {
    struct DebugCounters: Equatable {
        var decodedEvents = 0
        var coalescedFrameEvents = 0
        var malformedPayloadDrops = 0
        var clearedFrameEventsOnDestroy = 0
        var drainedEvents = 0
        var drainRuns = 0
    }

    static let shared = CGSEventObserver()

    weak var delegate: CGSEventDelegate?

    private var isRegistered = false
    private var isWindowClosedNotifyRegistered = false
    private var requestedWindowIds: Set<UInt32> = []
    private var retainedWindowSubscriptionCounts: [UInt32: Int] = [:]
    var windowNotificationRequestHandlerForTests: (([UInt32]) -> Bool)?
    var windowNotificationUnrequestHandlerForTests: (([UInt32]) -> Bool?)?

    private init() {}

    func start() {
        guard !isRegistered else { return }

        let eventsViaConnectionNotify: [CGSEventType] = [
            .spaceWindowCreated,
            .spaceWindowDestroyed,
            .windowMoved,
            .windowResized,
            .windowTitleChanged,
            .frontmostApplicationChanged
        ]

        var successCount = 0
        for event in eventsViaConnectionNotify {
            let success = SkyLight.shared.registerForNotification(
                event: event,
                callback: cgsConnectionCallback,
                context: nil
            )
            if success {
                successCount += 1
            }
        }

        if isWindowClosedNotifyRegistered {
            successCount += 1
        } else {
            let cid = SkyLight.shared.getMainConnectionID()
            let cidContext = UnsafeMutableRawPointer(bitPattern: Int(cid))
            let windowClosedSuccess = SkyLight.shared.registerNotifyProc(
                event: .windowClosed,
                callback: notifyCallback,
                context: cidContext
            )
            if windowClosedSuccess {
                successCount += 1
                isWindowClosedNotifyRegistered = true
            }
        }

        isRegistered = successCount > 0
        updateCallbackRegistrationState(isRegistered)
    }

    func stop() {
        if isRegistered {
            let eventsToUnregister: [CGSEventType] = [
                .spaceWindowCreated,
                .spaceWindowDestroyed,
                .windowMoved,
                .windowResized,
                .windowTitleChanged,
                .frontmostApplicationChanged
            ]

            for event in eventsToUnregister {
                _ = SkyLight.shared.unregisterForNotification(
                    event: event,
                    callback: cgsConnectionCallback
                )
            }

            isRegistered = false
        }

        if isWindowClosedNotifyRegistered {
            let cid = SkyLight.shared.getMainConnectionID()
            let cidContext = UnsafeMutableRawPointer(bitPattern: Int(cid))
            if SkyLight.shared.unregisterNotifyProc(
                event: .windowClosed,
                callback: notifyCallback,
                context: cidContext
            ) {
                isWindowClosedNotifyRegistered = false
            }
        }

        updateCallbackRegistrationState(false)
        requestedWindowIds.removeAll()
        retainedWindowSubscriptionCounts.removeAll()
    }

    @discardableResult
    func subscribeToWindows(_ windowIds: [UInt32]) -> Bool {
        let newWindowIds = uniqueWindowIds(windowIds).filter { !requestedWindowIds.contains($0) }
        guard !newWindowIds.isEmpty else {
            return true
        }
        guard requestWindowNotifications(newWindowIds) else {
            return false
        }
        requestedWindowIds.formUnion(newWindowIds)
        return true
    }

    @discardableResult
    func retainWindowNotificationSubscriptions(_ windowIds: [UInt32]) -> Bool {
        let uniqueWindowIds = uniqueWindowIds(windowIds)
        guard subscribeToWindows(uniqueWindowIds) else {
            return false
        }
        for windowId in uniqueWindowIds {
            retainedWindowSubscriptionCounts[windowId, default: 0] += 1
        }
        return true
    }

    @discardableResult
    func releaseWindowNotificationSubscriptions(_ windowIds: [UInt32]) -> Set<UInt32> {
        let uniqueWindowIds = uniqueWindowIds(windowIds)
        var orphanedWindowIds: [UInt32] = []
        for windowId in uniqueWindowIds {
            guard let currentCount = retainedWindowSubscriptionCounts[windowId] else { continue }
            if currentCount > 1 {
                retainedWindowSubscriptionCounts[windowId] = currentCount - 1
            } else {
                retainedWindowSubscriptionCounts.removeValue(forKey: windowId)
                orphanedWindowIds.append(windowId)
            }
        }

        let releasedWindowIds = Set(orphanedWindowIds)
        let removedWindowIds = unsubscribeFromWindowNotificationsIfAvailable(orphanedWindowIds)
        requestedWindowIds.subtract(removedWindowIds)
        return releasedWindowIds
    }

    private func requestWindowNotifications(_ windowIds: [UInt32]) -> Bool {
        if let windowNotificationRequestHandlerForTests {
            return windowNotificationRequestHandlerForTests(windowIds)
        }
        return SkyLight.shared.subscribeToWindowNotifications(windowIds)
    }

    private func unsubscribeFromWindowNotificationsIfAvailable(_ windowIds: [UInt32]) -> Set<UInt32> {
        guard !windowIds.isEmpty else {
            return []
        }

        if let windowNotificationUnrequestHandlerForTests {
            guard windowNotificationUnrequestHandlerForTests(windowIds) == true else {
                return []
            }
            return Set(windowIds)
        }

        guard SkyLight.shared.unsubscribeFromWindowNotifications(windowIds) == true else {
            return []
        }
        return Set(windowIds)
    }

    private func uniqueWindowIds(_ windowIds: [UInt32]) -> [UInt32] {
        var seen: Set<UInt32> = []
        return windowIds.filter { seen.insert($0).inserted }
    }

    func flushPendingCGSEventsForTests() {
        drainPendingEventsOnMainRunLoop(ignoreRegistration: true)
    }

    func enqueueEventForTests(_ event: CGSWindowEvent) {
        enqueueDecodedCGSEvent(event, requireRegistration: false)
    }

    func ingestRawEventForTests(eventType: UInt32, bytes: [UInt8]) {
        bytes.withUnsafeBytes { rawBuffer in
            handleRawCGSEvent(
                eventType: eventType,
                data: UnsafeMutableRawPointer(mutating: rawBuffer.baseAddress),
                length: rawBuffer.count,
                requireRegistration: false
            )
        }
    }

    func resetDebugStateForTests() {
        requestedWindowIds.removeAll()
        retainedWindowSubscriptionCounts.removeAll()
        windowNotificationRequestHandlerForTests = nil
        windowNotificationUnrequestHandlerForTests = nil
        resetPendingCGSEventState(isRegistered: isRegistered)
    }

    func cgsDebugSnapshot() -> DebugCounters {
        cgsPendingEvents.withLock { $0.debugCounters }
    }

    func windowNotificationStateForTests() -> (
        requestedWindowIds: Set<UInt32>,
        retainedWindowSubscriptionCounts: [UInt32: Int]
    ) {
        (requestedWindowIds, retainedWindowSubscriptionCounts)
    }

    fileprivate func drainPendingEventsOnMainRunLoop(ignoreRegistration: Bool = false) {
        precondition(Thread.isMainThread, "CGS drains must run on the main run loop")

        let pendingDrain = cgsPendingEvents.withLock { state -> (events: [CGSWindowEvent], ignoresRegistration: Bool) in
            let events = state.orderedEvents
            let ignoresRegistration = state.drainIgnoresRegistration
            state.orderedEvents.removeAll(keepingCapacity: true)
            state.pendingFrameWindowIds.removeAll(keepingCapacity: true)
            state.drainScheduled = false
            state.drainIgnoresRegistration = false
            if !events.isEmpty {
                state.debugCounters.drainRuns += 1
                state.debugCounters.drainedEvents += events.count
            }
            return (events, ignoresRegistration)
        }

        guard ignoreRegistration || pendingDrain.ignoresRegistration || isRegistered else { return }

        for event in pendingDrain.events {
            delegate?.cgsEventObserver(self, didReceive: event)
            forgetWindowNotificationStateIfNeeded(for: event)
        }
    }

    private func updateCallbackRegistrationState(_ isRegistered: Bool) {
        if isRegistered {
            cgsPendingEvents.withLock { $0.isRegistered = true }
        } else {
            resetPendingCGSEventState(isRegistered: false)
        }
    }

    private func forgetWindowNotificationStateIfNeeded(for event: CGSWindowEvent) {
        switch event {
        case let .destroyed(windowId, _), let .closed(windowId):
            requestedWindowIds.remove(windowId)
            retainedWindowSubscriptionCounts.removeValue(forKey: windowId)
        case .created, .frameChanged, .frontAppChanged, .titleChanged:
            return
        }
    }
}

private struct PendingCGSEventState {
    var isRegistered = false
    var drainScheduled = false
    var drainIgnoresRegistration = false
    var orderedEvents: [CGSWindowEvent] = []
    var pendingFrameWindowIds: Set<UInt32> = []
    var debugCounters = CGSEventObserver.DebugCounters()
}

private enum DecodedCGSEvent {
    case ignored
    case malformed
    case event(CGSWindowEvent)
}

private let cgsPendingEvents = OSAllocatedUnfairLock(initialState: PendingCGSEventState())

private func resetPendingCGSEventState(isRegistered: Bool) {
    cgsPendingEvents.withLock { state in
        state.isRegistered = isRegistered
        state.drainScheduled = false
        state.drainIgnoresRegistration = false
        state.orderedEvents.removeAll(keepingCapacity: false)
        state.pendingFrameWindowIds.removeAll(keepingCapacity: false)
        state.debugCounters = .init()
    }
}

private func schedulePendingCGSEventDrain() {
    let mainRunLoop = CFRunLoopGetMain()
    CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) {
        MainActor.assumeIsolated {
            CGSEventObserver.shared.drainPendingEventsOnMainRunLoop()
        }
    }
    CFRunLoopWakeUp(mainRunLoop)
}

private func enqueueDecodedCGSEvent(_ event: CGSWindowEvent, requireRegistration: Bool = true) {
    let shouldScheduleDrain = cgsPendingEvents.withLock { state -> Bool in
        guard state.isRegistered || !requireRegistration else { return false }

        state.debugCounters.decodedEvents += 1

        switch event {
        case let .frameChanged(windowId):
            if state.pendingFrameWindowIds.insert(windowId).inserted {
                state.orderedEvents.append(event)
            } else {
                state.debugCounters.coalescedFrameEvents += 1
            }

        case let .destroyed(windowId, _):
            clearPendingFrameEvent(windowId: windowId, state: &state)
            state.orderedEvents.append(event)

        case let .closed(windowId):
            clearPendingFrameEvent(windowId: windowId, state: &state)
            state.orderedEvents.append(event)

        case .created,
             .frontAppChanged,
             .titleChanged:
            state.orderedEvents.append(event)
        }

        if !requireRegistration {
            state.drainIgnoresRegistration = true
        }

        guard !state.drainScheduled else { return false }
        state.drainScheduled = true
        return true
    }

    if shouldScheduleDrain {
        schedulePendingCGSEventDrain()
    }
}

private func clearPendingFrameEvent(
    windowId: UInt32,
    state: inout PendingCGSEventState
) {
    guard state.pendingFrameWindowIds.remove(windowId) != nil else { return }

    state.orderedEvents.removeAll { event in
        if case let .frameChanged(pendingWindowId) = event {
            return pendingWindowId == windowId
        }
        return false
    }
    state.debugCounters.clearedFrameEventsOnDestroy += 1
}

private func handleRawCGSEvent(
    eventType: UInt32,
    data: UnsafeMutableRawPointer?,
    length: Int,
    requireRegistration: Bool = true
) {
    switch decodeCGSEvent(eventType: eventType, data: data, length: length) {
    case .ignored:
        return
    case .malformed:
        cgsPendingEvents.withLock { state in
            guard state.isRegistered || !requireRegistration else { return }
            state.debugCounters.malformedPayloadDrops += 1
        }
    case let .event(event):
        enqueueDecodedCGSEvent(event, requireRegistration: requireRegistration)
    }
}

private func decodeCGSEvent(
    eventType: UInt32,
    data: UnsafeMutableRawPointer?,
    length: Int
) -> DecodedCGSEvent {
    guard let cgsEvent = CGSEventType(rawValue: eventType) else {
        return .ignored
    }

    switch cgsEvent {
    case .spaceWindowCreated:
        guard let spaceId = copyUInt64(from: data, length: length, offset: 0),
              let windowId = copyUInt32(from: data, length: length, offset: 8)
        else {
            return .malformed
        }
        return .event(.created(windowId: windowId, spaceId: spaceId))

    case .spaceWindowDestroyed:
        guard let spaceId = copyUInt64(from: data, length: length, offset: 0),
              let windowId = copyUInt32(from: data, length: length, offset: 8)
        else {
            return .malformed
        }
        return .event(.destroyed(windowId: windowId, spaceId: spaceId))

    case .windowClosed:
        guard let windowId = copyUInt32(from: data, length: length, offset: 0) else {
            return .malformed
        }
        return .event(.closed(windowId: windowId))

    case .windowMoved,
         .windowResized:
        guard let windowId = copyUInt32(from: data, length: length, offset: 0) else {
            return .malformed
        }
        return .event(.frameChanged(windowId: windowId))

    case .frontmostApplicationChanged:
        guard let pid = copyInt32(from: data, length: length, offset: 0) else {
            return .malformed
        }
        return .event(.frontAppChanged(pid: pid))

    case .windowTitleChanged:
        guard let windowId = copyUInt32(from: data, length: length, offset: 0) else {
            return .malformed
        }
        return .event(.titleChanged(windowId: windowId))

    default:
        return .ignored
    }
}

private func copyUInt32(
    from data: UnsafeMutableRawPointer?,
    length: Int,
    offset: Int
) -> UInt32? {
    guard let data else { return nil }
    let valueSize = MemoryLayout<UInt32>.size
    guard length >= offset + valueSize else { return nil }

    var value: UInt32 = 0
    withUnsafeMutableBytes(of: &value) { destination in
        let source = UnsafeRawBufferPointer(
            start: UnsafeRawPointer(data).advanced(by: offset),
            count: valueSize
        )
        destination.copyBytes(from: source)
    }
    return value
}

private func copyUInt64(
    from data: UnsafeMutableRawPointer?,
    length: Int,
    offset: Int
) -> UInt64? {
    guard let data else { return nil }
    let valueSize = MemoryLayout<UInt64>.size
    guard length >= offset + valueSize else { return nil }

    var value: UInt64 = 0
    withUnsafeMutableBytes(of: &value) { destination in
        let source = UnsafeRawBufferPointer(
            start: UnsafeRawPointer(data).advanced(by: offset),
            count: valueSize
        )
        destination.copyBytes(from: source)
    }
    return value
}

private func copyInt32(
    from data: UnsafeMutableRawPointer?,
    length: Int,
    offset: Int
) -> Int32? {
    guard let data else { return nil }
    let valueSize = MemoryLayout<Int32>.size
    guard length >= offset + valueSize else { return nil }

    var value: Int32 = 0
    withUnsafeMutableBytes(of: &value) { destination in
        let source = UnsafeRawBufferPointer(
            start: UnsafeRawPointer(data).advanced(by: offset),
            count: valueSize
        )
        destination.copyBytes(from: source)
    }
    return value
}

private func cgsConnectionCallback(
    event: UInt32,
    data: UnsafeMutableRawPointer?,
    length: Int,
    context _: UnsafeMutableRawPointer?,
    cid _: Int32
) {
    handleRawCGSEvent(eventType: event, data: data, length: length)
}

private func notifyCallback(
    event: UInt32,
    data: UnsafeMutableRawPointer?,
    length: Int,
    cid _: Int32
) {
    handleRawCGSEvent(eventType: event, data: data, length: length)
}
