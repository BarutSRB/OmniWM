import AppKit
import Foundation

@MainActor
final class MouseWarpHandler {
    struct State {
        var eventTap: CFMachPort?
        var runLoopSource: CFRunLoopSource?
        var isWarping = false
        var lastMonitorId: Monitor.ID?
    }

    nonisolated(unsafe) static weak var _instance: MouseWarpHandler?
    static let cooldownSeconds: TimeInterval = 0.05

    weak var controller: WMController?
    var state = State()

    init(controller: WMController) {
        self.controller = controller
    }

    func setup() {
        guard state.eventTap == nil else { return }

        if let source = CGEventSource(stateID: .combinedSessionState) {
            source.localEventsSuppressionInterval = 0.0
        }

        MouseWarpHandler._instance = self

        let eventMask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = MouseWarpHandler._instance?.state.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let location = event.location
            let screenLocation = ScreenCoordinateSpace.toAppKit(point: location)

            Task { @MainActor in
                MouseWarpHandler._instance?.handleMouseWarpMoved(at: screenLocation)
            }

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
        MouseWarpHandler._instance = nil
        state.isWarping = false
        state.lastMonitorId = nil
    }

    private func handleMouseWarpMoved(at location: CGPoint) {
        guard let controller else { return }
        guard !state.isWarping else { return }
        guard controller.isEnabled else { return }
        guard controller.settings.mouseWarpEnabled else { return }

        let monitorOrder = controller.settings.mouseWarpMonitorOrder
        guard monitorOrder.count >= 2 else { return }

        let monitors = controller.workspaceManager.monitors
        let margin = CGFloat(controller.settings.mouseWarpMargin)

        guard let currentMonitor = monitors.first(where: { $0.frame.contains(location) }) else {
            mouseWarpClampCursorToNearestMonitor(location: location, monitors: monitors, margin: margin)
            return
        }

        if let lastMonitorId = state.lastMonitorId {
            if let lastMonitor = controller.workspaceManager.monitor(byId: lastMonitorId) {
                if lastMonitor.id != currentMonitor.id {
                    mouseWarpBackToMonitor(lastMonitor, location: location, margin: margin)
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
            in: monitorOrder,
            monitors: monitors
        ) else { return }

        let frame = currentMonitor.frame

        if location.x <= frame.minX + margin {
            let leftIndex = currentIndex - 1
            if leftIndex >= 0 {
                let yRatio = mouseWarpCalculateYRatio(location, in: frame)
                mouseWarpToMonitor(named: monitorOrder[leftIndex], edge: .right, yRatio: yRatio, monitors: monitors, margin: margin)
            }
        } else if location.x >= frame.maxX - margin {
            let rightIndex = currentIndex + 1
            if rightIndex < monitorOrder.count {
                let yRatio = mouseWarpCalculateYRatio(location, in: frame)
                mouseWarpToMonitor(named: monitorOrder[rightIndex], edge: .left, yRatio: yRatio, monitors: monitors, margin: margin)
            }
        }
    }

    private func mouseWarpCalculateYRatio(_ point: CGPoint, in frame: CGRect) -> CGFloat {
        (frame.maxY - point.y) / frame.height
    }

    private func mouseWarpBackToMonitor(_ monitor: Monitor, location: CGPoint, margin: CGFloat) {
        let frame = monitor.frame
        var clampedY = location.y

        if location.y > frame.maxY {
            clampedY = frame.maxY - margin - 1
        } else if location.y < frame.minY {
            clampedY = frame.minY + margin + 1
        } else {
            return
        }

        let clampedX = min(max(location.x, frame.minX + margin + 1), frame.maxX - margin - 1)

        state.isWarping = true
        state.lastMonitorId = monitor.id
        let warpPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(x: clampedX, y: clampedY))
        CGWarpMouseCursorPosition(warpPoint)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cooldownSeconds) { [weak self] in
            self?.state.isWarping = false
        }
    }

    private func mouseWarpClampCursorToNearestMonitor(location: CGPoint, monitors: [Monitor], margin: CGFloat) {
        if let lastMonitorId = state.lastMonitorId,
           let lastMonitor = controller?.workspaceManager.monitor(byId: lastMonitorId)
        {
            mouseWarpBackToMonitor(lastMonitor, location: location, margin: margin)
            return
        }

        guard let sourceMonitor = monitors.first(where: { monitor in
            location.x >= monitor.frame.minX && location.x <= monitor.frame.maxX
        }) else { return }

        let frame = sourceMonitor.frame
        var clampedY = location.y

        if location.y > frame.maxY {
            clampedY = frame.maxY - margin - 1
        } else if location.y < frame.minY {
            clampedY = frame.minY + margin + 1
        }

        if clampedY != location.y {
            state.isWarping = true
            let warpPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(x: location.x, y: clampedY))
            CGWarpMouseCursorPosition(warpPoint)

            DispatchQueue.main.asyncAfter(deadline: .now() + Self.cooldownSeconds) { [weak self] in
                self?.state.isWarping = false
            }
        }
    }

    private func mouseWarpToMonitor(named name: String, edge: Edge, yRatio: CGFloat, monitors: [Monitor], margin: CGFloat) {
        let candidates = controller?.workspaceManager.monitors(named: name) ?? monitors.filter { $0.name == name }
        guard !candidates.isEmpty else { return }

        guard let targetMonitor = mouseWarpTargetMonitor(from: candidates, edge: edge) else { return }

        let frame = targetMonitor.frame

        let x: CGFloat
        switch edge {
        case .left:
            x = frame.minX + margin + 1
        case .right:
            x = frame.maxX - margin - 1
        }

        let y = frame.maxY - (yRatio * frame.height)

        state.isWarping = true
        state.lastMonitorId = targetMonitor.id
        let warpPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(x: x, y: y))

        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: warpPoint, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cooldownSeconds) { [weak self] in
            self?.state.isWarping = false
        }
    }

    private func mouseWarpCurrentIndex(for currentMonitor: Monitor, in monitorOrder: [String], monitors: [Monitor]) -> Int? {
        let matchingIndices = monitorOrder.indices.filter { monitorOrder[$0] == currentMonitor.name }
        guard !matchingIndices.isEmpty else { return nil }
        guard matchingIndices.count > 1 else { return matchingIndices[0] }

        let sameNameMonitors = controller?.workspaceManager.monitors(named: currentMonitor.name)
            ?? monitors.filter { $0.name == currentMonitor.name }
        let sortedSameName = Monitor.sortedByPosition(sameNameMonitors)
        guard let rank = sortedSameName.firstIndex(where: { $0.id == currentMonitor.id }) else {
            return matchingIndices[0]
        }

        let clampedRank = min(rank, matchingIndices.count - 1)
        return matchingIndices[clampedRank]
    }

    private func mouseWarpTargetMonitor(from candidates: [Monitor], edge: Edge) -> Monitor? {
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 {
            return candidates[0]
        }

        let sorted = Monitor.sortedByPosition(candidates)
        switch edge {
        case .left:
            return sorted.first
        case .right:
            return sorted.last
        }
    }

    private enum Edge {
        case left
        case right
    }
}
