import AppKit
import Foundation

extension WMController {
    struct MouseWarpState {
        var eventTap: CFMachPort?
        var runLoopSource: CFRunLoopSource?
        var isWarping = false
        var lastMonitorId: Monitor.ID?
    }

    nonisolated(unsafe) static weak var _mouseWarpInstance: WMController?
    static let mouseWarpCooldownSeconds: TimeInterval = 0.05

    func mouseWarpSetup() {
        guard mouseWarpState.eventTap == nil else { return }

        if let source = CGEventSource(stateID: .combinedSessionState) {
            source.localEventsSuppressionInterval = 0.0
        }

        WMController._mouseWarpInstance = self

        let eventMask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = WMController._mouseWarpInstance?.mouseWarpState.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let location = event.location
            let screenLocation = ScreenCoordinateSpace.toAppKit(point: location)

            Task { @MainActor in
                WMController._mouseWarpInstance?.handleMouseWarpMoved(at: screenLocation)
            }

            return Unmanaged.passUnretained(event)
        }

        mouseWarpState.eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: nil
        )

        if let tap = mouseWarpState.eventTap {
            mouseWarpState.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source = mouseWarpState.runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    func mouseWarpCleanup() {
        if let source = mouseWarpState.runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            mouseWarpState.runLoopSource = nil
        }
        if let tap = mouseWarpState.eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            mouseWarpState.eventTap = nil
        }
        WMController._mouseWarpInstance = nil
        mouseWarpState.isWarping = false
        mouseWarpState.lastMonitorId = nil
    }

    private func handleMouseWarpMoved(at location: CGPoint) {
        guard !mouseWarpState.isWarping else { return }
        guard isEnabled else { return }
        guard settings.mouseWarpEnabled else { return }

        let monitorOrder = settings.mouseWarpMonitorOrder
        guard monitorOrder.count >= 2 else { return }

        let monitors = workspaceManager.monitors
        let margin = CGFloat(settings.mouseWarpMargin)

        guard let currentMonitor = monitors.first(where: { $0.frame.contains(location) }) else {
            mouseWarpClampCursorToNearestMonitor(location: location, monitors: monitors, margin: margin)
            return
        }

        if let lastMonitorId = mouseWarpState.lastMonitorId {
            if let lastMonitor = monitors.first(where: { $0.id == lastMonitorId }) {
                if lastMonitor.id != currentMonitor.id {
                    mouseWarpBackToMonitor(lastMonitor, location: location, margin: margin)
                    return
                }
            } else {
                mouseWarpState.lastMonitorId = currentMonitor.id
            }
        } else {
            mouseWarpState.lastMonitorId = currentMonitor.id
        }

        mouseWarpState.lastMonitorId = currentMonitor.id
        guard let currentIndex = monitorOrder.firstIndex(of: currentMonitor.name) else { return }

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

        mouseWarpState.isWarping = true
        mouseWarpState.lastMonitorId = monitor.id
        let warpPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(x: clampedX, y: clampedY))
        CGWarpMouseCursorPosition(warpPoint)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.mouseWarpCooldownSeconds) { [weak self] in
            self?.mouseWarpState.isWarping = false
        }
    }

    private func mouseWarpClampCursorToNearestMonitor(location: CGPoint, monitors: [Monitor], margin: CGFloat) {
        if let lastMonitorId = mouseWarpState.lastMonitorId,
           let lastMonitor = monitors.first(where: { $0.id == lastMonitorId })
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
            mouseWarpState.isWarping = true
            let warpPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(x: location.x, y: clampedY))
            CGWarpMouseCursorPosition(warpPoint)

            DispatchQueue.main.asyncAfter(deadline: .now() + Self.mouseWarpCooldownSeconds) { [weak self] in
                self?.mouseWarpState.isWarping = false
            }
        }
    }

    private func mouseWarpToMonitor(named name: String, edge: MouseWarpEdge, yRatio: CGFloat, monitors: [Monitor], margin: CGFloat) {
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

        mouseWarpState.isWarping = true
        mouseWarpState.lastMonitorId = targetMonitor.id
        let warpPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(x: x, y: y))

        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: warpPoint, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.mouseWarpCooldownSeconds) { [weak self] in
            self?.mouseWarpState.isWarping = false
        }
    }
}

fileprivate enum MouseWarpEdge {
    case left
    case right
}
