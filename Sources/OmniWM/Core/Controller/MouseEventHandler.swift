import AppKit
import Foundation

extension WMController {
    struct MouseEventState {
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

    private nonisolated(unsafe) static weak var _mouseInstance: WMController?

    func mouseSetup() {
        WMController._mouseInstance = self

        let eventMask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = WMController._mouseInstance?.mouseEventState.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let location = event.location
            let screenLocation = ScreenCoordinateSpace.toAppKit(point: location)

            switch type {
            case .mouseMoved:
                Task { @MainActor in
                    WMController._mouseInstance?.handleMouseMovedFromTap(at: screenLocation)
                }
            case .leftMouseDown:
                let modifiers = event.flags
                Task { @MainActor in
                    guard let instance = WMController._mouseInstance else { return }
                    if instance.isPointInOwnWindow(screenLocation) {
                        return
                    }
                    instance.handleMouseDownFromTap(at: screenLocation, modifiers: modifiers)
                }
            case .leftMouseDragged:
                Task { @MainActor in
                    WMController._mouseInstance?.handleMouseDraggedFromTap(at: screenLocation)
                }
            case .leftMouseUp:
                Task { @MainActor in
                    WMController._mouseInstance?.handleMouseUpFromTap(at: screenLocation)
                }
            case .scrollWheel:
                let deltaX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
                let deltaY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
                let momentumPhase = UInt32(event.getIntegerValueField(.scrollWheelEventMomentumPhase))
                let phase = UInt32(event.getIntegerValueField(.scrollWheelEventScrollPhase))
                let modifiers = event.flags
                Task { @MainActor in
                    WMController._mouseInstance?.handleScrollWheelFromTap(
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

        mouseEventState.eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: nil
        )

        if let tap = mouseEventState.eventTap {
            mouseEventState.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source = mouseEventState.runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        let gestureMask: CGEventMask = UInt64(NSEvent.EventTypeMask.gesture.rawValue)

        let gestureCallback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = WMController._mouseInstance?.mouseEventState.gestureTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            if type.rawValue == NSEvent.EventType.gesture.rawValue {
                Task { @MainActor in
                    WMController._mouseInstance?.handleGestureEventFromTap(event)
                }
            }

            return Unmanaged.passUnretained(event)
        }

        mouseEventState.gestureTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: gestureMask,
            callback: gestureCallback,
            userInfo: nil
        )

        if let tap = mouseEventState.gestureTap {
            mouseEventState.gestureRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source = mouseEventState.gestureRunLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    func mouseCleanup() {
        if let source = mouseEventState.runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            mouseEventState.runLoopSource = nil
        }
        if let tap = mouseEventState.eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            mouseEventState.eventTap = nil
        }
        if let source = mouseEventState.gestureRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            mouseEventState.gestureRunLoopSource = nil
        }
        if let tap = mouseEventState.gestureTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            mouseEventState.gestureTap = nil
        }
        WMController._mouseInstance = nil
        mouseEventState.currentHoveredEdges = []
        mouseEventState.isResizing = false
        mouseEventState.gesturePhase = .idle
    }

    private func handleMouseMovedFromTap(at location: CGPoint) {
        guard isEnabled else {
            if !mouseEventState.currentHoveredEdges.isEmpty {
                NSCursor.arrow.set()
                mouseEventState.currentHoveredEdges = []
            }
            return
        }

        if isPointInOwnWindow(location) {
            if !mouseEventState.currentHoveredEdges.isEmpty {
                NSCursor.arrow.set()
                mouseEventState.currentHoveredEdges = []
            }
            return
        }

        if focusFollowsMouseEnabled, !mouseEventState.isResizing {
            handleFocusFollowsMouse(at: location)
        }

        guard !mouseEventState.isResizing else { return }

        guard let engine = niriEngine,
              let wsId = activeWorkspace()?.id
        else {
            if !mouseEventState.currentHoveredEdges.isEmpty {
                NSCursor.arrow.set()
                mouseEventState.currentHoveredEdges = []
            }
            return
        }

        if let hitResult = engine.hitTestResize(point: location, in: wsId) {
            if hitResult.edges != mouseEventState.currentHoveredEdges {
                hitResult.edges.cursor.set()
                mouseEventState.currentHoveredEdges = hitResult.edges
            }
        } else {
            if !mouseEventState.currentHoveredEdges.isEmpty {
                NSCursor.arrow.set()
                mouseEventState.currentHoveredEdges = []
            }
        }
    }

    private func handleMouseDownFromTap(at location: CGPoint, modifiers: CGEventFlags) {
        guard isEnabled else { return }

        if isPointInOwnWindow(location) {
            return
        }

        guard let engine = niriEngine,
              let wsId = activeWorkspace()?.id
        else {
            return
        }

        if modifiers.contains(.maskAlternate) {
            if let tiledWindow = engine.hitTestTiled(point: location, in: wsId),
               let monitor = workspaceManager.monitor(for: wsId)
            {
                var state = workspaceManager.niriViewportState(for: wsId)
                let workingFrame = insetWorkingFrame(for: monitor)
                let gaps = CGFloat(workspaceManager.gaps)

                let isInsertMode = modifiers.contains(.maskShift)
                if engine.interactiveMoveBegin(
                    windowId: tiledWindow.id,
                    windowHandle: tiledWindow.handle,
                    startLocation: location,
                    isInsertMode: isInsertMode,
                    in: wsId,
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gaps
                ) {
                    mouseEventState.moveIsInsertMode = isInsertMode
                    workspaceManager.updateNiriViewportState(state, for: wsId)
                    mouseEventState.isMoving = true
                    NSCursor.closedHand.set()

                    if let entry = workspaceManager.entry(for: tiledWindow.handle),
                       let frame = AXWindowService.framePreferFast(entry.axRef)
                    {
                        if mouseEventState.dragGhostController == nil {
                            mouseEventState.dragGhostController = DragGhostController()
                        }
                        mouseEventState.dragGhostController?.beginDrag(
                            windowId: entry.windowId,
                            originalFrame: frame,
                            cursorLocation: location
                        )
                    }
                    return
                }
            }
        }

        guard !mouseEventState.currentHoveredEdges.isEmpty else { return }

        if let hitResult = engine.hitTestResize(point: location, in: wsId) {
            if engine.interactiveResizeBegin(
                windowId: hitResult.nodeId,
                edges: hitResult.edges,
                startLocation: location,
                in: wsId
            ) {
                mouseEventState.isResizing = true
                cancelActiveAnimations(for: wsId)
                hitResult.edges.cursor.set()
            }
        }
    }

    private func handleMouseDraggedFromTap(at _: CGPoint) {
        guard isEnabled else { return }
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }

        let location = NSEvent.mouseLocation

        if mouseEventState.isMoving {
            guard let engine = niriEngine,
                  let wsId = activeWorkspace()?.id
            else {
                return
            }

            let hoverTarget = engine.interactiveMoveUpdate(currentLocation: location, in: wsId)
            mouseEventState.dragGhostController?.updatePosition(cursorLocation: location)

            if let hoverTarget {
                switch hoverTarget {
                case let .window(nodeId, handle, insertPosition):
                    if insertPosition == .swap {
                        if let entry = workspaceManager.entry(for: handle),
                           let frame = AXWindowService.framePreferFast(entry.axRef)
                        {
                            mouseEventState.dragGhostController?.showSwapTarget(frame: frame)
                        }
                    } else if let wsId = activeWorkspace()?.id,
                              let dropFrame = engine.insertionDropzoneFrame(
                                  targetWindowId: nodeId,
                                  position: insertPosition,
                                  in: wsId,
                                  gaps: CGFloat(workspaceManager.gaps)
                              )
                    {
                        mouseEventState.dragGhostController?.showSwapTarget(frame: dropFrame)
                    }
                default:
                    mouseEventState.dragGhostController?.hideSwapTarget()
                }
            } else {
                mouseEventState.dragGhostController?.hideSwapTarget()
            }
            return
        }

        guard mouseEventState.isResizing else { return }

        guard let engine = niriEngine,
              let monitor = monitorForInteraction()
        else {
            return
        }

        let gaps = LayoutGaps(
            horizontal: CGFloat(workspaceManager.gaps),
            vertical: CGFloat(workspaceManager.gaps),
            outer: workspaceManager.outerGaps
        )
        let insetFrame = insetWorkingFrame(for: monitor)

        if engine.interactiveResizeUpdate(
            currentLocation: location,
            monitorFrame: insetFrame,
            gaps: gaps
        ) {
            executeLayoutRefreshImmediate()
        }
    }

    private func handleMouseUpFromTap(at location: CGPoint) {
        if mouseEventState.isMoving {
            if let engine = niriEngine,
               let wsId = activeWorkspace()?.id,
               let monitor = workspaceManager.monitor(for: wsId)
            {
                var state = workspaceManager.niriViewportState(for: wsId)
                let workingFrame = insetWorkingFrame(for: monitor)
                let gaps = CGFloat(workspaceManager.gaps)
                if engine.interactiveMoveEnd(
                    at: location,
                    in: wsId,
                    state: &state,
                    workingFrame: workingFrame,
                    gaps: gaps
                ) {
                    workspaceManager.updateNiriViewportState(state, for: wsId)
                    executeLayoutRefreshImmediate()
                }
            }

            mouseEventState.dragGhostController?.endDrag()
            mouseEventState.isMoving = false
            mouseEventState.moveIsInsertMode = false
            NSCursor.arrow.set()
            return
        }

        guard mouseEventState.isResizing else { return }

        if let engine = niriEngine,
           let wsId = activeWorkspace()?.id,
           let monitor = workspaceManager.monitor(for: wsId)
        {
            var state = workspaceManager.niriViewportState(for: wsId)
            let workingFrame = insetWorkingFrame(for: monitor)
            let gaps = CGFloat(workspaceManager.gaps)

            engine.interactiveResizeEnd(
                state: &state,
                workingFrame: workingFrame,
                gaps: gaps
            )
            workspaceManager.updateNiriViewportState(state, for: wsId)
            startScrollAnimation(for: wsId)
        }

        mouseEventState.isResizing = false

        if let engine = niriEngine,
           let wsId = activeWorkspace()?.id,
           let hitResult = engine.hitTestResize(point: location, in: wsId)
        {
            hitResult.edges.cursor.set()
            mouseEventState.currentHoveredEdges = hitResult.edges
        } else {
            NSCursor.arrow.set()
            mouseEventState.currentHoveredEdges = []
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
        guard isEnabled, settings.scrollGestureEnabled else { return }
        if isPointInOwnWindow(location) { return }
        guard !mouseEventState.isResizing, !mouseEventState.isMoving else { return }
        guard let engine = niriEngine, let wsId = activeWorkspace()?.id else { return }

        let isTrackpad = momentumPhase != 0 || phase != 0
        if isTrackpad {
            return
        }

        guard modifiers.contains(settings.scrollModifierKey.cgEventFlag) else {
            return
        }

        let scrollDeltaX: CGFloat = if modifiers.contains(.maskShift) {
            deltaY
        } else {
            -deltaY
        }

        guard abs(scrollDeltaX) > 0.5 else { return }

        let sensitivity = CGFloat(settings.scrollSensitivity)
        let adjustedDelta = scrollDeltaX * sensitivity

        applyMouseViewportScrollDelta(adjustedDelta, isTrackpad: false, engine: engine, wsId: wsId)
    }

    private func handleFocusFollowsMouse(at location: CGPoint) {
        guard !isNonManagedFocusActive, !isAppFullscreenActive else {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(mouseEventState.lastFocusFollowsMouseTime) >= mouseEventState.focusFollowsMouseDebounce else {
            return
        }

        guard let engine = niriEngine,
              let wsId = activeWorkspace()?.id
        else {
            return
        }

        if let tiledWindow = engine.hitTestTiled(point: location, in: wsId) {
            let handle = tiledWindow.handle
            if handle != mouseEventState.lastFocusFollowsMouseHandle, handle != focusedHandle {
                mouseEventState.lastFocusFollowsMouseTime = now
                mouseEventState.lastFocusFollowsMouseHandle = handle
                var state = workspaceManager.niriViewportState(for: wsId)
                activateNode(tiledWindow, in: wsId, state: &state)
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
        guard isEnabled, settings.scrollGestureEnabled else { return }
        if isPointInOwnWindow(location) { return }
        guard !mouseEventState.isResizing, !mouseEventState.isMoving else { return }
        guard let engine = niriEngine, let wsId = activeWorkspace()?.id else { return }

        let requiredFingers = settings.gestureFingerCount.rawValue
        let invertDirection = settings.gestureInvertDirection

        let phase = event.phase
        if phase == .ended || phase == .cancelled {
            if mouseEventState.gesturePhase == .committed {
                guard let monitor = monitorForInteraction() else {
                    mouseResetGestureState()
                    return
                }
                let insetFrame = insetWorkingFrame(for: monitor)
                let columns = engine.columns(in: wsId)
                let gap = CGFloat(workspaceManager.gaps)

                var endState = workspaceManager.niriViewportState(for: wsId)
                endState.endGesture(
                    columns: columns,
                    gap: gap,
                    viewportWidth: insetFrame.width,
                    centerMode: engine.centerFocusedColumn,
                    alwaysCenterSingleColumn: engine.alwaysCenterSingleColumn
                )
                workspaceManager.updateNiriViewportState(endState, for: wsId)
                startScrollAnimation(for: wsId)
            }
            mouseResetGestureState()
            return
        }

        if phase == .began {
            mouseResetGestureState()
        }

        let touches = event.allTouches()
        guard !touches.isEmpty else {
            mouseResetGestureState()
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
            mouseResetGestureState()
            return
        }

        let avgX = sumX / CGFloat(activeCount)
        let avgY = sumY / CGFloat(activeCount)

        switch mouseEventState.gesturePhase {
        case .idle:
            mouseEventState.gestureStartX = avgX
            mouseEventState.gestureStartY = avgY
            mouseEventState.gestureLastDeltaX = 0.0
            mouseEventState.gesturePhase = .armed

        case .armed, .committed:
            let dx = avgX - mouseEventState.gestureStartX
            let currentDeltaX = dx
            let deltaNorm = currentDeltaX - mouseEventState.gestureLastDeltaX
            mouseEventState.gestureLastDeltaX = currentDeltaX

            var deltaUnits = deltaNorm * CGFloat(settings.scrollSensitivity) * 500.0
            if invertDirection {
                deltaUnits = -deltaUnits
            }

            if abs(deltaUnits) < 0.5 {
                mouseEventState.gesturePhase = .committed
                return
            }

            mouseEventState.gesturePhase = .committed

            applyMouseViewportScrollDelta(deltaUnits, isTrackpad: true, engine: engine, wsId: wsId)
        }
    }

    private func applyMouseViewportScrollDelta(
        _ delta: CGFloat,
        isTrackpad: Bool,
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID
    ) {
        var state = workspaceManager.niriViewportState(for: wsId)

        if state.viewOffsetPixels.isAnimating {
            state.cancelAnimation()
        }

        if !state.viewOffsetPixels.isGesture {
            state.beginGesture(isTrackpad: isTrackpad)
        }

        guard let monitor = monitorForInteraction() else { return }
        let insetFrame = insetWorkingFrame(for: monitor)
        let viewportWidth = insetFrame.width
        let gap = CGFloat(workspaceManager.gaps)
        let columns = engine.columns(in: wsId)

        let timestamp = CACurrentMediaTime()
        var targetWindowHandle: WindowHandle?
        if let steps = state.updateGesture(
            deltaPixels: delta,
            timestamp: timestamp,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth
        ) {
            if let currentId = state.selectedNodeId,
               let currentNode = engine.findNode(by: currentId),
               let newNode = engine.moveSelectionByColumns(
                   steps: steps,
                   currentSelection: currentNode,
                   in: wsId
               )
            {
                state.selectedNodeId = newNode.id

                if let windowNode = newNode as? NiriWindow {
                    focusedHandle = windowNode.handle
                    engine.updateFocusTimestamp(for: windowNode.id)
                    targetWindowHandle = windowNode.handle
                }
            }
        }

        workspaceManager.updateNiriViewportState(state, for: wsId)
        executeLayoutRefreshImmediate()

        if let handle = targetWindowHandle {
            focusWindow(handle)
        }
    }

    private func mouseResetGestureState() {
        mouseEventState.gesturePhase = .idle
        mouseEventState.gestureStartX = 0.0
        mouseEventState.gestureStartY = 0.0
        mouseEventState.gestureLastDeltaX = 0.0
    }
}
