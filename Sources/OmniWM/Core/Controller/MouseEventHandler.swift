import AppKit
import Foundation

@MainActor
final class MouseEventHandler {
    private enum FocusFollowsMouseTarget {
        case niri(workspaceId: WorkspaceDescriptor.ID, window: NiriWindow)
        case dwindle(workspaceId: WorkspaceDescriptor.ID, token: WindowToken)
    }

    struct GestureTouchSample: Equatable, Sendable {
        let phase: NSTouch.Phase
        let normalizedPosition: CGPoint?
    }

    struct GestureEventSnapshot: Sendable {
        let location: CGPoint
        let phaseRawValue: NSEvent.Phase.RawValue
        let touches: [GestureTouchSample]
    }

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

        enum PendingTapKind: CaseIterable {
            case mouseMoved
            case leftMouseDragged
            case scrollWheel
        }

        struct ScrollPayload {
            var location: CGPoint
            var deltaX: CGFloat
            var deltaY: CGFloat
            var momentumPhase: UInt32
            var phase: UInt32
            var modifiers: CGEventFlags

            func matches(
                modifiers: CGEventFlags,
                momentumPhase: UInt32,
                phase: UInt32
            ) -> Bool {
                self.modifiers == modifiers &&
                    self.momentumPhase == momentumPhase &&
                    self.phase == phase
            }

            mutating func accumulate(deltaX: CGFloat, deltaY: CGFloat, location: CGPoint) {
                self.deltaX += deltaX
                self.deltaY += deltaY
                self.location = location
            }
        }

        struct PendingTapEvents {
            var orderedKinds: [PendingTapKind] = []
            var mouseMovedLocation: CGPoint?
            var mouseDraggedLocation: CGPoint?
            var scrollPayload: ScrollPayload?
            var drainScheduled = false

            var hasPendingEvents: Bool {
                !orderedKinds.isEmpty
            }

            mutating func clear() {
                orderedKinds.removeAll(keepingCapacity: true)
                mouseMovedLocation = nil
                mouseDraggedLocation = nil
                scrollPayload = nil
                drainScheduled = false
            }
        }

        struct DebugCounters: Equatable {
            var queuedTransientEvents = 0
            var coalescedTransientEvents = 0
            var drainedTransientEvents = 0
            var drainRuns = 0
            var flushedBeforeImmediateDispatch = 0
        }

        var eventTap: CFMachPort?
        var runLoopSource: CFRunLoopSource?
        var gestureTap: CFMachPort?
        var gestureRunLoopSource: CFRunLoopSource?
        var currentHoveredEdges: ResizeEdge = []
        var isResizing: Bool = false
        var isMoving: Bool = false

        var lastFocusFollowsMouseTime: Date = .distantPast
        var lastFocusFollowsMouseToken: WindowToken?
        let focusFollowsMouseDebounce: TimeInterval = 0.1
        var dragGhostController: DragGhostController?
        var moveIsInsertMode: Bool = false

        var gesturePhase: GesturePhase = .idle
        var gestureStartX: CGFloat = 0.0
        var gestureStartY: CGFloat = 0.0
        var gestureLastDeltaX: CGFloat = 0.0
        var lockedGestureContext: LockedGestureContext?
        var pendingTapEvents = PendingTapEvents()
        var debugCounters = DebugCounters()
    }

    nonisolated(unsafe) static weak var sharedInstance: MouseEventHandler?

    weak var controller: WMController?
    var state = State()
    var pressedMouseButtonsProvider: @MainActor () -> Int = { Int(NSEvent.pressedMouseButtons) }

    init(controller: WMController) {
        self.controller = controller
    }

    func setup() {
        MouseEventHandler.sharedInstance = self

        let eventMask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = MouseEventHandler.sharedInstance?.state.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            _ = MouseEventHandler.processTapCallback(type: type, event: event)

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
                if let tap = MouseEventHandler.sharedInstance?.state.gestureTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            _ = MouseEventHandler.processGestureTapCallback(type: type, event: event)

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
        MouseEventHandler.sharedInstance = nil
        state.currentHoveredEdges = []
        state.isResizing = false
        state.pendingTapEvents.clear()
        resetGestureState()
    }

    func dispatchMouseMoved(at location: CGPoint) {
        guard !isInputSuppressed else {
            resetHoveredEdgesIfNeeded()
            return
        }
        handleMouseMovedFromTap(at: location)
    }

    func dispatchMouseDown(at location: CGPoint, modifiers: CGEventFlags) {
        guard !isInputSuppressed else { return }
        guard let controller else { return }
        if controller.isPointInOwnWindow(location) {
            return
        }
        handleMouseDownFromTap(at: location, modifiers: modifiers)
    }

    func dispatchMouseDragged(at location: CGPoint) {
        guard !isInputSuppressed else { return }
        if let controller, controller.isPointInOwnWindow(location) {
            cancelActiveMouseInteraction()
            return
        }
        handleMouseDraggedFromTap(at: location)
    }

    func dispatchMouseUp(at location: CGPoint) {
        guard !isInputSuppressed else { return }
        if let controller, controller.isPointInOwnWindow(location) {
            cancelActiveMouseInteraction()
            return
        }
        handleMouseUpFromTap(at: location)
    }

    func dispatchScrollWheel(
        at location: CGPoint,
        deltaX: CGFloat,
        deltaY: CGFloat,
        momentumPhase: UInt32,
        phase: UInt32,
        modifiers: CGEventFlags
    ) {
        guard !isInputSuppressed else { return }
        handleScrollWheelFromTap(
            at: location,
            deltaX: deltaX,
            deltaY: deltaY,
            momentumPhase: momentumPhase,
            phase: phase,
            modifiers: modifiers
        )
    }

    func dispatchGestureEvent(from cgEvent: CGEvent) {
        guard !isInputSuppressed else { return }
        guard let snapshot = Self.makeGestureEventSnapshot(from: cgEvent) else { return }
        handleGestureEvent(snapshot)
    }

    func dispatchGestureEvent(_ event: NSEvent, at location: CGPoint) {
        guard !isInputSuppressed else { return }
        handleGestureEvent(
            GestureEventSnapshot(
                location: location,
                phaseRawValue: event.phase.rawValue,
                touches: event.allTouches().map { touch in
                    GestureTouchSample(
                        phase: touch.phase,
                        normalizedPosition: Self.sanitizedGestureTouchPosition(touch.normalizedPosition)
                    )
                }
            )
        )
    }

    var isInteractiveGestureActive: Bool {
        state.isMoving || state.isResizing
    }

    func flushPendingTapEventsForTests() {
        flushPendingTapEvents()
    }

    func mouseTapDebugSnapshot() -> State.DebugCounters {
        state.debugCounters
    }

    func resetDebugStateForTests() {
        state.debugCounters = .init()
        state.pendingTapEvents.clear()
    }

    func handleTapCallbackForTests(
        type: CGEventType,
        event: CGEvent,
        isMainThread: Bool
    ) -> Bool {
        Self.processTapCallback(type: type, event: event, isMainThread: isMainThread)
    }

    func handleGestureTapCallbackForTests(
        type: CGEventType,
        event: CGEvent,
        isMainThread: Bool
    ) -> Bool {
        Self.processGestureTapCallback(type: type, event: event, isMainThread: isMainThread)
    }

    func receiveTapMouseMoved(at location: CGPoint) {
        flushPendingScrollBeforeNonScroll()
        enqueuePendingMouseMoved(at: location)
    }

    func receiveTapMouseDown(at location: CGPoint, modifiers: CGEventFlags) {
        if let controller, controller.isPointInOwnWindow(location) {
            dropPendingTapEvents()
        } else {
            flushPendingTapEvents(beforeImmediateDispatch: true)
        }
        dispatchMouseDown(at: location, modifiers: modifiers)
    }

    func receiveTapMouseDragged(at location: CGPoint) {
        flushPendingScrollBeforeNonScroll()
        enqueuePendingMouseDragged(at: location)
    }

    func receiveTapMouseUp(at location: CGPoint) {
        if let controller, controller.isPointInOwnWindow(location) {
            dropPendingTapEvents()
        } else {
            flushPendingTapEvents(beforeImmediateDispatch: true)
        }
        dispatchMouseUp(at: location)
    }

    func receiveTapScrollWheel(
        at location: CGPoint,
        deltaX: CGFloat,
        deltaY: CGFloat,
        momentumPhase: UInt32,
        phase: UInt32,
        modifiers: CGEventFlags
    ) {
        enqueuePendingScrollWheel(
            at: location,
            deltaX: deltaX,
            deltaY: deltaY,
            momentumPhase: momentumPhase,
            phase: phase,
            modifiers: modifiers
        )
    }

    func receiveTapGestureEvent(from cgEvent: CGEvent) {
        let location = ScreenCoordinateSpace.toAppKit(point: cgEvent.location)
        if let controller, controller.isPointInOwnWindow(location) {
            dropPendingTapEvents()
        } else {
            flushPendingTapEvents(beforeImmediateDispatch: true)
        }
        guard let snapshot = Self.makeGestureEventSnapshot(from: cgEvent) else { return }
        handleGestureEvent(snapshot)
    }

    func receiveTapGestureEvent(_ snapshot: GestureEventSnapshot) {
        if let controller, controller.isPointInOwnWindow(snapshot.location) {
            dropPendingTapEvents()
        } else {
            flushPendingTapEvents(beforeImmediateDispatch: true)
        }
        handleGestureEvent(snapshot)
    }

    private var isInputSuppressed: Bool {
        guard let controller else { return true }
        return controller.isCursorAutomationSuppressed
    }

    private func dropPendingTapEvents() {
        guard state.pendingTapEvents.hasPendingEvents else { return }
        state.pendingTapEvents.clear()
    }

    private func cancelActiveMouseInteraction() {
        guard let controller else { return }

        if state.isMoving {
            controller.niriEngine?.interactiveMoveCancel()
            state.dragGhostController?.endDrag()
            state.isMoving = false
            state.moveIsInsertMode = false
        }

        if state.isResizing {
            controller.niriEngine?.clearInteractiveResize()
            state.isResizing = false
        }

        resetHoveredEdgesIfNeeded()
    }

    private func resetHoveredEdgesIfNeeded() {
        if !state.currentHoveredEdges.isEmpty {
            NSCursor.arrow.set()
            state.currentHoveredEdges = []
        }
    }

    private func schedulePendingTapDrainIfNeeded() {
        guard !state.pendingTapEvents.drainScheduled else { return }
        state.pendingTapEvents.drainScheduled = true

        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.flushPendingTapEvents()
            }
        }
        CFRunLoopWakeUp(mainRunLoop)
    }

    private func flushPendingScrollBeforeNonScroll() {
        guard state.pendingTapEvents.scrollPayload != nil else { return }
        flushPendingTapEvents()
    }

    private func enqueuePendingMouseMoved(at location: CGPoint) {
        state.debugCounters.queuedTransientEvents += 1
        let didCoalesce = state.pendingTapEvents.mouseMovedLocation != nil
        state.pendingTapEvents.mouseMovedLocation = location
        if !didCoalesce {
            state.pendingTapEvents.orderedKinds.append(.mouseMoved)
        } else {
            state.debugCounters.coalescedTransientEvents += 1
        }
        schedulePendingTapDrainIfNeeded()
    }

    private func enqueuePendingMouseDragged(at location: CGPoint) {
        state.debugCounters.queuedTransientEvents += 1
        let didCoalesce = state.pendingTapEvents.mouseDraggedLocation != nil
        state.pendingTapEvents.mouseDraggedLocation = location
        if !didCoalesce {
            state.pendingTapEvents.orderedKinds.append(.leftMouseDragged)
        } else {
            state.debugCounters.coalescedTransientEvents += 1
        }
        schedulePendingTapDrainIfNeeded()
    }

    private func enqueuePendingScrollWheel(
        at location: CGPoint,
        deltaX: CGFloat,
        deltaY: CGFloat,
        momentumPhase: UInt32,
        phase: UInt32,
        modifiers: CGEventFlags
    ) {
        state.debugCounters.queuedTransientEvents += 1

        if let existing = state.pendingTapEvents.scrollPayload,
           !existing.matches(modifiers: modifiers, momentumPhase: momentumPhase, phase: phase)
        {
            flushPendingTapEvents()
        }

        if var existing = state.pendingTapEvents.scrollPayload {
            existing.accumulate(deltaX: deltaX, deltaY: deltaY, location: location)
            state.pendingTapEvents.scrollPayload = existing
            state.debugCounters.coalescedTransientEvents += 1
        } else {
            state.pendingTapEvents.scrollPayload = .init(
                location: location,
                deltaX: deltaX,
                deltaY: deltaY,
                momentumPhase: momentumPhase,
                phase: phase,
                modifiers: modifiers
            )
            state.pendingTapEvents.orderedKinds.append(.scrollWheel)
        }

        schedulePendingTapDrainIfNeeded()
    }

    private func flushPendingTapEvents(beforeImmediateDispatch: Bool = false) {
        guard state.pendingTapEvents.hasPendingEvents else { return }

        if beforeImmediateDispatch {
            state.debugCounters.flushedBeforeImmediateDispatch += 1
        }

        let pendingKinds = state.pendingTapEvents.orderedKinds
        let pendingMouseMoved = state.pendingTapEvents.mouseMovedLocation
        let pendingMouseDragged = state.pendingTapEvents.mouseDraggedLocation
        let pendingScroll = state.pendingTapEvents.scrollPayload

        state.pendingTapEvents.clear()
        state.debugCounters.drainRuns += 1

        for kind in pendingKinds {
            switch kind {
            case .mouseMoved:
                if let location = pendingMouseMoved {
                    state.debugCounters.drainedTransientEvents += 1
                    dispatchMouseMoved(at: location)
                }
            case .leftMouseDragged:
                if let location = pendingMouseDragged {
                    state.debugCounters.drainedTransientEvents += 1
                    replayQueuedMouseDragged(at: location)
                }
            case .scrollWheel:
                if let payload = pendingScroll {
                    state.debugCounters.drainedTransientEvents += 1
                    dispatchScrollWheel(
                        at: payload.location,
                        deltaX: payload.deltaX,
                        deltaY: payload.deltaY,
                        momentumPhase: payload.momentumPhase,
                        phase: payload.phase,
                        modifiers: payload.modifiers
                    )
                }
            }
        }
    }

    private func replayQueuedMouseDragged(at location: CGPoint) {
        guard !isInputSuppressed else { return }
        if let controller, controller.isPointInOwnWindow(location) {
            cancelActiveMouseInteraction()
            return
        }
        handleMouseDraggedFromTap(at: location, requirePressedButtonCheck: false)
    }

    private func handleMouseMovedFromTap(at location: CGPoint) {
        guard let controller else { return }
        guard controller.isEnabled else {
            resetHoveredEdgesIfNeeded()
            return
        }
        if controller.isOverviewOpen() { return }

        if controller.isPointInOwnWindow(location) {
            resetHoveredEdgesIfNeeded()
            return
        }

        if controller.focusFollowsMouseEnabled, !state.isResizing {
            handleFocusFollowsMouse(at: location)
        }

        guard !state.isResizing else { return }

        guard let engine = controller.niriEngine,
              let wsId = controller.activeWorkspace()?.id
        else {
            resetHoveredEdgesIfNeeded()
            return
        }

        if let hitResult = engine.hitTestResize(point: location, in: wsId) {
            if hitResult.edges != state.currentHoveredEdges {
                hitResult.edges.cursor.set()
                state.currentHoveredEdges = hitResult.edges
            }
        } else {
            resetHoveredEdgesIfNeeded()
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
                        motion: controller.motionPolicy.snapshot(),
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

    private func handleMouseDraggedFromTap(
        at location: CGPoint,
        requirePressedButtonCheck: Bool = true
    ) {
        guard let controller else { return }
        guard controller.isEnabled else { return }
        if controller.isOverviewOpen() { return }
        if requirePressedButtonCheck {
            guard pressedMouseButtonsProvider() & 1 != 0 else { return }
        }

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
            controller.layoutRefreshController.requestImmediateRelayout(
                reason: .interactiveGesture,
                affectedWorkspaceIds: [wsId]
            )
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
                        motion: controller.motionPolicy.snapshot(),
                        state: &vstate,
                        workingFrame: workingFrame,
                        gaps: gaps
                    )
                }
                if didEnd {
                    controller.layoutRefreshController.requestImmediateRelayout(
                        reason: .interactiveGesture,
                        affectedWorkspaceIds: [wsId]
                    )
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
            let hadInteractiveResize = engine.interactiveResize != nil

            controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
                engine.interactiveResizeEnd(
                    motion: controller.motionPolicy.snapshot(),
                    state: &vstate,
                    workingFrame: workingFrame,
                    gaps: gaps
                )
            }
            if hadInteractiveResize {
                controller.layoutRefreshController.requestImmediateRelayout(
                    reason: .interactiveGesture,
                    affectedWorkspaceIds: [wsId]
                )
            }
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
            monitor: context.monitor
        )
    }

    private func handleFocusFollowsMouse(at location: CGPoint) {
        guard let controller else { return }
        guard controller.focusPolicyEngine.evaluate(.focusFollowsMouse).allowsFocusChange else {
            return
        }
        guard !controller.workspaceManager.isNonManagedFocusActive,
              !controller.workspaceManager.hasPendingNativeFullscreenTransition,
              !controller.workspaceManager.isAppFullscreenActive else {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(state.lastFocusFollowsMouseTime) >= state.focusFollowsMouseDebounce else {
            return
        }

        guard let target = resolveFocusFollowsMouseTarget(at: location) else { return }
        let token = focusFollowsMouseToken(for: target)

        if token != state.lastFocusFollowsMouseToken,
           token != controller.workspaceManager.focusedToken {
            state.lastFocusFollowsMouseTime = now
            state.lastFocusFollowsMouseToken = token
            activateFocusFollowsMouseTarget(target)
        }
    }

    private func resolveFocusFollowsMouseTarget(at location: CGPoint) -> FocusFollowsMouseTarget? {
        guard let controller, let workspace = controller.activeWorkspace() else { return nil }

        switch controller.settings.layoutType(for: workspace.name) {
        case .niri, .defaultLayout:
            guard let engine = controller.niriEngine,
                  let window = engine.hitTestFocusableWindow(point: location, in: workspace.id)
            else {
                return nil
            }
            return .niri(workspaceId: workspace.id, window: window)

        case .dwindle:
            guard let engine = controller.dwindleEngine else { return nil }
            let presentationTime = controller.animationClock.now()
            guard let token = engine.hitTestFocusableWindow(
                point: location,
                in: workspace.id,
                at: presentationTime
            ) else {
                return nil
            }
            return .dwindle(workspaceId: workspace.id, token: token)
        }
    }

    private func focusFollowsMouseToken(for target: FocusFollowsMouseTarget) -> WindowToken {
        switch target {
        case let .niri(_, window):
            window.token
        case let .dwindle(_, token):
            token
        }
    }

    private func activateFocusFollowsMouseTarget(_ target: FocusFollowsMouseTarget) {
        guard let controller else { return }

        switch target {
        case let .niri(workspaceId, window):
            controller.workspaceManager.withNiriViewportState(for: workspaceId) { vstate in
                controller.niriLayoutHandler.activateNode(window, in: workspaceId, state: &vstate)
            }
        case let .dwindle(workspaceId, token):
            controller.dwindleLayoutHandler.activateWindow(token, in: workspaceId)
        }
    }

    private func handleGestureEvent(_ snapshot: GestureEventSnapshot) {
        guard let controller else { return }
        let location = snapshot.location
        guard controller.isEnabled, controller.settings.scrollGestureEnabled else { return }
        if controller.isOverviewOpen() { return }
        if controller.isPointInOwnWindow(location) {
            abortActiveGestureIfNeeded()
            return
        }
        guard !state.isResizing, !state.isMoving else { return }
        guard let engine = controller.niriEngine else { return }

        let requiredFingers = controller.settings.gestureFingerCount.rawValue
        let invertDirection = controller.settings.gestureInvertDirection

        let phase = NSEvent.Phase(rawValue: snapshot.phaseRawValue)
        if phase == .ended || phase == .cancelled {
            if state.gesturePhase == .committed {
                guard let lockedContext = state.lockedGestureContext else {
                    assertionFailure("Committed gesture missing locked context")
                    resetGestureState()
                    return
                }
                finalizeOrCancelCommittedGesture(using: lockedContext, engine: engine)
            }
            resetGestureState()
            return
        }

        if phase == .began {
            abortActiveGestureIfNeeded()
        }

        guard resolveScrollContext(at: location) != nil else {
            finalizeOrAbortActiveGesture(engine: engine)
            return
        }
        guard !snapshot.touches.isEmpty else {
            finalizeOrAbortActiveGesture(engine: engine)
            return
        }
        guard let averageTouchPosition = Self.averageGestureTouchPosition(
            requiredFingers: requiredFingers,
            touches: snapshot.touches
        ) else {
            finalizeOrAbortActiveGesture(engine: engine)
            return
        }

        let avgX = averageTouchPosition.x
        let avgY = averageTouchPosition.y

        switch state.gesturePhase {
        case .idle:
            guard let currentContext = resolveScrollContext(at: location) else {
                abortActiveGestureIfNeeded()
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
                abortActiveGestureIfNeeded()
                return
            }
            let wsId = lockedContext.workspaceId
            guard let monitor = controller.workspaceManager.monitor(byId: lockedContext.monitorId) else {
                abortActiveGestureIfNeeded()
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

            applyMouseViewportScrollDelta(
                deltaUnits,
                isTrackpad: true,
                engine: engine,
                wsId: wsId,
                monitor: monitor
            )
        }
    }

    func applyMouseViewportScrollDelta(
        _ delta: CGFloat,
        isTrackpad: Bool,
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID,
        monitor: Monitor
    ) {
        guard let controller else { return }
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
                        _ = controller.workspaceManager.applySessionPatch(
                            .init(
                                workspaceId: wsId,
                                viewportState: nil,
                                rememberedFocusToken: windowNode.token
                            )
                        )
                        engine.updateFocusTimestamp(for: windowNode.id)
                        targetWindowHandle = controller.workspaceManager.handle(for: windowNode.token)
                    }
                }
            }
        }
        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .interactiveGesture,
            affectedWorkspaceIds: [wsId]
        )

        if let handle = targetWindowHandle {
            controller.focusWindow(handle)
        }
    }

    func finalizeOrCancelCommittedGesture(
        using lockedContext: State.LockedGestureContext,
        engine: NiriLayoutEngine
    ) {
        guard let controller else { return }
        let wsId = lockedContext.workspaceId
        guard let monitor = controller.workspaceManager.monitor(byId: lockedContext.monitorId) else {
            cancelCommittedGestureViewportState(for: wsId)
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
                motion: controller.motionPolicy.snapshot(),
                centerMode: engine.centerFocusedColumn,
                alwaysCenterSingleColumn: engine.alwaysCenterSingleColumn
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
            vstate.viewOffsetToRestore = nil
            vstate.activatePrevColumnOnRemoval = nil
            didCancel = true
        }
        if didCancel {
            controller.layoutRefreshController.requestImmediateRelayout(
                reason: .interactiveGesture,
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    private func abortActiveGestureIfNeeded() {
        if state.gesturePhase == .committed {
            guard let lockedContext = state.lockedGestureContext else {
                assertionFailure("Committed gesture missing locked context")
                resetGestureState()
                return
            }
            cancelCommittedGestureViewportState(for: lockedContext.workspaceId)
        }
        resetGestureState()
    }

    /// Finalizes a committed gesture with the snap-to-column animation when possible,
    /// or falls back to an abort. Used when the gesture stream stops delivering valid
    /// touch data before the explicit `.ended` phase arrives — for example, when the
    /// user lifts their fingers and macOS first sends a `.changed` event with empty
    /// touches. Aborting in that window would skip the snap and leave the viewport
    /// stuck mid-column.
    private func finalizeOrAbortActiveGesture(engine: NiriLayoutEngine) {
        if state.gesturePhase == .committed, let lockedContext = state.lockedGestureContext {
            finalizeOrCancelCommittedGesture(using: lockedContext, engine: engine)
            resetGestureState()
        } else {
            abortActiveGestureIfNeeded()
        }
    }

    private func resolveScrollContext(at location: CGPoint) -> (
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID,
        monitor: Monitor
    )? {
        guard let controller,
              let engine = controller.niriEngine
        else {
            return nil
        }

        let monitors = controller.workspaceManager.monitors
        guard let monitor = location.monitorApproximation(in: monitors),
              let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        else {
            return nil
        }

        switch controller.settings.layoutType(for: workspace.name) {
        case .niri, .defaultLayout:
            return (engine, workspace.id, monitor)
        case .dwindle:
            return nil
        }
    }

    private func resetGestureState() {
        state.gesturePhase = .idle
        state.gestureStartX = 0.0
        state.gestureStartY = 0.0
        state.gestureLastDeltaX = 0.0
        state.lockedGestureContext = nil
    }

    nonisolated private static func processTapCallback(
        type: CGEventType,
        event: CGEvent,
        isMainThread: Bool = Thread.isMainThread
    ) -> Bool {
        guard isMainThread else { return false }

        let location = event.location
        let screenLocation = ScreenCoordinateSpace.toAppKit(point: location)
        let modifiers = event.flags
        let deltaX = CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))
        let deltaY = CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
        let momentumPhase = UInt32(event.getIntegerValueField(.scrollWheelEventMomentumPhase))
        let phase = UInt32(event.getIntegerValueField(.scrollWheelEventScrollPhase))

        MainActor.assumeIsolated {
            guard let handler = MouseEventHandler.sharedInstance else { return }
            switch type {
            case .mouseMoved:
                handler.receiveTapMouseMoved(at: screenLocation)
            case .leftMouseDown:
                handler.receiveTapMouseDown(at: screenLocation, modifiers: modifiers)
            case .leftMouseDragged:
                handler.receiveTapMouseDragged(at: screenLocation)
            case .leftMouseUp:
                handler.receiveTapMouseUp(at: screenLocation)
            case .scrollWheel:
                handler.receiveTapScrollWheel(
                    at: screenLocation,
                    deltaX: deltaX,
                    deltaY: deltaY,
                    momentumPhase: momentumPhase,
                    phase: phase,
                    modifiers: modifiers
                )
            default:
                break
            }
        }

        return true
    }

    nonisolated private static func processGestureTapCallback(
        type: CGEventType,
        event: CGEvent,
        isMainThread: Bool = Thread.isMainThread
    ) -> Bool {
        guard type.rawValue == NSEvent.EventType.gesture.rawValue else { return false }
        guard isMainThread else { return false }
        guard let snapshot = makeGestureEventSnapshot(from: event) else { return true }

        MainActor.assumeIsolated {
            MouseEventHandler.sharedInstance?.receiveTapGestureEvent(snapshot)
        }

        return true
    }

    static func averageGestureTouchPosition(
        requiredFingers: Int,
        touches: [GestureTouchSample]
    ) -> CGPoint? {
        guard requiredFingers > 0 else { return nil }

        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        var touchCount = 0
        var activeCount = 0

        for touch in touches {
            if touch.phase == .ended || touch.phase == .cancelled {
                continue
            }

            touchCount += 1
            if touchCount > requiredFingers {
                return nil
            }

            guard let normalizedPosition = touch.normalizedPosition else {
                return nil
            }

            sumX += normalizedPosition.x
            sumY += normalizedPosition.y
            activeCount += 1
        }

        guard touchCount == requiredFingers, activeCount > 0 else { return nil }

        return CGPoint(
            x: sumX / CGFloat(activeCount),
            y: sumY / CGFloat(activeCount)
        )
    }

    nonisolated private static func sanitizedGestureTouchPosition(_ position: CGPoint) -> CGPoint? {
        guard position.x.isFinite, position.y.isFinite else { return nil }
        return position
    }

    nonisolated private static func makeGestureEventSnapshot(from cgEvent: CGEvent) -> GestureEventSnapshot? {
        guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return nil }
        return GestureEventSnapshot(
            location: ScreenCoordinateSpace.toAppKit(point: cgEvent.location),
            phaseRawValue: nsEvent.phase.rawValue,
            touches: nsEvent.allTouches().map { touch in
                GestureTouchSample(
                    phase: touch.phase,
                    normalizedPosition: sanitizedGestureTouchPosition(touch.normalizedPosition)
                )
            }
        )
    }
}
