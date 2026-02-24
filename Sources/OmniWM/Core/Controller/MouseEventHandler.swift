import AppKit
import Foundation

@MainActor
final class MouseEventHandler {
    struct State {
        enum GesturePhase {
            case idle
            case armed
            case committed
        }

        var eventTap: CFMachPort?
        var runLoopSource: CFRunLoopSource?
        var gestureTap: CFMachPort?
        var gestureRunLoopSource: CFRunLoopSource?
        var currentHoveredEdges: ResizeEdge = []
        var isResizing: Bool = false
        var isMoving: Bool = false

        var lastFocusFollowsMouseTime: Date = .distantPast
        var lastFocusFollowsMouseHandle: WindowHandle?
        let focusFollowsMouseDebounce: TimeInterval = 0.1
        var dragGhostController: DragGhostController?
        var moveIsInsertMode: Bool = false

        var gesturePhase: GesturePhase = .idle
        var gestureStartX: CGFloat = 0.0
        var gestureStartY: CGFloat = 0.0
        var gestureLastDeltaX: CGFloat = 0.0
    }

    nonisolated(unsafe) static weak var _instance: MouseEventHandler?

    weak var controller: WMController?
    var state = State()

    init(controller: WMController) {
        self.controller = controller
    }

    func setup() {
        MouseEventHandler._instance = self

        let eventMask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = MouseEventHandler._instance?.state.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let location = event.location
            let screenLocation = ScreenCoordinateSpace.toAppKit(point: location)

            switch type {
            case .mouseMoved:
                Task { @MainActor in
                    MouseEventHandler._instance?.handleMouseMovedFromTap(at: screenLocation)
                }
            case .leftMouseDown:
                let modifiers = event.flags
                Task { @MainActor in
                    guard let instance = MouseEventHandler._instance else { return }
                    guard let controller = instance.controller else { return }
                    if controller.isPointInOwnWindow(screenLocation) {
                        return
                    }
                    instance.handleMouseDownFromTap(at: screenLocation, modifiers: modifiers)
                }
            case .leftMouseDragged:
                Task { @MainActor in
                    MouseEventHandler._instance?.handleMouseDraggedFromTap(at: screenLocation)
                }
            case .leftMouseUp:
                Task { @MainActor in
                    MouseEventHandler._instance?.handleMouseUpFromTap(at: screenLocation)
                }
            case .scrollWheel:
                let deltaX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
                let deltaY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
                let momentumPhase = UInt32(event.getIntegerValueField(.scrollWheelEventMomentumPhase))
                let phase = UInt32(event.getIntegerValueField(.scrollWheelEventScrollPhase))
                let modifiers = event.flags
                Task { @MainActor in
                    MouseEventHandler._instance?.handleScrollWheelFromTap(
                        at: screenLocation,
                        deltaX: CGFloat(deltaX),
                        deltaY: CGFloat(deltaY),
                        momentumPhase: momentumPhase,
                        phase: phase,
                        modifiers: modifiers
                    )
                }
            default:
                break
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

        let gestureMask: CGEventMask = UInt64(NSEvent.EventTypeMask.gesture.rawValue)

        let gestureCallback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = MouseEventHandler._instance?.state.gestureTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            if type.rawValue == NSEvent.EventType.gesture.rawValue {
                Task { @MainActor in
                    MouseEventHandler._instance?.handleGestureEventFromTap(event)
                }
            }

            return Unmanaged.passUnretained(event)
        }

        state.gestureTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: gestureMask,
            callback: gestureCallback,
            userInfo: nil
        )

        if let tap = state.gestureTap {
            state.gestureRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source = state.gestureRunLoopSource {
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
        if let source = state.gestureRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            state.gestureRunLoopSource = nil
        }
        if let tap = state.gestureTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            state.gestureTap = nil
        }
        MouseEventHandler._instance = nil
        state.currentHoveredEdges = []
        state.isResizing = false
        state.gesturePhase = .idle
    }

    private func handleMouseMovedFromTap(at location: CGPoint) {
        guard let controller else { return }
        guard controller.isEnabled else {
            if !state.currentHoveredEdges.isEmpty {
                NSCursor.arrow.set()
                state.currentHoveredEdges = []
            }
            return
        }
        if controller.isOverviewOpen() { return }

        if controller.isPointInOwnWindow(location) {
            if !state.currentHoveredEdges.isEmpty {
                NSCursor.arrow.set()
                state.currentHoveredEdges = []
            }
            return
        }

        if controller.focusFollowsMouseEnabled, !state.isResizing {
            handleFocusFollowsMouse(at: location)
        }

        guard !state.isResizing else { return }

        guard let engine = controller.niriEngine,
              let wsId = controller.activeWorkspace()?.id
        else {
            if !state.currentHoveredEdges.isEmpty {
                NSCursor.arrow.set()
                state.currentHoveredEdges = []
            }
            return
        }

        if let hitResult = engine.hitTestResize(point: location, in: wsId) {
            if hitResult.edges != state.currentHoveredEdges {
                hitResult.edges.cursor.set()
                state.currentHoveredEdges = hitResult.edges
            }
        } else {
            if !state.currentHoveredEdges.isEmpty {
                NSCursor.arrow.set()
                state.currentHoveredEdges = []
            }
        }
    }

    private func handleMouseDownFromTap(at location: CGPoint, modifiers: CGEventFlags) {
        guard let controller else { return }
        guard controller.isEnabled else { return }
        if controller.isOverviewOpen() { return }

        if controller.isPointInOwnWindow(location) {
            return
        }

        guard let engine = controller.niriEngine,
              let wsId = controller.activeWorkspace()?.id
        else {
            return
        }

        if modifiers.contains(.maskAlternate) {
            if let tiledWindow = engine.hitTestTiled(point: location, in: wsId),
               let monitor = controller.workspaceManager.monitor(for: wsId)
            {
                let workingFrame = controller.insetWorkingFrame(for: monitor)
                let gaps = CGFloat(controller.workspaceManager.gaps)

                let isInsertMode = modifiers.contains(.maskShift)
                var moveStarted = false
                controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
                    if engine.interactiveMoveBegin(
                        windowId: tiledWindow.id,
                        windowHandle: tiledWindow.handle,
                        startLocation: location,
                        isInsertMode: isInsertMode,
                        in: wsId,
                        state: &vstate,
                        workingFrame: workingFrame,
                        gaps: gaps
                    ) {
                        moveStarted = true
                    }
                }
                if moveStarted {
                    state.moveIsInsertMode = isInsertMode
                    state.isMoving = true
                    NSCursor.closedHand.set()

                    if let entry = controller.workspaceManager.entry(for: tiledWindow.handle),
                       let frame = AXWindowService.framePreferFast(entry.axRef)
                    {
                        if state.dragGhostController == nil {
                            state.dragGhostController = DragGhostController()
                        }
                        state.dragGhostController?.beginDrag(
                            windowId: entry.windowId,
                            originalFrame: frame,
                            cursorLocation: location
                        )
                    }
                    return
                }
            }
        }

        guard !state.currentHoveredEdges.isEmpty else { return }

        if let hitResult = engine.hitTestResize(point: location, in: wsId) {
            let currentViewOffset = controller.workspaceManager.niriViewportState(for: wsId).viewOffsetPixels.current()
            if engine.interactiveResizeBegin(
                windowId: hitResult.nodeId,
                edges: hitResult.edges,
                startLocation: location,
                in: wsId,
                viewOffset: currentViewOffset
            ) {
                state.isResizing = true
                controller.niriLayoutHandler.cancelActiveAnimations(for: wsId)
                hitResult.edges.cursor.set()
            }
        }
    }

    private func handleMouseDraggedFromTap(at _: CGPoint) {
        guard let controller else { return }
        guard controller.isEnabled else { return }
        if controller.isOverviewOpen() { return }
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }

        let location = NSEvent.mouseLocation

        if state.isMoving {
            guard let engine = controller.niriEngine,
                  let wsId = controller.activeWorkspace()?.id
            else {
                return
            }

            let hoverTarget = engine.interactiveMoveUpdate(currentLocation: location, in: wsId)
            state.dragGhostController?.updatePosition(cursorLocation: location)

            if let hoverTarget {
                switch hoverTarget {
                case let .window(nodeId, handle, insertPosition):
                    if insertPosition == .swap {
                        if let entry = controller.workspaceManager.entry(for: handle),
                           let frame = AXWindowService.framePreferFast(entry.axRef)
                        {
                            state.dragGhostController?.showSwapTarget(frame: frame)
                        }
                    } else if let wsId = controller.activeWorkspace()?.id,
                              let dropFrame = engine.insertionDropzoneFrame(
                                  targetWindowId: nodeId,
                                  position: insertPosition,
                                  in: wsId,
                                  gaps: CGFloat(controller.workspaceManager.gaps)
                              )
                    {
                        state.dragGhostController?.showSwapTarget(frame: dropFrame)
                    }
                default:
                    state.dragGhostController?.hideSwapTarget()
                }
            } else {
                state.dragGhostController?.hideSwapTarget()
            }
            return
        }

        guard state.isResizing else { return }

        guard let engine = controller.niriEngine,
              let monitor = controller.monitorForInteraction()
        else {
            return
        }

        let gaps = LayoutGaps(
            horizontal: CGFloat(controller.workspaceManager.gaps),
            vertical: CGFloat(controller.workspaceManager.gaps),
            outer: controller.workspaceManager.outerGaps
        )
        let insetFrame = controller.insetWorkingFrame(for: monitor)
        guard let wsId = controller.activeWorkspace()?.id else { return }

        if engine.interactiveResizeUpdate(
            currentLocation: location,
            monitorFrame: insetFrame,
            gaps: gaps,
            viewportState: { mutate in
                controller.workspaceManager.withNiriViewportState(for: wsId, mutate)
            }
        ) {
            controller.layoutRefreshController.executeLayoutRefreshImmediate()
        }
    }

    private func handleMouseUpFromTap(at location: CGPoint) {
        guard let controller else { return }
        if controller.isOverviewOpen() { return }

        if state.isMoving {
            if let engine = controller.niriEngine,
               let wsId = controller.activeWorkspace()?.id,
               let monitor = controller.workspaceManager.monitor(for: wsId)
            {
                let workingFrame = controller.insetWorkingFrame(for: monitor)
                let gaps = CGFloat(controller.workspaceManager.gaps)
                var didEnd = false
                controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
                    didEnd = engine.interactiveMoveEnd(
                        at: location,
                        in: wsId,
                        state: &vstate,
                        workingFrame: workingFrame,
                        gaps: gaps
                    )
                }
                if didEnd {
                    controller.layoutRefreshController.executeLayoutRefreshImmediate()
                }
            }

            state.dragGhostController?.endDrag()
            state.isMoving = false
            state.moveIsInsertMode = false
            NSCursor.arrow.set()
            return
        }

        guard state.isResizing else { return }

        if let engine = controller.niriEngine,
           let wsId = controller.activeWorkspace()?.id,
           let monitor = controller.workspaceManager.monitor(for: wsId)
        {
            let workingFrame = controller.insetWorkingFrame(for: monitor)
            let gaps = CGFloat(controller.workspaceManager.gaps)

            controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
                engine.interactiveResizeEnd(
                    state: &vstate,
                    workingFrame: workingFrame,
                    gaps: gaps
                )
            }
            controller.layoutRefreshController.startScrollAnimation(for: wsId)
        }

        state.isResizing = false

        if let engine = controller.niriEngine,
           let wsId = controller.activeWorkspace()?.id,
           let hitResult = engine.hitTestResize(point: location, in: wsId)
        {
            hitResult.edges.cursor.set()
            state.currentHoveredEdges = hitResult.edges
        } else {
            NSCursor.arrow.set()
            state.currentHoveredEdges = []
        }
    }

    private func handleScrollWheelFromTap(
        at location: CGPoint,
        deltaX _: CGFloat,
        deltaY: CGFloat,
        momentumPhase: UInt32,
        phase: UInt32,
        modifiers: CGEventFlags
    ) {
        guard let controller else { return }
        guard controller.isEnabled, controller.settings.scrollGestureEnabled else { return }
        if controller.isOverviewOpen() { return }
        if controller.isPointInOwnWindow(location) { return }
        guard !state.isResizing, !state.isMoving else { return }
        guard let engine = controller.niriEngine, let wsId = controller.activeWorkspace()?.id else { return }

        let isTrackpad = momentumPhase != 0 || phase != 0
        if isTrackpad {
            return
        }

        guard modifiers.contains(controller.settings.scrollModifierKey.cgEventFlag) else {
            return
        }

        let scrollDeltaX: CGFloat = if modifiers.contains(.maskShift) {
            deltaY
        } else {
            -deltaY
        }

        guard abs(scrollDeltaX) > 0.5 else { return }

        let sensitivity = CGFloat(controller.settings.scrollSensitivity)
        let adjustedDelta = scrollDeltaX * sensitivity

        applyMouseViewportScrollDelta(adjustedDelta, isTrackpad: false, engine: engine, wsId: wsId)
    }

    private func handleFocusFollowsMouse(at location: CGPoint) {
        guard let controller else { return }
        guard !controller.focusManager.isNonManagedFocusActive, !controller.focusManager.isAppFullscreenActive else {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(state.lastFocusFollowsMouseTime) >= state.focusFollowsMouseDebounce else {
            return
        }

        guard let engine = controller.niriEngine,
              let wsId = controller.activeWorkspace()?.id
        else {
            return
        }

        if let tiledWindow = engine.hitTestTiled(point: location, in: wsId) {
            let handle = tiledWindow.handle
            if handle != state.lastFocusFollowsMouseHandle, handle != controller.focusedHandle {
                state.lastFocusFollowsMouseTime = now
                state.lastFocusFollowsMouseHandle = handle
                controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
                    controller.niriLayoutHandler.activateNode(tiledWindow, in: wsId, state: &vstate)
                }
            }
            return
        }
    }

    private func handleGestureEventFromTap(_ cgEvent: CGEvent) {
        let screenLocation = ScreenCoordinateSpace.toAppKit(point: cgEvent.location)
        guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return }
        handleGestureEvent(nsEvent, at: screenLocation)
    }

    private func handleGestureEvent(_ event: NSEvent, at location: CGPoint) {
        guard let controller else { return }
        guard controller.isEnabled, controller.settings.scrollGestureEnabled else { return }
        if controller.isOverviewOpen() { return }
        if controller.isPointInOwnWindow(location) { return }
        guard !state.isResizing, !state.isMoving else { return }
        guard let engine = controller.niriEngine, let wsId = controller.activeWorkspace()?.id else { return }

        let requiredFingers = controller.settings.gestureFingerCount.rawValue
        let invertDirection = controller.settings.gestureInvertDirection

        let phase = event.phase
        if phase == .ended || phase == .cancelled {
            if state.gesturePhase == .committed {
                guard let monitor = controller.monitorForInteraction() else {
                    resetGestureState()
                    return
                }
                let insetFrame = controller.insetWorkingFrame(for: monitor)
                let columns = engine.columns(in: wsId)
                let gap = CGFloat(controller.workspaceManager.gaps)

                controller.workspaceManager.withNiriViewportState(for: wsId) { endState in
                    endState.endGesture(
                        columns: columns,
                        gap: gap,
                        viewportWidth: insetFrame.width,
                        centerMode: engine.centerFocusedColumn,
                        alwaysCenterSingleColumn: engine.alwaysCenterSingleColumn
                    )
                }
                controller.layoutRefreshController.startScrollAnimation(for: wsId)
            }
            resetGestureState()
            return
        }

        if phase == .began {
            resetGestureState()
        }

        let touches = event.allTouches()
        guard !touches.isEmpty else {
            resetGestureState()
            return
        }

        var sumX: CGFloat = 0.0
        var sumY: CGFloat = 0.0
        var touchCount = 0
        var activeCount = 0
        var tooManyTouches = false

        for touch in touches {
            let touchPhase = touch.phase
            if touchPhase == .ended || touchPhase == .cancelled {
                continue
            }

            touchCount += 1
            if touchCount > requiredFingers {
                tooManyTouches = true
                break
            }

            let pos = touch.normalizedPosition
            sumX += pos.x
            sumY += pos.y
            activeCount += 1
        }

        if tooManyTouches || touchCount != requiredFingers || activeCount == 0 {
            resetGestureState()
            return
        }

        let avgX = sumX / CGFloat(activeCount)
        let avgY = sumY / CGFloat(activeCount)

        switch state.gesturePhase {
        case .idle:
            state.gestureStartX = avgX
            state.gestureStartY = avgY
            state.gestureLastDeltaX = 0.0
            state.gesturePhase = .armed

        case .armed, .committed:
            let dx = avgX - state.gestureStartX
            let currentDeltaX = dx
            let deltaNorm = currentDeltaX - state.gestureLastDeltaX
            state.gestureLastDeltaX = currentDeltaX

            var deltaUnits = deltaNorm * CGFloat(controller.settings.scrollSensitivity) * 500.0
            if invertDirection {
                deltaUnits = -deltaUnits
            }

            if abs(deltaUnits) < 0.5 {
                state.gesturePhase = .committed
                return
            }

            state.gesturePhase = .committed

            applyMouseViewportScrollDelta(deltaUnits, isTrackpad: true, engine: engine, wsId: wsId)
        }
    }

    private func applyMouseViewportScrollDelta(
        _ delta: CGFloat,
        isTrackpad: Bool,
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID
    ) {
        guard let controller else { return }
        guard let monitor = controller.monitorForInteraction() else { return }
        let insetFrame = controller.insetWorkingFrame(for: monitor)
        let viewportWidth = insetFrame.width
        let gap = CGFloat(controller.workspaceManager.gaps)
        let columns = engine.columns(in: wsId)

        var targetWindowHandle: WindowHandle?
        controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
            if vstate.viewOffsetPixels.isAnimating {
                vstate.cancelAnimation()
            }

            if !vstate.viewOffsetPixels.isGesture {
                vstate.beginGesture(isTrackpad: isTrackpad)
            }

            let timestamp = CACurrentMediaTime()
            if let steps = vstate.updateGesture(
                deltaPixels: delta,
                timestamp: timestamp,
                columns: columns,
                gap: gap,
                viewportWidth: viewportWidth
            ) {
                if let currentId = vstate.selectedNodeId,
                   let currentNode = engine.findNode(by: currentId),
                   let newNode = engine.moveSelectionByColumns(
                       steps: steps,
                       currentSelection: currentNode,
                       in: wsId
                   )
                {
                    vstate.selectedNodeId = newNode.id

                    if let windowNode = newNode as? NiriWindow {
                        controller.focusManager.setFocus(windowNode.handle, in: wsId)
                        engine.updateFocusTimestamp(for: windowNode.id)
                        targetWindowHandle = windowNode.handle
                    }
                }
            }
        }
        controller.layoutRefreshController.executeLayoutRefreshImmediate()

        if let handle = targetWindowHandle {
            controller.focusWindow(handle)
        }
    }

    private func resetGestureState() {
        state.gesturePhase = .idle
        state.gestureStartX = 0.0
        state.gestureStartY = 0.0
        state.gestureLastDeltaX = 0.0
    }
}
