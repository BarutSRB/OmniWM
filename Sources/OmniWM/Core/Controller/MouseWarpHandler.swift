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
        enqueuePendingWarpMove(at: location)
    }

    nonisolated private static func processTapCallback(
        event: CGEvent,
        isMainThread: Bool = Thread.isMainThread
    ) -> Bool {
        guard isMainThread else { return false }

        let screenLocation = ScreenCoordinateSpace.toAppKit(point: event.location)
        MainActor.assumeIsolated {
            guard let handler = MouseWarpHandler.sharedInstance else { return }
            guard let controller = handler.controller, !controller.isCursorAutomationSuppressed else { return }
            handler.receiveTapMouseWarpMoved(at: screenLocation)
        }
        return true
    }

    private func handleMouseWarpMoved(at location: CGPoint) {
        guard let controller else { return }
        guard !state.isWarping else { return }
        guard controller.isEnabled else { return }
        guard !controller.isCursorAutomationSuppressed else { return }

        let monitors = controller.workspaceManager.monitors
        guard monitors.count > 1 else { return }
        let axis = controller.settings.mouseWarpAxis
        let effectiveOrder = controller.settings.effectiveMouseWarpMonitorOrder(for: monitors, axis: axis)
        guard effectiveOrder.count >= 2 else { return }

        // For `both` axis, compute separate horizontal and vertical orderings
        let hOrder: [String]
        let vOrder: [String]
        if axis == .both {
            hOrder = controller.settings.effectiveMouseWarpMonitorOrder(for: monitors, axis: .horizontal)
            vOrder = controller.settings.effectiveMouseWarpMonitorOrder(for: monitors, axis: .vertical)
        } else {
            hOrder = effectiveOrder
            vOrder = effectiveOrder
        }

        let margin = CGFloat(controller.settings.mouseWarpMargin)

        // Grid-first path for `both` axis: intercept ALL cursor movement using grid adjacency
        if axis == .both {
            let gridEntries = controller.settings.mouseWarpGrid
            let virtualLayout = mouseWarpBuildVirtualLayout(grid: gridEntries, monitors: monitors)
            if !virtualLayout.isEmpty {
                handleGridBasedWarp(location: location, monitors: monitors, virtualLayout: virtualLayout, margin: margin)
                return
            }
        }

        guard let currentMonitor = monitors.first(where: { $0.frame.contains(location) }) else {
            // Try to warp from the last monitor when the cursor escaped between monitors.
            switch axis {
            case .horizontal:
                if mouseWarpAttemptHorizontalWarpFromLastMonitor(
                    location: location,
                    in: hOrder,
                    monitors: monitors,
                    margin: margin
                ) {
                    return
                }
            case .vertical:
                if mouseWarpAttemptVerticalWarpFromLastMonitor(
                    location: location,
                    in: vOrder,
                    monitors: monitors,
                    margin: margin
                ) {
                    return
                }
            case .both:
                if mouseWarpAttemptHorizontalWarpFromLastMonitor(
                    location: location,
                    in: hOrder,
                    monitors: monitors,
                    margin: margin
                ) {
                    return
                }
                if mouseWarpAttemptVerticalWarpFromLastMonitor(
                    location: location,
                    in: vOrder,
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
                    let attemptedWarp: Bool
                    switch axis {
                    case .horizontal:
                        if let lastIndex = mouseWarpCurrentIndex(
                            for: lastMonitor,
                            in: hOrder,
                            monitors: monitors,
                            axis: .horizontal
                        ) {
                            attemptedWarp = mouseWarpAttemptHorizontalWarp(
                                from: lastMonitor,
                                sourceIndex: lastIndex,
                                location: location,
                                in: hOrder,
                                monitors: monitors,
                                margin: margin
                            )
                        } else {
                            attemptedWarp = false
                        }
                    case .vertical:
                        if let lastIndex = mouseWarpCurrentIndex(
                            for: lastMonitor,
                            in: vOrder,
                            monitors: monitors,
                            axis: .vertical
                        ) {
                            attemptedWarp = mouseWarpAttemptVerticalWarp(
                                from: lastMonitor,
                                sourceIndex: lastIndex,
                                location: location,
                                in: vOrder,
                                monitors: monitors,
                                margin: margin
                            )
                        } else {
                            attemptedWarp = false
                        }
                    case .both:
                        var attempted = false
                        if let lastHIndex = mouseWarpCurrentIndex(
                            for: lastMonitor,
                            in: hOrder,
                            monitors: monitors,
                            axis: .horizontal
                        ),
                            mouseWarpAttemptHorizontalWarp(
                                from: lastMonitor,
                                sourceIndex: lastHIndex,
                                location: location,
                                in: hOrder,
                                monitors: monitors,
                                margin: margin
                            )
                        {
                            attempted = true
                        } else if let lastVIndex = mouseWarpCurrentIndex(
                            for: lastMonitor,
                            in: vOrder,
                            monitors: monitors,
                            axis: .vertical
                        ),
                            mouseWarpAttemptVerticalWarp(
                                from: lastMonitor,
                                sourceIndex: lastVIndex,
                                location: location,
                                in: vOrder,
                                monitors: monitors,
                                margin: margin
                            )
                        {
                            attempted = true
                        }
                        attemptedWarp = attempted
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
            in: effectiveOrder,
            monitors: monitors,
            axis: axis
        ) else { return }

        let frame = currentMonitor.frame

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
        case .both:
            // Fallback when grid is empty: order-based horizontal + vertical
            if let hIndex = mouseWarpCurrentIndex(for: currentMonitor, in: hOrder, monitors: monitors, axis: .horizontal) {
                if location.x <= frame.minX + margin {
                    let leftIndex = hIndex - 1
                    if leftIndex >= 0 {
                        let yRatio = mouseWarpCalculateYRatio(location, in: frame)
                        mouseWarpToMonitor(named: hOrder[leftIndex], edge: .right, transferRatio: yRatio, axis: .horizontal, monitors: monitors, margin: margin)
                        return
                    }
                } else if location.x >= frame.maxX - margin {
                    let rightIndex = hIndex + 1
                    if rightIndex < hOrder.count {
                        let yRatio = mouseWarpCalculateYRatio(location, in: frame)
                        mouseWarpToMonitor(named: hOrder[rightIndex], edge: .left, transferRatio: yRatio, axis: .horizontal, monitors: monitors, margin: margin)
                        return
                    }
                }
            }
            if let vIndex = mouseWarpCurrentIndex(for: currentMonitor, in: vOrder, monitors: monitors, axis: .vertical) {
                _ = mouseWarpAttemptVerticalWarp(from: currentMonitor, sourceIndex: vIndex, location: location, in: vOrder, monitors: monitors, margin: margin)
            }
        }
    }

    private func mouseWarpCalculateYRatio(_ point: CGPoint, in frame: CGRect) -> CGFloat {
        (frame.maxY - point.y) / frame.height
    }

    private func mouseWarpCalculateXRatio(_ point: CGPoint, in frame: CGRect) -> CGFloat {
        (point.x - frame.minX) / frame.width
    }

    private func mouseWarpAttemptHorizontalWarpFromLastMonitor(
        location: CGPoint,
        in effectiveOrder: [String],
        monitors: [Monitor],
        margin: CGFloat
    ) -> Bool {
        guard let lastMonitorId = state.lastMonitorId,
              let lastMonitor = controller?.workspaceManager.monitor(byId: lastMonitorId),
              let sourceIndex = mouseWarpCurrentIndex(
                  for: lastMonitor,
                  in: effectiveOrder,
                  monitors: monitors,
                  axis: .horizontal
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
        in effectiveOrder: [String],
        monitors: [Monitor],
        margin: CGFloat
    ) -> Bool {
        let frame = sourceMonitor.frame

        if location.x <= frame.minX + margin {
            let leftIndex = sourceIndex - 1
            guard leftIndex >= 0 else { return false }
            let yRatio = mouseWarpCalculateYRatio(location, in: frame)
            mouseWarpToMonitor(
                named: effectiveOrder[leftIndex],
                edge: .right,
                transferRatio: yRatio,
                axis: .horizontal,
                monitors: monitors,
                margin: margin
            )
            return true
        }

        if location.x >= frame.maxX - margin {
            let rightIndex = sourceIndex + 1
            guard rightIndex < effectiveOrder.count else { return false }
            let yRatio = mouseWarpCalculateYRatio(location, in: frame)
            mouseWarpToMonitor(
                named: effectiveOrder[rightIndex],
                edge: .left,
                transferRatio: yRatio,
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
        in effectiveOrder: [String],
        monitors: [Monitor],
        margin: CGFloat
    ) -> Bool {
        guard let lastMonitorId = state.lastMonitorId,
              let lastMonitor = controller?.workspaceManager.monitor(byId: lastMonitorId),
              let sourceIndex = mouseWarpCurrentIndex(
                  for: lastMonitor,
                  in: effectiveOrder,
                  monitors: monitors,
                  axis: .vertical
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
        in effectiveOrder: [String],
        monitors: [Monitor],
        margin: CGFloat
    ) -> Bool {
        let frame = sourceMonitor.frame

        if location.y >= frame.maxY - margin {
            let upperIndex = sourceIndex - 1
            guard upperIndex >= 0 else { return false }
            let xRatio = mouseWarpCalculateXRatio(location, in: frame)
            mouseWarpToMonitor(
                named: effectiveOrder[upperIndex],
                edge: .bottom,
                transferRatio: xRatio,
                axis: .vertical,
                monitors: monitors,
                margin: margin
            )
            return true
        }

        if location.y <= frame.minY + margin {
            let lowerIndex = sourceIndex + 1
            guard lowerIndex < effectiveOrder.count else { return false }
            let xRatio = mouseWarpCalculateXRatio(location, in: frame)
            mouseWarpToMonitor(
                named: effectiveOrder[lowerIndex],
                edge: .top,
                transferRatio: xRatio,
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
        case .both:
            var x = location.x
            var y = location.y
            var needsClamp = false

            if x > frame.maxX {
                x = frame.maxX - margin - 1
                needsClamp = true
            } else if x < frame.minX {
                x = frame.minX + margin + 1
                needsClamp = true
            }
            if y > frame.maxY {
                y = frame.maxY - margin - 1
                needsClamp = true
            } else if y < frame.minY {
                y = frame.minY + margin + 1
                needsClamp = true
            }

            guard needsClamp else { return }
            clampedPoint = CGPoint(x: x, y: y)
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

        // Pick the closest monitor by squared distance, breaking ties via the axis-defined order.
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
        named name: String,
        edge: Edge,
        transferRatio: CGFloat,
        axis: MouseWarpAxis,
        monitors: [Monitor],
        margin: CGFloat
    ) {
        let candidates = controller?.workspaceManager.monitors(named: name) ?? monitors.filter { $0.name == name }
        guard !candidates.isEmpty else { return }

        guard let targetMonitor = mouseWarpTargetMonitor(from: candidates, edge: edge, axis: axis) else { return }

        let destination = mouseWarpDestinationPoint(
            on: targetMonitor.frame,
            edge: edge,
            transferRatio: transferRatio,
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
        on frame: CGRect,
        edge: Edge,
        transferRatio: CGFloat,
        axis: MouseWarpAxis,
        margin: CGFloat
    ) -> CGPoint {
        let clampedRatio = min(max(transferRatio, 0), 1)

        switch axis {
        case .horizontal, .both:
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

            let y: CGFloat
            switch edge {
            case .top:
                y = frame.maxY - margin - 1
            case .bottom:
                y = frame.minY + margin + 1
            case .left, .right:
                y = mouseWarpClampMappedCoordinate(
                    frame.maxY - clampedRatio * frame.height,
                    minCoordinate: frame.minY,
                    maxCoordinate: frame.maxY
                )
            }
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
        in monitorOrder: [String],
        monitors: [Monitor],
        axis: MouseWarpAxis
    ) -> Int? {
        let matchingIndices = monitorOrder.indices.filter { monitorOrder[$0] == currentMonitor.name }
        guard !matchingIndices.isEmpty else { return nil }
        guard matchingIndices.count > 1 else { return matchingIndices[0] }

        let sameNameMonitors = controller?.workspaceManager.monitors(named: currentMonitor.name)
            ?? monitors.filter { $0.name == currentMonitor.name }
        let sortedSameName = axis.sortedMonitors(sameNameMonitors)
        guard let rank = sortedSameName.firstIndex(where: { $0.id == currentMonitor.id }) else {
            return matchingIndices[0]
        }

        let clampedRank = min(rank, matchingIndices.count - 1)
        return matchingIndices[clampedRank]
    }

    private func mouseWarpTargetMonitor(from candidates: [Monitor], edge: Edge, axis: MouseWarpAxis) -> Monitor? {
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 {
            return candidates[0]
        }

        let sorted = axis.sortedMonitors(candidates)
        if edge.prefersLeadingMonitor {
            return sorted.first
        }
        return sorted.last
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

    /// Maps cursor position from source to target using virtual layout coordinates.
    /// Instead of using ratio within the source monitor, computes the absolute virtual
    /// position and maps it to the target's virtual frame.
    private func mouseWarpVirtualTransferRatio(
        location: CGPoint,
        actualFrame: CGRect,
        sourceVirtual: CGRect,
        targetVirtual: CGRect,
        direction: Edge
    ) -> CGFloat {
        switch direction {
        case .left, .right:
            // Transfer Y position using virtual coordinates
            let ratioInSource = (actualFrame.maxY - location.y) / actualFrame.height
            let virtualY = sourceVirtual.minY + ratioInSource * sourceVirtual.height
            let ratioInTarget = (virtualY - targetVirtual.minY) / targetVirtual.height
            return min(max(ratioInTarget, 0.05), 0.95)
        case .top, .bottom:
            // Transfer X position using virtual coordinates
            let ratioInSource = (location.x - actualFrame.minX) / actualFrame.width
            let virtualX = sourceVirtual.minX + ratioInSource * sourceVirtual.width
            let ratioInTarget = (virtualX - targetVirtual.minX) / targetVirtual.width
            return min(max(ratioInTarget, 0.05), 0.95)
        }
    }

    // MARK: - Grid-based virtual layout for `both` axis

    private struct VirtualMonitor {
        let monitor: Monitor
        let virtualFrame: CGRect
    }

    private func mouseWarpBuildVirtualLayout(
        grid: [MouseWarpGridEntry],
        monitors: [Monitor]
    ) -> [VirtualMonitor] {
        grid.compactMap { entry in
            guard let monitor = monitors.first(where: { $0.name == entry.name }) else { return nil }
            return VirtualMonitor(monitor: monitor, virtualFrame: entry.virtualFrame(for: monitor))
        }
    }

    private func mouseWarpGridNeighbor(
        for monitor: Monitor,
        direction: Edge,
        virtualLayout: [VirtualMonitor],
        cursorVirtualX: CGFloat? = nil
    ) -> VirtualMonitor? {
        guard let current = virtualLayout.first(where: { $0.monitor.id == monitor.id }) else {
            return nil
        }
        let vf = current.virtualFrame
        let others = virtualLayout.filter { $0.monitor.id != monitor.id }

        // AppKit coordinates: y increases upward. "top" edge = maxY = physically above.
        switch direction {
        case .left:
            return others
                .filter { $0.virtualFrame.maxX <= vf.minX + 1 }
                .filter { $0.virtualFrame.maxY > vf.minY && $0.virtualFrame.minY < vf.maxY }
                .min(by: { abs($0.virtualFrame.maxX - vf.minX) < abs($1.virtualFrame.maxX - vf.minX) })
        case .right:
            return others
                .filter { $0.virtualFrame.minX >= vf.maxX - 1 }
                .filter { $0.virtualFrame.maxY > vf.minY && $0.virtualFrame.minY < vf.maxY }
                .min(by: { abs($0.virtualFrame.minX - vf.maxX) < abs($1.virtualFrame.minX - vf.maxX) })
        case .top:
            // Going up: find monitor whose bottom (minY) is at our top (maxY)
            let candidates = others
                .filter { $0.virtualFrame.minY >= vf.maxY - 1 }
                .filter { $0.virtualFrame.maxX > vf.minX && $0.virtualFrame.minX < vf.maxX }
            if candidates.count <= 1 { return candidates.first }
            // Multiple candidates: pick the one containing the cursor's virtual X
            if let cx = cursorVirtualX {
                return candidates.first(where: { cx >= $0.virtualFrame.minX && cx < $0.virtualFrame.maxX })
                    ?? candidates.min(by: { abs($0.virtualFrame.minY - vf.maxY) < abs($1.virtualFrame.minY - vf.maxY) })
            }
            return candidates.min(by: { abs($0.virtualFrame.minY - vf.maxY) < abs($1.virtualFrame.minY - vf.maxY) })
        case .bottom:
            // Going down: find monitor whose top (maxY) is at our bottom (minY)
            let candidates = others
                .filter { $0.virtualFrame.maxY <= vf.minY + 1 }
                .filter { $0.virtualFrame.maxX > vf.minX && $0.virtualFrame.minX < vf.maxX }
            if candidates.count <= 1 { return candidates.first }
            // Multiple candidates: pick the one containing the cursor's virtual X
            if let cx = cursorVirtualX {
                return candidates.first(where: { cx >= $0.virtualFrame.minX && cx < $0.virtualFrame.maxX })
                    ?? candidates.min(by: { abs($0.virtualFrame.maxY - vf.minY) < abs($1.virtualFrame.maxY - vf.minY) })
            }
            return candidates.min(by: { abs($0.virtualFrame.maxY - vf.minY) < abs($1.virtualFrame.maxY - vf.minY) })
        }
    }

    // MARK: - Grid-based warp: handles ALL cursor movement for `both` + grid

    private func handleGridBasedWarp(
        location: CGPoint,
        monitors: [Monitor],
        virtualLayout: [VirtualMonitor],
        margin: CGFloat
    ) {
        // Determine reference monitor (where cursor was last)
        let referenceMonitor: Monitor
        if let lastId = state.lastMonitorId,
           let last = monitors.first(where: { $0.id == lastId }) {
            referenceMonitor = last
        } else if let current = monitors.first(where: { $0.frame.contains(location) }) {
            state.lastMonitorId = current.id
            return
        } else {
            return
        }

        let frame = referenceMonitor.frame

        // Cursor still inside reference monitor — check edges
        if frame.contains(location) {
            state.lastMonitorId = referenceMonitor.id

            // Check all 4 edges
            var direction: Edge?
            if location.x <= frame.minX + margin { direction = .left }
            else if location.x >= frame.maxX - margin { direction = .right }
            else if location.y >= frame.maxY - margin { direction = .top }
            else if location.y <= frame.minY + margin { direction = .bottom }

            // Compute cursor's virtual X for disambiguating multiple vertical neighbors
            let sourceVM = virtualLayout.first(where: { $0.monitor.id == referenceMonitor.id })
            let cursorVX: CGFloat? = sourceVM.map { vm in
                let ratioInSource = (location.x - frame.minX) / frame.width
                return vm.virtualFrame.minX + ratioInSource * vm.virtualFrame.width
            }

            if let dir = direction,
               let sourceVM,
               let target = mouseWarpGridNeighbor(for: referenceMonitor, direction: dir, virtualLayout: virtualLayout, cursorVirtualX: cursorVX) {

                let ratio = mouseWarpVirtualTransferRatio(
                    location: location, actualFrame: frame,
                    sourceVirtual: sourceVM.virtualFrame, targetVirtual: target.virtualFrame,
                    direction: dir
                )
                let targetEdge: Edge
                let warpAxis: MouseWarpAxis
                switch dir {
                case .left: targetEdge = .right; warpAxis = .horizontal
                case .right: targetEdge = .left; warpAxis = .horizontal
                case .top: targetEdge = .bottom; warpAxis = .vertical
                case .bottom: targetEdge = .top; warpAxis = .vertical
                }
                mouseWarpToAdjacentMonitor(target.monitor, edge: targetEdge, transferRatio: ratio, warpAxis: warpAxis, margin: margin)
            }
            return
        }

        // Cursor has LEFT the reference monitor — determine which edge was crossed
        var direction: Edge?
        if location.x < frame.minX { direction = .left }
        else if location.x > frame.maxX { direction = .right }
        if direction == nil {
            if location.y >= frame.maxY { direction = .top }
            else if location.y <= frame.minY { direction = .bottom }
        }

        // Compute cursor's virtual X for escape path too
        let escapeSourceVM = virtualLayout.first(where: { $0.monitor.id == referenceMonitor.id })
        let escapeCursorVX: CGFloat? = escapeSourceVM.map { vm in
            let ratioInSource = (location.x - frame.minX) / frame.width
            return vm.virtualFrame.minX + ratioInSource * vm.virtualFrame.width
        }

        if let dir = direction,
           let sourceVM = escapeSourceVM,
           let target = mouseWarpGridNeighbor(for: referenceMonitor, direction: dir, virtualLayout: virtualLayout, cursorVirtualX: escapeCursorVX) {
            let ratio = mouseWarpVirtualTransferRatio(
                location: location, actualFrame: frame,
                sourceVirtual: sourceVM.virtualFrame, targetVirtual: target.virtualFrame,
                direction: dir
            )
            let targetEdge: Edge
            let warpAxis: MouseWarpAxis
            switch dir {
            case .left: targetEdge = .right; warpAxis = .horizontal
            case .right: targetEdge = .left; warpAxis = .horizontal
            case .top: targetEdge = .bottom; warpAxis = .vertical
            case .bottom: targetEdge = .top; warpAxis = .vertical
            }
            mouseWarpToAdjacentMonitor(target.monitor, edge: targetEdge, transferRatio: ratio, warpAxis: warpAxis, margin: margin)
        } else {
            // No grid neighbor — clamp back to reference monitor
            mouseWarpBackToMonitor(referenceMonitor, location: location, margin: margin, axis: .both)
        }
    }

    private func mouseWarpToAdjacentMonitor(
        _ target: Monitor,
        edge: Edge,
        transferRatio: CGFloat,
        warpAxis: MouseWarpAxis,
        margin: CGFloat
    ) {
        let destination = mouseWarpDestinationPoint(
            on: target.frame,
            edge: edge,
            transferRatio: transferRatio,
            axis: warpAxis,
            margin: max(margin * 5, 10)
        )

        state.isWarping = true
        state.lastMonitorId = target.id
        let warpPoint = ScreenCoordinateSpace.toWindowServer(point: destination)

        warpCursor(warpPoint)
        _ = controller?.workspaceManager.setInteractionMonitor(target.id)
        postMouseMovedEvent(warpPoint)

        scheduleWarpCooldownReset()
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
