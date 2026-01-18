import AppKit
import Foundation

@MainActor
final class MouseWarpHandler {
    private weak var controller: WMController?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isWarping = false
    private var lastMonitorId: Monitor.ID?

    private static var sharedHandler: MouseWarpHandler?
    private static let warpCooldownSeconds: TimeInterval = 0.05

    init(controller: WMController) {
        self.controller = controller
    }

    func setup() {
        guard eventTap == nil else { return }

        if let source = CGEventSource(stateID: .combinedSessionState) {
            source.localEventsSuppressionInterval = 0.0
        }

        MouseWarpHandler.sharedHandler = self

        let eventMask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = MouseWarpHandler.sharedHandler?.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let location = event.location
            let screenLocation = ScreenCoordinateSpace.toAppKit(point: location)

            Task { @MainActor in
                MouseWarpHandler.sharedHandler?.handleMouseMoved(at: screenLocation)
            }

            return Unmanaged.passUnretained(event)
        }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: nil
        )

        if let tap = eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source = runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    func cleanup() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        MouseWarpHandler.sharedHandler = nil
        isWarping = false
        lastMonitorId = nil
    }

    private func handleMouseMoved(at location: CGPoint) {
        guard !isWarping else { return }
        guard let controller else { return }
        guard controller.isEnabled else { return }
        guard controller.internalSettings.mouseWarpEnabled else { return }

        let monitorOrder = controller.internalSettings.mouseWarpMonitorOrder
        guard monitorOrder.count >= 2 else { return }

        let monitors = controller.internalWorkspaceManager.monitors
        let margin = CGFloat(controller.internalSettings.mouseWarpMargin)

        guard let currentMonitor = monitors.first(where: { $0.frame.contains(location) }) else {
            clampCursorToNearestMonitor(location: location, monitors: monitors, margin: margin)
            return
        }

        if let lastMonitorId {
            if let lastMonitor = monitors.first(where: { $0.id == lastMonitorId }) {
                if lastMonitor.id != currentMonitor.id {
                    warpBackToMonitor(lastMonitor, location: location, margin: margin)
                    return
                }
            } else {
                self.lastMonitorId = currentMonitor.id
            }
        } else {
            lastMonitorId = currentMonitor.id
        }

        lastMonitorId = currentMonitor.id
        guard let currentIndex = monitorOrder.firstIndex(of: currentMonitor.name) else { return }

        let frame = currentMonitor.frame

        if location.x <= frame.minX + margin {
            let leftIndex = currentIndex - 1
            if leftIndex >= 0 {
                let yRatio = calculateYRatio(location, in: frame)
                warpToMonitor(named: monitorOrder[leftIndex], edge: .right, yRatio: yRatio, monitors: monitors, margin: margin)
            }
        } else if location.x >= frame.maxX - margin {
            let rightIndex = currentIndex + 1
            if rightIndex < monitorOrder.count {
                let yRatio = calculateYRatio(location, in: frame)
                warpToMonitor(named: monitorOrder[rightIndex], edge: .left, yRatio: yRatio, monitors: monitors, margin: margin)
            }
        }
    }

    private func calculateYRatio(_ point: CGPoint, in frame: CGRect) -> CGFloat {
        (frame.maxY - point.y) / frame.height
    }

    private func warpBackToMonitor(_ monitor: Monitor, location: CGPoint, margin: CGFloat) {
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

        isWarping = true
        lastMonitorId = monitor.id
        let warpPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(x: clampedX, y: clampedY))
        CGWarpMouseCursorPosition(warpPoint)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.warpCooldownSeconds) { [weak self] in
            self?.isWarping = false
        }
    }

    private func clampCursorToNearestMonitor(location: CGPoint, monitors: [Monitor], margin: CGFloat) {
        if let lastMonitorId,
           let lastMonitor = monitors.first(where: { $0.id == lastMonitorId })
        {
            warpBackToMonitor(lastMonitor, location: location, margin: margin)
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
            isWarping = true
            let warpPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(x: location.x, y: clampedY))
            CGWarpMouseCursorPosition(warpPoint)

            DispatchQueue.main.asyncAfter(deadline: .now() + Self.warpCooldownSeconds) { [weak self] in
                self?.isWarping = false
            }
        }
    }

    private func warpToMonitor(named name: String, edge: Edge, yRatio: CGFloat, monitors: [Monitor], margin: CGFloat) {
        guard let targetMonitor = monitors.first(where: { $0.name == name }) else { return }

        let frame = targetMonitor.frame

        let x: CGFloat
        switch edge {
        case .left:
            x = frame.minX + margin + 1
        case .right:
            x = frame.maxX - margin - 1
        }

        let y = frame.maxY - (yRatio * frame.height)

        isWarping = true
        lastMonitorId = targetMonitor.id
        let warpPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(x: x, y: y))

        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: warpPoint, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.warpCooldownSeconds) { [weak self] in
            self?.isWarping = false
        }
    }

    private enum Edge {
        case left
        case right
    }
}
