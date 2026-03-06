import AppKit
import Foundation

@MainActor
final class MouseEventHandler {
    struct State {
        struct LockedGestureContext {
            let workspaceId: WorkspaceDescriptor.ID
            let monitorId: Monitor.ID
        }

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

        var gesturePhase: GesturePhase = .idle
        var gestureStartX: CGFloat = 0.0
        var gestureStartY: CGFloat = 0.0
        var gestureLastDeltaX: CGFloat = 0.0
        var lockedGestureContext: LockedGestureContext?
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
        resetGestureState()
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

        guard let context = resolveScrollContext(at: location) else {
            if !state.currentHoveredEdges.isEmpty {
                NSCursor.arrow.set()
                state.currentHoveredEdges = []
            }
            return
        }

        let request = makeHitTestRequest(wsId: context.wsId, monitor: context.monitor, orientation: context.orientation)
        if let hitResult = context.engine.hitTestResize(at: location, request) {
            let legacy = resizeEdges(from: hitResult.edges)
            if legacy != state.currentHoveredEdges {
                legacy.cursor.set()
                state.currentHoveredEdges = legacy
            }
        } else if !state.currentHoveredEdges.isEmpty {
            NSCursor.arrow.set()
            state.currentHoveredEdges = []
        }
    }

    private func handleMouseDownFromTap(at location: CGPoint, modifiers: CGEventFlags) {
        guard let controller else { return }
        guard controller.isEnabled else { return }
        if controller.isOverviewOpen() { return }
        if controller.isPointInOwnWindow(location) { return }

        guard let context = resolveScrollContext(at: location) else { return }

        let request = makeHitTestRequest(wsId: context.wsId, monitor: context.monitor, orientation: context.orientation)

        if modifiers.contains(.maskAlternate) {
            if let tiledWindow = context.engine.hitTestTiled(at: location, request) {
                let started = context.engine.beginInteractiveMove(
                    ZigNiriInteractiveMoveState(
                        windowId: tiledWindow.windowId,
                        workspaceId: context.wsId,
                        startMouseLocation: location,
                        monitorFrame: context.monitor.visibleFrame,
                        currentHoverTarget: nil
                    )
                )

                if started {
                    state.isMoving = true
                    NSCursor.closedHand.set()

                    if let entry = controller.workspaceManager.entry(for: tiledWindow.windowHandle),
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

        if let hitResult = context.engine.hitTestResize(at: location, request) {
            if context.engine.beginInteractiveResize(
                ZigNiriInteractiveResizeState(
                    windowId: hitResult.windowId,
                    workspaceId: context.wsId,
                    edges: hitResult.edges,
                    startMouseLocation: location
                )
            ) {
                state.isResizing = true
                controller.niriLayoutHandler.cancelActiveAnimations(for: context.wsId)
                resizeEdges(from: hitResult.edges).cursor.set()
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
            guard let context = resolveScrollContext(at: location) else {
                return
            }

            let hoverTarget = context.engine.updateInteractiveMove(mouseLocation: location)
            state.dragGhostController?.updatePosition(cursorLocation: location)

            if case let .window(_, handle, _) = hoverTarget,
               let entry = controller.workspaceManager.entry(for: handle),
               let frame = AXWindowService.framePreferFast(entry.axRef)
            {
                state.dragGhostController?.showSwapTarget(frame: frame)
            } else {
                state.dragGhostController?.hideSwapTarget()
            }
            return
        }

        guard state.isResizing else { return }
        guard let context = resolveScrollContext(at: location) else { return }

        let update = context.engine.updateInteractiveResize(mouseLocation: location)
        if update.applied {
            controller.layoutRefreshController.executeLayoutRefreshImmediate()
        }
    }

    private func handleMouseUpFromTap(at location: CGPoint) {
        guard let controller else { return }
        if controller.isOverviewOpen() { return }

        if state.isMoving {
            if let context = resolveScrollContext(at: location) {
                let result = context.engine.endInteractiveMove(commit: true)
                if result.applied {
                    controller.layoutRefreshController.executeLayoutRefreshImmediate()
                }
            }

            state.dragGhostController?.endDrag()
            state.isMoving = false
            NSCursor.arrow.set()
            return
        }

        guard state.isResizing else { return }

        if let context = resolveScrollContext(at: location) {
            _ = context.engine.endInteractiveResize(commit: true)
            controller.layoutRefreshController.startScrollAnimation(for: context.wsId)

            let request = makeHitTestRequest(wsId: context.wsId, monitor: context.monitor, orientation: context.orientation)
            if let hitResult = context.engine.hitTestResize(at: location, request) {
                let legacy = resizeEdges(from: hitResult.edges)
                legacy.cursor.set()
                state.currentHoveredEdges = legacy
            } else {
                NSCursor.arrow.set()
                state.currentHoveredEdges = []
            }
        }

        state.isResizing = false
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
        guard let context = resolveScrollContext(at: location) else { return }

        let sensitivity = CGFloat(controller.settings.scrollSensitivity)
        let adjustedDelta = scrollDeltaX * sensitivity

        applyMouseViewportScrollDelta(
            adjustedDelta,
            isTrackpad: false,
            engine: context.engine,
            wsId: context.wsId,
            monitor: context.monitor,
            orientation: context.orientation
        )
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

        guard let context = resolveScrollContext(at: location) else { return }
        let request = makeHitTestRequest(wsId: context.wsId, monitor: context.monitor, orientation: context.orientation)

        if let tiledWindow = context.engine.hitTestTiled(at: location, request) {
            let handle = tiledWindow.windowHandle
            if handle != state.lastFocusFollowsMouseHandle, handle != controller.focusedHandle {
                state.lastFocusFollowsMouseTime = now
                state.lastFocusFollowsMouseHandle = handle

                _ = context.engine.applyWorkspace(
                    .setSelection(
                        ZigNiriSelection(
                            selectedNodeId: tiledWindow.windowId,
                            focusedWindowId: tiledWindow.windowId
                        )
                    ),
                    in: context.wsId
                )
                controller.workspaceManager.withNiriViewportState(for: context.wsId) { vstate in
                    vstate.selectedNodeId = tiledWindow.windowId
                }
                controller.focusManager.setFocus(handle, in: context.wsId)
                controller.focusWindow(handle)
            }
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

        let requiredFingers = controller.settings.gestureFingerCount.rawValue
        let invertDirection = controller.settings.gestureInvertDirection

        let phase = event.phase
        if phase == .ended || phase == .cancelled {
            if state.gesturePhase == .committed {
                guard let lockedContext = state.lockedGestureContext else {
                    assertionFailure("Committed gesture missing locked context")
                    resetGestureState()
                    return
                }
                finalizeOrCancelCommittedGesture(using: lockedContext)
            }
            resetGestureState()
            return
        }

        if phase == .began {
            resetGestureState()
        }

        guard resolveScrollContext(at: location) != nil else {
            resetGestureState()
            return
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
            guard let currentContext = resolveScrollContext(at: location) else {
                resetGestureState()
                return
            }
            state.lockedGestureContext = .init(
                workspaceId: currentContext.wsId,
                monitorId: currentContext.monitor.id
            )
            state.gestureStartX = avgX
            state.gestureStartY = avgY
            state.gestureLastDeltaX = 0.0
            state.gesturePhase = .armed

        case .armed, .committed:
            guard let lockedContext = state.lockedGestureContext else {
                assertionFailure("Active gesture missing locked context")
                resetGestureState()
                return
            }
            let wsId = lockedContext.workspaceId
            guard let monitor = controller.workspaceManager.monitor(byId: lockedContext.monitorId) else {
                if state.gesturePhase == .committed {
                    cancelCommittedGestureViewportState(for: wsId)
                }
                resetGestureState()
                return
            }

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

            let orientation = controller.settings.effectiveOrientation(for: monitor)
            guard let engine = controller.zigNiriEngine else { return }
            applyMouseViewportScrollDelta(
                deltaUnits,
                isTrackpad: true,
                engine: engine,
                wsId: wsId,
                monitor: monitor,
                orientation: orientation
            )
        }
    }

    private func applyMouseViewportScrollDelta(
        _ delta: CGFloat,
        isTrackpad: Bool,
        engine: ZigNiriEngine,
        wsId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        orientation: Monitor.Orientation
    ) {
        guard let controller else { return }
        let insetFrame = controller.insetWorkingFrame(for: monitor)
        let viewportSpan = orientation == .horizontal ? insetFrame.width : insetFrame.height
        let gap = CGFloat(controller.workspaceManager.gaps)

        var targetWindowHandle: WindowHandle?

        controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
            _ = controller.syncZigNiriWorkspace(workspaceId: wsId, selectedNodeId: vstate.selectedNodeId)
            guard let view = engine.workspaceView(for: wsId) else { return }
            let columnSpans = columnSpans(for: view, orientation: orientation, fallbackFrame: insetFrame)

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
                columnSpans: columnSpans,
                gap: gap,
                viewportSpan: viewportSpan
            ), steps != 0 {
                let stepDirection: Direction = if orientation == .horizontal {
                    steps > 0 ? .right : .left
                } else {
                    steps > 0 ? .down : .up
                }

                for _ in 0 ..< abs(steps) {
                    let result = engine.applyNavigation(
                        .focus(direction: stepDirection),
                        in: wsId,
                        orientation: orientation,
                        selection: ZigNiriSelection(
                            selectedNodeId: vstate.selectedNodeId,
                            focusedWindowId: controller.focusedHandle.flatMap { controller.zigNodeId(for: $0, workspaceId: wsId) }
                        )
                    )
                    vstate.selectedNodeId = result.selection?.selectedNodeId
                    controller.workspaceManager.setSelection(result.selection?.selectedNodeId, for: wsId)
                }

                if let selectedNodeId = vstate.selectedNodeId,
                   let newHandle = controller.zigWindowHandle(for: selectedNodeId, workspaceId: wsId)
                {
                    controller.focusManager.setFocus(newHandle, in: wsId)
                    targetWindowHandle = newHandle
                }
            }
        }

        controller.layoutRefreshController.executeLayoutRefreshImmediate()
        if let handle = targetWindowHandle {
            controller.focusWindow(handle)
        }
    }

    private func finalizeOrCancelCommittedGesture(using lockedContext: State.LockedGestureContext) {
        guard let controller,
              let engine = controller.zigNiriEngine
        else {
            return
        }

        let wsId = lockedContext.workspaceId
        guard let monitor = controller.workspaceManager.monitor(byId: lockedContext.monitorId) else {
            cancelCommittedGestureViewportState(for: wsId)
            return
        }

        let orientation = controller.settings.effectiveOrientation(for: monitor)
        let insetFrame = controller.insetWorkingFrame(for: monitor)
        let viewportSpan = orientation == .horizontal ? insetFrame.width : insetFrame.height
        let gap = CGFloat(controller.workspaceManager.gaps)
        let resolved = controller.settings.resolvedNiriSettings(for: monitor)

        controller.workspaceManager.withNiriViewportState(for: wsId) { endState in
            _ = controller.syncZigNiriWorkspace(workspaceId: wsId, selectedNodeId: endState.selectedNodeId)
            guard let view = engine.workspaceView(for: wsId) else { return }
            let spans = columnSpans(for: view, orientation: orientation, fallbackFrame: insetFrame)

            endState.endGesture(
                columnSpans: spans,
                gap: gap,
                viewportSpan: viewportSpan,
                centerMode: resolved.centerFocusedColumn,
                alwaysCenterSingleColumn: resolved.alwaysCenterSingleColumn
            )
        }
        controller.layoutRefreshController.startScrollAnimation(for: wsId)
    }

    private func cancelCommittedGestureViewportState(for wsId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        var didCancel = false
        controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
            guard vstate.viewOffsetPixels.isGesture else { return }
            vstate.cancelAnimation()
            vstate.selectionProgress = 0.0
            didCancel = true
        }
        if didCancel {
            controller.layoutRefreshController.executeLayoutRefreshImmediate()
        }
    }

    private func resolveScrollContext(at location: CGPoint) -> (
        engine: ZigNiriEngine,
        wsId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        orientation: Monitor.Orientation
    )? {
        guard let controller,
              let engine = controller.zigNiriEngine
        else {
            return nil
        }

        let monitors = controller.workspaceManager.monitors
        guard let monitor = location.monitorApproximation(in: monitors),
              let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        else {
            return nil
        }

        let orientation = controller.settings.effectiveOrientation(for: monitor)
        return (engine, workspace.id, monitor, orientation)
    }

    private func makeHitTestRequest(
        wsId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        orientation: Monitor.Orientation
    ) -> ZigNiriHitTestRequest {
        guard let controller else {
            return ZigNiriHitTestRequest(
                workspaceId: wsId,
                monitorFrame: monitor.visibleFrame,
                gaps: .default,
                scale: 2.0,
                orientation: orientation
            )
        }

        return ZigNiriHitTestRequest(
            workspaceId: wsId,
            monitorFrame: controller.insetWorkingFrame(for: monitor),
            gaps: ZigNiriGaps(
                horizontal: CGFloat(controller.workspaceManager.gaps),
                vertical: CGFloat(controller.workspaceManager.gaps)
            ),
            scale: controller.layoutRefreshController.backingScale(for: monitor),
            orientation: orientation
        )
    }

    private func columnSpans(
        for view: ZigNiriWorkspaceView,
        orientation: Monitor.Orientation,
        fallbackFrame: CGRect
    ) -> [CGFloat] {
        guard !view.columns.isEmpty else { return [] }

        let fallback = (orientation == .horizontal ? fallbackFrame.width : fallbackFrame.height) / CGFloat(max(1, view.columns.count))

        return view.columns.map { column in
            let frames = column.windowIds.compactMap { view.windowsById[$0]?.frame }
            if orientation == .horizontal {
                return frames.map(\.width).max() ?? fallback
            }
            return frames.map(\.height).max() ?? fallback
        }
    }

    private func resizeEdges(from edges: ZigNiriResizeEdge) -> ResizeEdge {
        var result: ResizeEdge = []
        if edges.contains(.top) { result.insert(.top) }
        if edges.contains(.bottom) { result.insert(.bottom) }
        if edges.contains(.left) { result.insert(.left) }
        if edges.contains(.right) { result.insert(.right) }
        return result
    }

    private func resetGestureState() {
        state.gesturePhase = .idle
        state.gestureStartX = 0.0
        state.gestureStartY = 0.0
        state.gestureLastDeltaX = 0.0
        state.lockedGestureContext = nil
    }
}
