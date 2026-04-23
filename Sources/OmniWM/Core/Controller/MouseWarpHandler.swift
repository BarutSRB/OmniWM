// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation

@MainActor
final class MouseWarpHandler: NSObject {
    struct State {
        struct PendingWarpEvents {
            var pendingLocation: CGPoint?
            var drainScheduled = false

            var hasPendingEvents: Bool {
                pendingLocation != nil
            }

            mutating func clear() {
                pendingLocation = nil
                drainScheduled = false
            }
        }

        struct DebugCounters: Equatable {
            var queuedTransientEvents = 0
            var coalescedTransientEvents = 0
            var drainedTransientEvents = 0
            var drainRuns = 0
        }

        var eventTap: CFMachPort?
        var runLoopSource: CFRunLoopSource?
        var cooldownTimer: Timer?
        var isWarping = false
        var lastMonitorId: Monitor.ID?
        var pendingWarpEvents = PendingWarpEvents()
        var debugCounters = DebugCounters()
    }

    nonisolated(unsafe) static weak var sharedInstance: MouseWarpHandler?
    static let cooldownSeconds: TimeInterval = 0.05
    private static let nearestMonitorDistanceEpsilon: CGFloat = 0.0001

    weak var controller: WMController?
    var state = State()
    var warpCursor: (CGPoint) -> Void = { CGWarpMouseCursorPosition($0) }
    var postMouseMovedEvent: (CGPoint) -> Void = { point in
        if let moveEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) {
            moveEvent.post(tap: .cghidEventTap)
        }
    }

    init(controller: WMController) {
        self.controller = controller
        super.init()
    }

    func setup() {
        guard state.eventTap == nil else { return }

        if let source = CGEventSource(stateID: .combinedSessionState) {
            source.localEventsSuppressionInterval = 0.0
        }

        MouseWarpHandler.sharedInstance = self

        let eventMask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = MouseWarpHandler.sharedInstance?.state.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            _ = MouseWarpHandler.processTapCallback(event: event)

            return Unmanaged.passUnretained(event)
        }

        state.eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: nil
        )

        if let tap = state.eventTap {
            state.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source = state.runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    func cleanup() {
        if let source = state.runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            state.runLoopSource = nil
        }
        if let tap = state.eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            state.eventTap = nil
        }
        state.cooldownTimer?.invalidate()
        state.cooldownTimer = nil
        MouseWarpHandler.sharedInstance = nil
        state.isWarping = false
        state.lastMonitorId = nil
        state.pendingWarpEvents.clear()
        state.debugCounters = .init()
    }

    func flushPendingWarpEventsForTests() {
        flushPendingWarpEvents()
    }

    func mouseWarpDebugSnapshot() -> State.DebugCounters {
        state.debugCounters
    }

    func resetDebugStateForTests() {
        state.debugCounters = .init()
        state.pendingWarpEvents.clear()
    }

    func handleTapCallbackForTests(event: CGEvent, isMainThread: Bool) -> Bool {
        Self.processTapCallback(event: event, isMainThread: isMainThread)
    }

    func receiveTapMouseWarpMoved(at location: CGPoint) {
        guard let controller, !controller.isCursorAutomationSuppressed else { return }
        enqueuePendingWarpMove(at: location)
    }

    nonisolated private static func processTapCallback(
        event: CGEvent,
        isMainThread: Bool = Thread.isMainThread
    ) -> Bool {
        guard isMainThread else { return false }

        let screenLocation = ScreenCoordinateSpace.toAppKit(point: event.location)
        MainActor.assumeIsolated {
            MouseWarpHandler.sharedInstance?.receiveTapMouseWarpMoved(at: screenLocation)
        }
        return true
    }

    private func handleMouseWarpMoved(at location: CGPoint) {
        guard let controller else { return }
        guard !controller.isCursorAutomationSuppressed else { return }
        guard !state.isWarping else { return }
        guard controller.isEnabled else { return }

        let monitors = controller.workspaceManager.monitors
        guard monitors.count > 1 else { return }
        let axis = controller.settings.mouseWarpAxis
        let effectiveOrder = controller.settings.effectiveMouseWarpMonitorOrder(for: monitors, axis: axis)
        guard effectiveOrder.count >= 2 else { return }

        let margin = CGFloat(controller.settings.mouseWarpMargin)

        guard let currentMonitor = monitors.first(where: { $0.frame.contains(location) }) else {
            switch axis {
            case .horizontal:
                if mouseWarpAttemptHorizontalWarpFromLastMonitor(
                    location: location,
                    in: effectiveOrder,
                    monitors: monitors,
                    margin: margin
                ) {
                    return
                }
            case .vertical:
                if mouseWarpAttemptVerticalWarpFromLastMonitor(
                    location: location,
                    in: effectiveOrder,
                    monitors: monitors,
                    margin: margin
                ) {
                    return
                }
            }
            mouseWarpClampCursorToNearestMonitor(location: location, monitors: monitors, margin: margin, axis: axis)
            return
        }

        if let lastMonitorId = state.lastMonitorId {
            if let lastMonitor = controller.workspaceManager.monitor(byId: lastMonitorId) {
                if lastMonitor.id != currentMonitor.id {
                    let attemptedWarp: Bool = if let lastIndex = mouseWarpCurrentIndex(
                        for: lastMonitor,
                        in: effectiveOrder
                    ) {
                        switch axis {
                        case .horizontal:
                            mouseWarpAttemptHorizontalWarp(
                                from: lastMonitor,
                                sourceIndex: lastIndex,
                                location: location,
                                in: effectiveOrder,
                                monitors: monitors,
                                margin: margin
                            )
                        case .vertical:
                            mouseWarpAttemptVerticalWarp(
                                from: lastMonitor,
                                sourceIndex: lastIndex,
                                location: location,
                                in: effectiveOrder,
                                monitors: monitors,
                                margin: margin
                            )
                        }
                    } else {
                        false
                    }
                    if attemptedWarp {
                        return
                    }
                    mouseWarpBackToMonitor(lastMonitor, location: location, margin: margin, axis: axis)
                    return
                }
            } else {
                state.lastMonitorId = currentMonitor.id
            }
        } else {
            state.lastMonitorId = currentMonitor.id
        }

        state.lastMonitorId = currentMonitor.id
        guard let currentIndex = mouseWarpCurrentIndex(
            for: currentMonitor,
            in: effectiveOrder
        ) else { return }

        switch axis {
        case .horizontal:
            _ = mouseWarpAttemptHorizontalWarp(
                from: currentMonitor,
                sourceIndex: currentIndex,
                location: location,
                in: effectiveOrder,
                monitors: monitors,
                margin: margin
            )
        case .vertical:
            _ = mouseWarpAttemptVerticalWarp(
                from: currentMonitor,
                sourceIndex: currentIndex,
                location: location,
                in: effectiveOrder,
                monitors: monitors,
                margin: margin
            )
        }
    }

    private func mouseWarpAttemptHorizontalWarpFromLastMonitor(
        location: CGPoint,
        in effectiveOrder: [Monitor.ID],
        monitors: [Monitor],
        margin: CGFloat
    ) -> Bool {
        guard let lastMonitorId = state.lastMonitorId,
              let lastMonitor = controller?.workspaceManager.monitor(byId: lastMonitorId),
              let sourceIndex = mouseWarpCurrentIndex(
                  for: lastMonitor,
                  in: effectiveOrder
              ) else {
            return false
        }

        return mouseWarpAttemptHorizontalWarp(
            from: lastMonitor,
            sourceIndex: sourceIndex,
            location: location,
            in: effectiveOrder,
            monitors: monitors,
            margin: margin
        )
    }

    private func mouseWarpAttemptHorizontalWarp(
        from sourceMonitor: Monitor,
        sourceIndex: Int,
        location: CGPoint,
        in effectiveOrder: [Monitor.ID],
        monitors: [Monitor],
        margin: CGFloat
    ) -> Bool {
        let frame = sourceMonitor.frame

        if location.x <= frame.minX + margin {
            let leftIndex = sourceIndex - 1
            guard leftIndex >= 0 else { return false }
            mouseWarpToMonitor(
                id: effectiveOrder[leftIndex],
                edge: .right,
                transferRatio: mouseWarpCalculateYRatio(location, in: frame),
                axis: .horizontal,
                monitors: monitors,
                margin: margin
            )
            return true
        }

        if location.x >= frame.maxX - margin {
            let rightIndex = sourceIndex + 1
            guard rightIndex < effectiveOrder.count else { return false }
            mouseWarpToMonitor(
                id: effectiveOrder[rightIndex],
                edge: .left,
                transferRatio: mouseWarpCalculateYRatio(location, in: frame),
                axis: .horizontal,
                monitors: monitors,
                margin: margin
            )
            return true
        }

        return false
    }

    private func mouseWarpAttemptVerticalWarpFromLastMonitor(
        location: CGPoint,
        in effectiveOrder: [Monitor.ID],
        monitors: [Monitor],
        margin: CGFloat
    ) -> Bool {
        guard let lastMonitorId = state.lastMonitorId,
              let lastMonitor = controller?.workspaceManager.monitor(byId: lastMonitorId),
              let sourceIndex = mouseWarpCurrentIndex(
                  for: lastMonitor,
                  in: effectiveOrder
              ) else {
            return false
        }

        return mouseWarpAttemptVerticalWarp(
            from: lastMonitor,
            sourceIndex: sourceIndex,
            location: location,
            in: effectiveOrder,
            monitors: monitors,
            margin: margin
        )
    }

    private func mouseWarpAttemptVerticalWarp(
        from sourceMonitor: Monitor,
        sourceIndex: Int,
        location: CGPoint,
        in effectiveOrder: [Monitor.ID],
        monitors: [Monitor],
        margin: CGFloat
    ) -> Bool {
        let frame = sourceMonitor.frame

        if location.y >= frame.maxY - margin {
            let upperIndex = sourceIndex - 1
            guard upperIndex >= 0 else { return false }
            mouseWarpToMonitor(
                id: effectiveOrder[upperIndex],
                edge: .bottom,
                transferRatio: mouseWarpCalculateXRatio(location, in: frame),
                axis: .vertical,
                monitors: monitors,
                margin: margin
            )
            return true
        }

        if location.y <= frame.minY + margin {
            let lowerIndex = sourceIndex + 1
            guard lowerIndex < effectiveOrder.count else { return false }
            mouseWarpToMonitor(
                id: effectiveOrder[lowerIndex],
                edge: .top,
                transferRatio: mouseWarpCalculateXRatio(location, in: frame),
                axis: .vertical,
                monitors: monitors,
                margin: margin
            )
            return true
        }

        return false
    }

    private func mouseWarpBackToMonitor(_ monitor: Monitor, location: CGPoint, margin: CGFloat, axis: MouseWarpAxis) {
        let frame = monitor.frame
        let clampedPoint: CGPoint

        switch axis {
        case .horizontal:
            var clampedY = location.y

            if location.y > frame.maxY {
                clampedY = frame.maxY - margin - 1
            } else if location.y < frame.minY {
                clampedY = frame.minY + margin + 1
            } else {
                return
            }

            let clampedX = min(max(location.x, frame.minX + margin + 1), frame.maxX - margin - 1)
            clampedPoint = CGPoint(x: clampedX, y: clampedY)
        case .vertical:
            var clampedX = location.x

            if location.x > frame.maxX {
                clampedX = frame.maxX - margin - 1
            } else if location.x < frame.minX {
                clampedX = frame.minX + margin + 1
            } else {
                return
            }

            let clampedY = min(max(location.y, frame.minY + margin + 1), frame.maxY - margin - 1)
            clampedPoint = CGPoint(x: clampedX, y: clampedY)
        }

        state.isWarping = true
        state.lastMonitorId = monitor.id
        let warpPoint = ScreenCoordinateSpace.toWindowServer(point: clampedPoint)
        warpCursor(warpPoint)

        scheduleWarpCooldownReset()
    }

    private func mouseWarpClampCursorToNearestMonitor(
        location: CGPoint,
        monitors: [Monitor],
        margin: CGFloat,
        axis: MouseWarpAxis
    ) {
        if let lastMonitorId = state.lastMonitorId,
           let lastMonitor = controller?.workspaceManager.monitor(byId: lastMonitorId)
        {
            mouseWarpBackToMonitor(lastMonitor, location: location, margin: margin, axis: axis)
            return
        }

        let sourceMonitor = monitors.min { lhs, rhs in
            let lhsDistance = lhs.frame.distanceSquared(to: location)
            let rhsDistance = rhs.frame.distanceSquared(to: location)

            if abs(lhsDistance - rhsDistance) < Self.nearestMonitorDistanceEpsilon {
                return axis.sortedMonitors([lhs, rhs]).first?.id == lhs.id
            }

            return lhsDistance < rhsDistance
        }
        guard let sourceMonitor else { return }

        let frame = sourceMonitor.frame
        let clampedPoint = CGPoint(
            x: mouseWarpClampCoordinate(
                location.x,
                minCoordinate: frame.minX,
                maxCoordinate: frame.maxX,
                margin: margin
            ),
            y: mouseWarpClampCoordinate(
                location.y,
                minCoordinate: frame.minY,
                maxCoordinate: frame.maxY,
                margin: margin
            )
        )

        if clampedPoint != location {
            state.isWarping = true
            let warpPoint = ScreenCoordinateSpace.toWindowServer(point: clampedPoint)
            warpCursor(warpPoint)

            scheduleWarpCooldownReset()
        }
    }

    private func mouseWarpToMonitor(
        id targetMonitorId: Monitor.ID,
        edge: Edge,
        transferRatio: CGFloat,
        axis: MouseWarpAxis,
        monitors: [Monitor],
        margin: CGFloat
    ) {
        guard let targetMonitor = controller?.workspaceManager.monitor(byId: targetMonitorId)
            ?? monitors.first(where: { $0.id == targetMonitorId })
        else {
            return
        }

        let destination = mouseWarpDestinationPoint(
            transferRatio: transferRatio,
            on: targetMonitor.frame,
            edge: edge,
            axis: axis,
            margin: margin
        )

        state.isWarping = true
        state.lastMonitorId = targetMonitor.id
        let warpPoint = ScreenCoordinateSpace.toWindowServer(point: destination)

        warpCursor(warpPoint)
        _ = controller?.workspaceManager.setInteractionMonitor(targetMonitor.id)
        postMouseMovedEvent(warpPoint)

        scheduleWarpCooldownReset()
    }

    private func mouseWarpDestinationPoint(
        transferRatio: CGFloat,
        on frame: CGRect,
        edge: Edge,
        axis: MouseWarpAxis,
        margin: CGFloat
    ) -> CGPoint {
        let clampedRatio = min(max(transferRatio, 0), 1)

        switch axis {
        case .horizontal:
            let x: CGFloat
            switch edge {
            case .left:
                x = frame.minX + margin + 1
            case .right:
                x = frame.maxX - margin - 1
            case .top, .bottom:
                x = mouseWarpClampCoordinate(
                    frame.minX + clampedRatio * frame.width,
                    minCoordinate: frame.minX,
                    maxCoordinate: frame.maxX,
                    margin: margin
                )
            }

            let y = mouseWarpClampMappedCoordinate(
                frame.maxY - clampedRatio * frame.height,
                minCoordinate: frame.minY,
                maxCoordinate: frame.maxY
            )
            return CGPoint(x: x, y: y)
        case .vertical:
            let y: CGFloat
            switch edge {
            case .top:
                y = frame.maxY - margin - 1
            case .bottom:
                y = frame.minY + margin + 1
            case .left, .right:
                y = mouseWarpClampCoordinate(
                    frame.maxY - clampedRatio * frame.height,
                    minCoordinate: frame.minY,
                    maxCoordinate: frame.maxY,
                    margin: margin
                )
            }

            let x = mouseWarpClampMappedCoordinate(
                frame.minX + clampedRatio * frame.width,
                minCoordinate: frame.minX,
                maxCoordinate: frame.maxX
            )
            return CGPoint(x: x, y: y)
        }
    }

    private func mouseWarpCalculateYRatio(_ point: CGPoint, in frame: CGRect) -> CGFloat {
        guard frame.height > 0 else { return 0.5 }
        return (frame.maxY - point.y) / frame.height
    }

    private func mouseWarpCalculateXRatio(_ point: CGPoint, in frame: CGRect) -> CGFloat {
        guard frame.width > 0 else { return 0.5 }
        return (point.x - frame.minX) / frame.width
    }

    private func mouseWarpClampMappedCoordinate(
        _ value: CGFloat,
        minCoordinate: CGFloat,
        maxCoordinate: CGFloat
    ) -> CGFloat {
        guard minCoordinate < maxCoordinate else { return minCoordinate }
        return min(max(value, minCoordinate), maxCoordinate.nextDown)
    }

    private func mouseWarpClampCoordinate(
        _ value: CGFloat,
        minCoordinate: CGFloat,
        maxCoordinate: CGFloat,
        margin: CGFloat
    ) -> CGFloat {
        let lowerBound = minCoordinate + margin + 1
        let upperBound = maxCoordinate - margin - 1

        guard lowerBound <= upperBound else {
            return (minCoordinate + maxCoordinate) / 2
        }

        return min(max(value, lowerBound), upperBound)
    }

    private func mouseWarpCurrentIndex(
        for currentMonitor: Monitor,
        in monitorOrder: [Monitor.ID]
    ) -> Int? {
        monitorOrder.firstIndex(of: currentMonitor.id)
    }

    private func scheduleWarpCooldownReset() {
        state.cooldownTimer?.invalidate()
        state.cooldownTimer = Timer(
            fireAt: Date(timeIntervalSinceNow: MouseWarpHandler.cooldownSeconds),
            interval: 0,
            target: self,
            selector: #selector(handleWarpCooldownTimer(_:)),
            userInfo: nil,
            repeats: false
        )

        if let cooldownTimer = state.cooldownTimer {
            RunLoop.main.add(cooldownTimer, forMode: .common)
        }
    }

    private enum Edge {
        case left
        case right
        case top
        case bottom

        var prefersLeadingMonitor: Bool {
            switch self {
            case .left, .top:
                true
            case .right, .bottom:
                false
            }
        }
    }

    @objc private func handleWarpCooldownTimer(_ timer: Timer) {
        timer.invalidate()
        if state.cooldownTimer === timer {
            state.cooldownTimer = nil
        }
        state.isWarping = false
    }

    private func schedulePendingWarpDrainIfNeeded() {
        guard !state.pendingWarpEvents.drainScheduled else { return }
        state.pendingWarpEvents.drainScheduled = true

        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.flushPendingWarpEvents()
            }
        }
        CFRunLoopWakeUp(mainRunLoop)
    }

    private func enqueuePendingWarpMove(at location: CGPoint) {
        state.debugCounters.queuedTransientEvents += 1
        let didCoalesce = state.pendingWarpEvents.pendingLocation != nil
        state.pendingWarpEvents.pendingLocation = location
        if didCoalesce {
            state.debugCounters.coalescedTransientEvents += 1
        }
        schedulePendingWarpDrainIfNeeded()
    }

    private func flushPendingWarpEvents() {
        guard state.pendingWarpEvents.hasPendingEvents,
              let pendingLocation = state.pendingWarpEvents.pendingLocation else {
            state.pendingWarpEvents.clear()
            return
        }

        state.pendingWarpEvents.clear()
        state.debugCounters.drainRuns += 1
        state.debugCounters.drainedTransientEvents += 1
        handleMouseWarpMoved(at: pendingLocation)
    }
}
