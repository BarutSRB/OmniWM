import AppKit
import Foundation
import os

private let niriTouchpadGestureRecognitionThreshold: CGFloat = 16.0
// AppKit gives normalized touch positions rather than libinput gesture deltas.
// This maps normalized movement into the delta space that ViewportState later
// normalizes with VIEW_GESTURE_WORKING_AREA_MOVEMENT.
private let macNormalizedTouchPositionToNiriGestureUnits: CGFloat = 500.0
private let mouseWheelAxisEpsilon: CGFloat = 0.001
private let niriWheelScrollTickAmount: CGFloat = 120.0
private let mouseRelevantModifierFlags: CGEventFlags = [
    .maskAlternate,
    .maskShift,
    .maskControl,
    .maskCommand
]

@MainActor
final class MouseEventHandler {
    enum MouseButton: Hashable {
        case left
        case right

        var pressedMask: Int {
            switch self {
            case .left: 1
            case .right: 2
            }
        }
    }

    private enum MouseWheelColumnAxis {
        case horizontal
        case vertical
    }

    private struct MouseWheelColumnDelta {
        var axis: MouseWheelColumnAxis
        var value: CGFloat
    }

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
        let timestamp: TimeInterval
        let touches: [GestureTouchSample]

        init(
            location: CGPoint,
            phaseRawValue: NSEvent.Phase.RawValue,
            timestamp: TimeInterval = CACurrentMediaTime(),
            touches: [GestureTouchSample]
        ) {
            self.location = location
            self.phaseRawValue = phaseRawValue
            self.timestamp = timestamp
            self.touches = touches
        }
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

        enum PendingTapKind {
            case mouseMoved
            case mouseDragged(MouseButton)
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

            func canCoalesce(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
                Self.axisSignature(deltaX: self.deltaX, deltaY: self.deltaY) ==
                    Self.axisSignature(deltaX: deltaX, deltaY: deltaY)
            }

            mutating func accumulate(deltaX: CGFloat, deltaY: CGFloat, location: CGPoint) {
                self.deltaX += deltaX
                self.deltaY += deltaY
                self.location = location
            }

            private static func axisSignature(deltaX: CGFloat, deltaY: CGFloat) -> (Int, Int) {
                (
                    signedAxis(deltaX),
                    signedAxis(deltaY)
                )
            }

            private static func signedAxis(_ delta: CGFloat) -> Int {
                guard abs(delta) > mouseWheelAxisEpsilon else { return 0 }
                return delta > 0 ? 1 : -1
            }
        }

        struct PendingTapEvents {
            var orderedKinds: [PendingTapKind] = []
            var mouseMovedLocation: CGPoint?
            var leftMouseDraggedLocation: CGPoint?
            var rightMouseDraggedLocation: CGPoint?
            var scrollPayload: ScrollPayload?
            var drainScheduled = false

            var hasPendingEvents: Bool {
                !orderedKinds.isEmpty
            }

            mutating func setMouseDraggedLocation(_ location: CGPoint, for button: MouseButton) -> Bool {
                switch button {
                case .left:
                    let didCoalesce = leftMouseDraggedLocation != nil
                    leftMouseDraggedLocation = location
                    return didCoalesce
                case .right:
                    let didCoalesce = rightMouseDraggedLocation != nil
                    rightMouseDraggedLocation = location
                    return didCoalesce
                }
            }

            mutating func clear() {
                orderedKinds.removeAll(keepingCapacity: true)
                mouseMovedLocation = nil
                leftMouseDraggedLocation = nil
                rightMouseDraggedLocation = nil
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
        var activeInteractionButton: MouseButton?

        var lastFocusFollowsMouseTime: Date = .distantPast
        var lastFocusFollowsMouseToken: WindowToken?
        let focusFollowsMouseDebounce: TimeInterval = 0.1
        var dragGhostController: DragGhostController?
        var moveIsInsertMode: Bool = false

        var gesturePhase: GesturePhase = .idle
        var gestureStartX: CGFloat = 0.0
        var gestureStartY: CGFloat = 0.0
        var gestureLastAverageX: CGFloat = 0.0
        var gestureLastAverageY: CGFloat = 0.0
        var lockedGestureContext: LockedGestureContext?
        var pendingTapEvents = PendingTapEvents()
        var debugCounters = DebugCounters()
        var horizontalWheelTracker = NiriScrollTracker(tick: niriWheelScrollTickAmount)
        var verticalWheelTracker = NiriScrollTracker(tick: niriWheelScrollTickAmount)
    }

    nonisolated(unsafe) weak static var _instance: MouseEventHandler?

    weak var controller: WMController?
    var state = State()
    var pressedMouseButtonsProvider: @MainActor () -> Int = { Int(NSEvent.pressedMouseButtons) }

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
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if type == .tapDisabledByTimeout {
                    WMLog.input.info("Mouse event tap disabled by timeout")
                }
                if let tap = MouseEventHandler._instance?.state.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let suppressEvent = MouseEventHandler.processTapCallback(type: type, event: event)

            return suppressEvent ? nil : Unmanaged.passUnretained(event)
        }

        state.eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
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
                if type == .tapDisabledByTimeout {
                    WMLog.input.info("Gesture tap disabled by timeout")
                }
                if let tap = MouseEventHandler._instance?.state.gestureTap {
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
        MouseEventHandler._instance = nil
        state.currentHoveredEdges = []
        state.isResizing = false
        state.activeInteractionButton = nil
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

    @discardableResult
    func dispatchMouseDown(
        at location: CGPoint,
        modifiers: CGEventFlags,
        button: MouseButton = .left
    ) -> Bool {
        guard !isInputSuppressed else { return false }
        guard controller != nil else { return false }
        if shouldBlockOwnWindowInput(at: location) {
            return false
        }
        return handleMouseDownFromTap(at: location, modifiers: modifiers, button: button)
    }

    func dispatchMouseDragged(at location: CGPoint, button: MouseButton = .left) {
        guard !isInputSuppressed else { return }
        if shouldBlockOwnWindowInput(at: location) {
            cancelActiveMouseInteraction()
            return
        }
        handleMouseDraggedFromTap(at: location, button: button)
    }

    func dispatchMouseUp(at location: CGPoint, button: MouseButton = .left) {
        guard !isInputSuppressed else { return }
        if shouldBlockOwnWindowInput(at: location) {
            cancelActiveMouseInteraction()
            return
        }
        handleMouseUpFromTap(at: location, button: button)
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
                timestamp: event.timestamp,
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
        state.isMoving || state.isResizing || isViewportGestureActive
    }

    var isViewportGestureActive: Bool {
        state.gesturePhase != .idle
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

    func handleInputSuppressionBegan() {
        dropPendingTapEvents()
        resetMouseWheelTrackers()
        abortActiveGestureIfNeeded()
    }

    func handleTapCallbackForTests(
        type: CGEventType,
        event: CGEvent,
        isMainThread: Bool
    ) -> Bool {
        let previousInstance = Self._instance
        Self._instance = self
        defer { Self._instance = previousInstance }
        return Self.processTapCallback(type: type, event: event, isMainThread: isMainThread)
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

    @discardableResult
    func receiveTapMouseDown(
        at location: CGPoint,
        modifiers: CGEventFlags,
        button: MouseButton = .left
    ) -> Bool {
        if shouldBlockOwnWindowInput(at: location, allowsResizePlaceholderInteraction: false) {
            dropPendingTapEvents()
        } else {
            flushPendingTapEvents(beforeImmediateDispatch: true)
        }
        return dispatchMouseDown(at: location, modifiers: modifiers, button: button)
    }

    func receiveTapMouseDragged(at location: CGPoint, button: MouseButton = .left) {
        flushPendingScrollBeforeNonScroll()
        enqueuePendingMouseDragged(at: location, button: button)
    }

    func receiveTapMouseUp(at location: CGPoint, button: MouseButton = .left) {
        if shouldBlockOwnWindowInput(at: location, allowsResizePlaceholderInteraction: false) {
            dropPendingTapEvents()
        } else {
            flushPendingTapEvents(beforeImmediateDispatch: true)
        }
        dispatchMouseUp(at: location, button: button)
    }

    func receiveTapScrollWheel(
        at location: CGPoint,
        deltaX: CGFloat,
        deltaY: CGFloat,
        momentumPhase: UInt32,
        phase: UInt32,
        modifiers: CGEventFlags
    ) {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
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
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
        let location = ScreenCoordinateSpace.toAppKit(point: cgEvent.location)
        if shouldBlockOwnWindowInput(at: location, allowsResizePlaceholderInteraction: false) {
            dropPendingTapEvents()
        } else {
            flushPendingTapEvents(beforeImmediateDispatch: true)
        }
        guard let snapshot = Self.makeGestureEventSnapshot(from: cgEvent) else { return }
        handleGestureEvent(snapshot)
    }

    func receiveTapGestureEvent(_ snapshot: GestureEventSnapshot) {
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return
        }
        if shouldBlockOwnWindowInput(at: snapshot.location, allowsResizePlaceholderInteraction: false) {
            dropPendingTapEvents()
        } else {
            flushPendingTapEvents(beforeImmediateDispatch: true)
        }
        handleGestureEvent(snapshot)
    }

    private var isInputSuppressed: Bool {
        guard let controller else { return true }
        return controller.isLockScreenActive || controller.isFrontmostAppLockScreen()
    }

    private func dropPendingTapEvents() {
        guard state.pendingTapEvents.hasPendingEvents else { return }
        state.pendingTapEvents.clear()
    }

    private func resetMouseWheelTrackers() {
        state.horizontalWheelTracker.reset()
        state.verticalWheelTracker.reset()
    }

    private func cancelActiveMouseInteraction() {
        guard let controller else { return }

        if state.isMoving {
            controller.niriEngine?.interactiveMoveCancel()
            state.dragGhostController?.endDrag()
            state.isMoving = false
            state.moveIsInsertMode = false
            state.activeInteractionButton = nil
        }

        if state.isResizing {
            controller.niriEngine?.clearInteractiveResize()
            state.isResizing = false
            state.activeInteractionButton = nil
        }

        resetHoveredEdgesIfNeeded()
    }

    private func resizePlaceholderToken(at location: CGPoint) -> WindowToken? {
        guard let controller else { return nil }
        if let workspaceId = workspaceIdForPointer(at: location),
           let token = controller.resizePlaceholderManager.token(at: location, in: workspaceId)
        {
            return token
        }
        return controller.resizePlaceholderManager.token(at: location)
    }

    private func workspaceIdForPointer(at location: CGPoint) -> WorkspaceDescriptor.ID? {
        guard let controller else { return nil }
        guard let monitor = location.monitorApproximation(in: controller.workspaceManager.monitors) else {
            return controller.activeWorkspace()?.id
        }
        return controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
    }

    private func shouldBlockOwnWindowInput(
        at location: CGPoint,
        allowsResizePlaceholderInteraction: Bool = true
    ) -> Bool {
        guard let controller else { return false }
        guard controller.isPointInOwnWindow(location) else { return false }
        guard allowsResizePlaceholderInteraction else { return true }
        return resizePlaceholderToken(at: location) == nil
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

    private func enqueuePendingMouseDragged(at location: CGPoint, button: MouseButton) {
        state.debugCounters.queuedTransientEvents += 1
        let didCoalesce = state.pendingTapEvents.setMouseDraggedLocation(location, for: button)
        if !didCoalesce {
            state.pendingTapEvents.orderedKinds.append(.mouseDragged(button))
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
           (!existing.matches(modifiers: modifiers, momentumPhase: momentumPhase, phase: phase)
               || !existing.canCoalesce(deltaX: deltaX, deltaY: deltaY))
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
        let pendingLeftMouseDragged = state.pendingTapEvents.leftMouseDraggedLocation
        let pendingRightMouseDragged = state.pendingTapEvents.rightMouseDraggedLocation
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
            case let .mouseDragged(button):
                let location = switch button {
                case .left: pendingLeftMouseDragged
                case .right: pendingRightMouseDragged
                }
                if let location {
                    state.debugCounters.drainedTransientEvents += 1
                    replayQueuedMouseDragged(at: location, button: button)
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

    private func replayQueuedMouseDragged(at location: CGPoint, button: MouseButton) {
        guard !isInputSuppressed else { return }
        if shouldBlockOwnWindowInput(at: location) {
            cancelActiveMouseInteraction()
            return
        }
        handleMouseDraggedFromTap(at: location, button: button, requirePressedButtonCheck: false)
    }

    private func handleMouseMovedFromTap(at location: CGPoint) {
        guard let controller else { return }
        guard controller.isEnabled else {
            resetHoveredEdgesIfNeeded()
            return
        }
        if controller.isOverviewOpen() { return }

        if shouldBlockOwnWindowInput(at: location) {
            resetHoveredEdgesIfNeeded()
            return
        }

        if controller.focusFollowsMouseEnabled, shouldHandleFocusFollowsMouse(at: location) {
            handleFocusFollowsMouse(at: location)
        }

        guard !state.isResizing else { return }
        resetHoveredEdgesIfNeeded()
    }

    private func shouldHandleFocusFollowsMouse(at location: CGPoint) -> Bool {
        guard !state.isResizing, !isViewportGestureActive else { return false }
        guard let controller else { return false }
        guard let monitor = location.monitorApproximation(in: controller.workspaceManager.monitors),
              let workspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        else {
            return true
        }
        return !controller.niriLayoutHandler.hasScrollAnimation(for: workspace.id)
    }

    private func handleMouseDownFromTap(
        at location: CGPoint,
        modifiers: CGEventFlags,
        button: MouseButton
    ) -> Bool {
        guard let controller else { return false }
        guard controller.isEnabled else { return false }
        if controller.isOverviewOpen() { return false }

        if shouldBlockOwnWindowInput(at: location) {
            return false
        }

        guard let engine = controller.niriEngine,
              let wsId = workspaceIdForPointer(at: location) ?? controller.activeWorkspace()?.id
        else {
            return false
        }

        if button == .left, modifiers.contains(.maskAlternate) {
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
                    state.activeInteractionButton = button
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
                    return false
                }
            }
            return false
        }

        guard button == .right,
              Self.modifierFlagsMatch(modifiers, required: controller.settings.mouseResizeModifierKey.cgEventFlag)
        else { return false }
        if let placeholderToken = resizePlaceholderToken(at: location) {
            guard let tiledWindow = engine.findNode(for: placeholderToken),
                  let placeholderState = controller.workspaceManager.resizePlaceholderState(for: placeholderToken),
                  placeholderState.workspaceId == wsId
            else {
                return false
            }

            let edges = resizeEdges(for: location, in: placeholderState.frame)
            controller.selectResizePlaceholderForInteraction(placeholderToken)
            let currentViewOffset = controller.workspaceManager.niriViewportState(for: wsId).viewOffsetPixels.current()
            if engine.interactiveResizeBegin(
                windowId: tiledWindow.id,
                edges: edges,
                startLocation: location,
                in: wsId,
                viewOffset: currentViewOffset
            ) {
                state.isResizing = true
                state.activeInteractionButton = button
                state.currentHoveredEdges = edges
                controller.niriLayoutHandler.cancelActiveAnimations(for: wsId)
                edges.cursor.set()
                return true
            }
            return false
        }

        guard let tiledWindow = engine.hitTestTiled(point: location, in: wsId),
              let frame = tiledWindow.renderedFrame ?? tiledWindow.frame
        else { return false }

        let edges = resizeEdges(for: location, in: frame)
        let currentViewOffset = controller.workspaceManager.niriViewportState(for: wsId).viewOffsetPixels.current()
        if engine.interactiveResizeBegin(
            windowId: tiledWindow.id,
            edges: edges,
            startLocation: location,
            in: wsId,
            viewOffset: currentViewOffset
        ) {
            state.isResizing = true
            state.activeInteractionButton = button
            state.currentHoveredEdges = edges
            controller.niriLayoutHandler.cancelActiveAnimations(for: wsId)
            edges.cursor.set()
            return true
        }
        return false
    }

    private func resizeEdges(for location: CGPoint, in frame: CGRect) -> ResizeEdge {
        var edges: ResizeEdge = location.x < frame.midX ? [.left] : [.right]
        edges.insert(location.y < frame.midY ? .bottom : .top)
        return edges
    }

    private func shouldAcceptInteractionButton(_ button: MouseButton) -> Bool {
        state.activeInteractionButton == nil || state.activeInteractionButton == button
    }

    private func shouldSuppressRightMouseEvent(type: CGEventType) -> Bool {
        guard state.activeInteractionButton == .right else { return false }
        switch type {
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp:
            return state.isResizing
        default:
            return false
        }
    }

    private func handleMouseDraggedFromTap(
        at location: CGPoint,
        button: MouseButton,
        requirePressedButtonCheck: Bool = true
    ) {
        guard let controller else { return }
        guard controller.isEnabled else { return }
        if controller.isOverviewOpen() { return }
        if requirePressedButtonCheck {
            guard pressedMouseButtonsProvider() & button.pressedMask != 0 else { return }
        }

        if state.isMoving {
            guard shouldAcceptInteractionButton(button) else { return }
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
        guard shouldAcceptInteractionButton(button) else { return }

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
            controller.layoutRefreshController.requestImmediateRelayout(reason: .interactiveGesture)
        }
    }

    private func handleMouseUpFromTap(at location: CGPoint, button: MouseButton) {
        guard let controller else { return }
        if controller.isOverviewOpen() { return }

        if state.isMoving {
            guard shouldAcceptInteractionButton(button) else { return }
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
                    controller.layoutRefreshController.requestImmediateRelayout(reason: .interactiveGesture)
                }
            }

            state.dragGhostController?.endDrag()
            state.isMoving = false
            state.moveIsInsertMode = false
            state.activeInteractionButton = nil
            NSCursor.arrow.set()
            return
        }

        guard state.isResizing else { return }
        guard shouldAcceptInteractionButton(button) else { return }

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
                controller.layoutRefreshController.requestImmediateRelayout(reason: .interactiveGesture)
            }
        }

        state.isResizing = false
        state.activeInteractionButton = nil
        NSCursor.arrow.set()
        state.currentHoveredEdges = []
    }

    private func handleScrollWheelFromTap(
        at location: CGPoint,
        deltaX: CGFloat,
        deltaY: CGFloat,
        momentumPhase: UInt32,
        phase: UInt32,
        modifiers: CGEventFlags
    ) {
        guard let controller else { return }
        guard controller.isEnabled, controller.settings.scrollGestureEnabled else { return }
        if controller.isOverviewOpen() { return }
        if shouldBlockOwnWindowInput(at: location, allowsResizePlaceholderInteraction: false) { return }
        guard !state.isResizing, !state.isMoving else { return }

        let isTrackpad = momentumPhase != 0 || phase != 0
        if isTrackpad {
            return
        }

        let requiredModifiers = controller.settings.scrollModifierKey.cgEventFlag
        guard Self.mouseWheelModifiersMatch(modifiers, required: requiredModifiers) else {
            resetMouseWheelTrackers()
            return
        }

        guard let columnDelta = Self.resolvedMouseWheelColumnDelta(
            deltaX: deltaX,
            deltaY: deltaY,
            allowVerticalFallback: modifiers.contains(.maskShift)
        ) else { return }
        guard let context = resolveScrollContext(at: location) else { return }

        let ticks: Int
        switch columnDelta.axis {
        case .horizontal:
            ticks = state.horizontalWheelTracker.accumulate(columnDelta.value)
        case .vertical:
            ticks = state.verticalWheelTracker.accumulate(columnDelta.value)
        }
        guard ticks != 0 else { return }

        applyMouseWheelColumnTicks(
            ticks,
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
              !controller.workspaceManager.isAppFullscreenActive
        else {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(state.lastFocusFollowsMouseTime) >= state.focusFollowsMouseDebounce else {
            return
        }

        guard let target = resolveFocusFollowsMouseTarget(at: location) else { return }
        let token = focusFollowsMouseToken(for: target)

        if token != state.lastFocusFollowsMouseToken,
           token != controller.workspaceManager.focusedToken
        {
            state.lastFocusFollowsMouseTime = now
            state.lastFocusFollowsMouseToken = token
            activateFocusFollowsMouseTarget(target)
        }
    }

    private func resolveFocusFollowsMouseTarget(at location: CGPoint) -> FocusFollowsMouseTarget? {
        guard let controller, let workspace = controller.activeWorkspace() else { return nil }

        switch controller.settings.layoutType(for: workspace.name) {
        case .niri,
             .defaultLayout:
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
                controller.niriLayoutHandler.activateNode(
                    window,
                    in: workspaceId,
                    state: &vstate,
                    options: .init(ensureVisible: false, startAnimation: false)
                )
            }
        case let .dwindle(workspaceId, token):
            controller.dwindleLayoutHandler.activateWindow(token, in: workspaceId)
        }
    }

    private func handleGestureEvent(_ snapshot: GestureEventSnapshot) {
        guard let controller else { return }
        let location = snapshot.location
        let phase = NSEvent.Phase(rawValue: snapshot.phaseRawValue)
        let activeTouchCount = snapshot.touches.filter { $0.phase != .ended && $0.phase != .cancelled }.count

        guard controller.isEnabled else {
            abortActiveGestureIfNeeded()
            return
        }
        guard controller.settings.scrollGestureEnabled else {
            abortActiveGestureIfNeeded()
            return
        }
        if controller.isOverviewOpen() {
            abortActiveGestureIfNeeded()
            return
        }
        if shouldBlockOwnWindowInput(at: location, allowsResizePlaceholderInteraction: false) {
            abortActiveGestureIfNeeded()
            return
        }
        guard !state.isResizing, !state.isMoving else {
            abortActiveGestureIfNeeded()
            return
        }
        guard let engine = controller.niriEngine else {
            abortActiveGestureIfNeeded()
            return
        }

        let requiredFingers = controller.settings.gestureFingerCount.rawValue
        let invertDirection = controller.settings.gestureInvertDirection

        if phase == .ended || phase == .cancelled {
            if state.gesturePhase == .committed {
                guard let lockedContext = state.lockedGestureContext else {
                    assertionFailure("Committed gesture missing locked context")
                    resetGestureState()
                    return
                }
                finalizeOrCancelCommittedGesture(
                    using: lockedContext,
                    engine: engine,
                    timestamp: snapshot.timestamp
                )
            }
            resetGestureState()
            return
        }

        if phase == .began, state.gesturePhase != .idle {
            abortActiveGestureIfNeeded()
        }

        guard resolveScrollContext(at: location) != nil else {
            abortActiveGestureIfNeeded()
            return
        }
        guard !snapshot.touches.isEmpty else {
            abortActiveGestureIfNeeded()
            return
        }
        guard let averageTouchPosition = Self.averageGestureTouchPosition(
            requiredFingers: requiredFingers,
            touches: snapshot.touches
        ) else {
            if state.gesturePhase == .committed, activeTouchCount < requiredFingers {
                finalizeCommittedGestureAfterTouchRelease(
                    engine: engine,
                    timestamp: snapshot.timestamp
                )
                return
            }
            abortActiveGestureIfNeeded()
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
            state.gestureLastAverageX = avgX
            state.gestureLastAverageY = avgY
            state.gesturePhase = .armed

        case .armed,
             .committed:
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

            let cumulativeX = (avgX - state.gestureStartX) * macNormalizedTouchPositionToNiriGestureUnits
            let cumulativeY = (avgY - state.gestureStartY) * macNormalizedTouchPositionToNiriGestureUnits
            let previousPhase = state.gesturePhase
            let rawDeltaX: CGFloat

            if previousPhase == .armed {
                let distanceSquared = cumulativeX * cumulativeX + cumulativeY * cumulativeY
                let thresholdSquared = niriTouchpadGestureRecognitionThreshold * niriTouchpadGestureRecognitionThreshold
                guard distanceSquared >= thresholdSquared else {
                    state.gestureLastAverageX = avgX
                    state.gestureLastAverageY = avgY
                    return
                }

                guard abs(cumulativeX) > abs(cumulativeY) else {
                    resetGestureState()
                    return
                }

                rawDeltaX = (avgX - state.gestureLastAverageX) * macNormalizedTouchPositionToNiriGestureUnits
                state.gesturePhase = .committed
            } else {
                rawDeltaX = (avgX - state.gestureLastAverageX) * macNormalizedTouchPositionToNiriGestureUnits
            }

            state.gestureLastAverageX = avgX
            state.gestureLastAverageY = avgY

            var deltaUnits = rawDeltaX * CGFloat(controller.settings.scrollSensitivity)
            if invertDirection {
                deltaUnits = -deltaUnits
            }

            applyTrackpadViewportScrollDelta(
                deltaUnits,
                engine: engine,
                wsId: wsId,
                monitor: monitor,
                timestamp: snapshot.timestamp
            )
        }
    }

    func applyTrackpadViewportScrollDelta(
        _ delta: CGFloat,
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        timestamp: TimeInterval = CACurrentMediaTime()
    ) {
        guard let controller else { return }
        let insetFrame = controller.insetWorkingFrame(for: monitor)
        let viewportWidth = insetFrame.width
        let gap = CGFloat(controller.workspaceManager.gaps)
        let columns = engine.columns(in: wsId)

        var didApply = false
        controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
            if vstate.viewOffsetPixels.isAnimating {
                vstate.settleAtCurrentOffset()
            }

            if !vstate.viewOffsetPixels.isGesture {
                guard vstate.beginGesture(isTrackpad: true, columns: columns) else { return }
            }

            _ = vstate.updateGesture(
                deltaPixels: delta,
                timestamp: timestamp,
                isTrackpad: true,
                columns: columns,
                gap: gap,
                viewportWidth: viewportWidth
            )
            didApply = true
        }
        if didApply {
            controller.layoutRefreshController.requestImmediateRelayout(reason: .interactiveGesture)
        }
    }

    private func applyMouseWheelColumnTicks(
        _ ticks: Int,
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID,
        monitor: Monitor
    ) {
        guard let controller else { return }
        let insetFrame = controller.insetWorkingFrame(for: monitor)
        let gap = CGFloat(controller.workspaceManager.gaps)
        let step = ticks > 0 ? 1 : -1
        let motion = controller.motionPolicy.snapshot()

        var didApply = false
        var shouldStartAnimation = false
        controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
            if vstate.viewOffsetPixels.gestureRef?.isTrackpad == true {
                return
            }

            for _ in 0 ..< abs(ticks) {
                let columns = engine.columns(in: wsId)
                let targetColumnIndex = vstate.activeColumnIndex + step
                guard columns.indices.contains(targetColumnIndex),
                      let currentNode = currentSelectionNode(engine: engine, wsId: wsId, state: vstate),
                      let newNode = engine.focusColumn(
                          targetColumnIndex,
                          currentSelection: currentNode,
                          in: wsId,
                          motion: motion,
                          state: &vstate,
                          workingFrame: insetFrame,
                          gaps: gap
                      )
                else {
                    break
                }

                controller.niriLayoutHandler.activateNode(
                    newNode,
                    in: wsId,
                    state: &vstate,
                    options: .init(
                        activateWindow: true,
                        ensureVisible: false,
                        updateTimestamp: true,
                        layoutRefresh: false,
                        axFocus: false,
                        startAnimation: false
                    )
                )
                didApply = true
            }
            shouldStartAnimation = vstate.viewOffsetPixels.isAnimating
        }

        if didApply {
            controller.layoutRefreshController.requestImmediateRelayout(reason: .interactiveGesture)
            if shouldStartAnimation {
                controller.layoutRefreshController.startScrollAnimation(for: wsId)
            }
        }
    }

    func finalizeOrCancelCommittedGesture(
        using lockedContext: State.LockedGestureContext,
        engine: NiriLayoutEngine,
        timestamp: TimeInterval? = nil
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
        let scale = NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?
            .backingScaleFactor ?? 2.0

        var selectedWindow: NiriWindow?
        controller.workspaceManager.withNiriViewportState(for: wsId) { endState in
            endState.endGesture(
                columns: columns,
                gap: gap,
                viewportWidth: insetFrame.width,
                motion: controller.motionPolicy.snapshot(),
                isTrackpad: true,
                snapToColumn: true,
                centerMode: engine.centerFocusedColumn,
                alwaysCenterSingleColumn: engine.alwaysCenterSingleColumn,
                workingArea: insetFrame,
                viewFrame: monitor.frame,
                scale: scale,
                timestamp: timestamp
            )
            selectedWindow = syncViewportSelectionToActiveColumn(columns: columns, state: &endState)
        }
        if let selectedWindow {
            rememberViewportFocusAnchor(selectedWindow, engine: engine, wsId: wsId)
        }
        controller.layoutRefreshController.startScrollAnimation(for: wsId)
    }

    private func finalizeCommittedGestureAfterTouchRelease(
        engine: NiriLayoutEngine,
        timestamp: TimeInterval
    ) {
        guard let lockedContext = state.lockedGestureContext else {
            assertionFailure("Committed gesture missing locked context")
            resetGestureState()
            return
        }
        finalizeOrCancelCommittedGesture(
            using: lockedContext,
            engine: engine,
            timestamp: timestamp
        )
        resetGestureState()
    }

    private func cancelCommittedGestureViewportState(for wsId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        var didCancel = false
        controller.workspaceManager.withNiriViewportState(for: wsId) { vstate in
            guard vstate.viewOffsetPixels.isGesture || vstate.viewOffsetPixels.isAnimating else { return }
            vstate.settleAtCurrentOffset()
            vstate.selectionProgress = 0.0
            vstate.viewOffsetToRestore = nil
            vstate.activatePrevColumnOnRemoval = nil
            didCancel = true
        }
        if didCancel {
            controller.layoutRefreshController.requestImmediateRelayout(reason: .interactiveGesture)
        }
    }

    private func abortActiveGestureIfNeeded() {
        if state.gesturePhase == .committed {
            guard let lockedContext = state.lockedGestureContext else {
                assertionFailure("Committed gesture missing locked context")
                resetGestureState()
                return
            }
            if let engine = controller?.niriEngine {
                finalizeOrCancelCommittedGesture(using: lockedContext, engine: engine)
            } else {
                cancelCommittedGestureViewportState(for: lockedContext.workspaceId)
            }
        }
        resetGestureState()
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
        case .niri,
             .defaultLayout:
            return (engine, workspace.id, monitor)
        case .dwindle:
            return nil
        }
    }

    private func resetGestureState() {
        state.gesturePhase = .idle
        state.gestureStartX = 0.0
        state.gestureStartY = 0.0
        state.gestureLastAverageX = 0.0
        state.gestureLastAverageY = 0.0
        state.lockedGestureContext = nil
    }

    private func currentSelectionNode(
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID,
        state: ViewportState
    ) -> NiriNode? {
        if let selectedNodeId = state.selectedNodeId,
           let selectedNode = engine.findNode(by: selectedNodeId)
        {
            return selectedNode
        }

        let columns = engine.columns(in: wsId)
        guard columns.indices.contains(state.activeColumnIndex) else { return nil }
        let activeColumn = columns[state.activeColumnIndex]
        let windows = activeColumn.windowNodes
        guard !windows.isEmpty else { return activeColumn.firstChild() }
        let activeTileIndex = activeColumn.activeTileIdx.clamped(to: 0 ... (windows.count - 1))
        return windows[activeTileIndex]
    }

    private func syncViewportSelectionToActiveColumn(
        columns: [NiriContainer],
        state: inout ViewportState
    ) -> NiriWindow? {
        guard columns.indices.contains(state.activeColumnIndex) else { return nil }
        let activeColumn = columns[state.activeColumnIndex]
        let windows = activeColumn.windowNodes
        guard !windows.isEmpty else { return nil }
        let activeTileIndex = activeColumn.activeTileIdx.clamped(to: 0 ... (windows.count - 1))
        let selectedWindow = windows[activeTileIndex]
        state.selectedNodeId = selectedWindow.id
        return selectedWindow
    }

    private func rememberViewportFocusAnchor(
        _ window: NiriWindow,
        engine: NiriLayoutEngine,
        wsId: WorkspaceDescriptor.ID
    ) {
        guard let controller else { return }
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: wsId,
                viewportState: nil,
                rememberedFocusToken: window.token
            )
        )
        engine.updateFocusTimestamp(for: window.id)
    }

    private nonisolated static func processTapCallback(
        type: CGEventType,
        event: CGEvent,
        isMainThread: Bool = Thread.isMainThread
    ) -> Bool {
        guard isMainThread else { return false }

        let location = event.location
        let screenLocation = ScreenCoordinateSpace.toAppKit(point: location)
        let modifiers = event.flags
        let scrollPayload: (deltaX: CGFloat, deltaY: CGFloat, momentumPhase: UInt32, phase: UInt32)?
        if type == .scrollWheel {
            scrollPayload = (
                resolvedWheelAxisDelta(
                    pointDelta: CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)),
                    fixedPointDelta: CGFloat(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
                ),
                resolvedWheelAxisDelta(
                    pointDelta: CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)),
                    fixedPointDelta: CGFloat(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
                ),
                UInt32(event.getIntegerValueField(.scrollWheelEventMomentumPhase)),
                UInt32(event.getIntegerValueField(.scrollWheelEventScrollPhase))
            )
        } else {
            scrollPayload = nil
        }
        var suppressEvent = false

        MainActor.assumeIsolated {
            guard let handler = MouseEventHandler._instance else { return }
            switch type {
            case .mouseMoved:
                handler.receiveTapMouseMoved(at: screenLocation)
            case .leftMouseDown:
                _ = handler.receiveTapMouseDown(at: screenLocation, modifiers: modifiers)
            case .leftMouseDragged:
                handler.receiveTapMouseDragged(at: screenLocation)
            case .leftMouseUp:
                handler.receiveTapMouseUp(at: screenLocation)
            case .rightMouseDown:
                suppressEvent = handler.receiveTapMouseDown(
                    at: screenLocation,
                    modifiers: modifiers,
                    button: .right
                )
            case .rightMouseDragged:
                suppressEvent = handler.shouldSuppressRightMouseEvent(type: type)
                handler.receiveTapMouseDragged(at: screenLocation, button: .right)
            case .rightMouseUp:
                suppressEvent = handler.shouldSuppressRightMouseEvent(type: type)
                handler.receiveTapMouseUp(at: screenLocation, button: .right)
            case .scrollWheel:
                guard let scrollPayload else { return }
                handler.receiveTapScrollWheel(
                    at: screenLocation,
                    deltaX: scrollPayload.deltaX,
                    deltaY: scrollPayload.deltaY,
                    momentumPhase: scrollPayload.momentumPhase,
                    phase: scrollPayload.phase,
                    modifiers: modifiers
                )
            default:
                break
            }
        }

        return suppressEvent
    }

    nonisolated static func resolvedWheelAxisDelta(pointDelta: CGFloat, fixedPointDelta: CGFloat) -> CGFloat {
        if abs(pointDelta) > mouseWheelAxisEpsilon {
            return pointDelta
        }
        return fixedPointDelta
    }

    nonisolated static func mouseWheelModifiersMatch(_ modifiers: CGEventFlags, required: CGEventFlags) -> Bool {
        modifierFlagsMatch(modifiers, required: required)
    }

    nonisolated static func modifierFlagsMatch(_ modifiers: CGEventFlags, required: CGEventFlags) -> Bool {
        modifiers.intersection(mouseRelevantModifierFlags) == required
    }

    nonisolated static func resolvedMouseWheelColumnDeltaValue(
        deltaX: CGFloat,
        deltaY: CGFloat,
        allowVerticalFallback: Bool
    ) -> CGFloat? {
        resolvedMouseWheelColumnDelta(
            deltaX: deltaX,
            deltaY: deltaY,
            allowVerticalFallback: allowVerticalFallback
        )?.value
    }

    private nonisolated static func resolvedMouseWheelColumnDelta(
        deltaX: CGFloat,
        deltaY: CGFloat,
        allowVerticalFallback: Bool
    ) -> MouseWheelColumnDelta? {
        if abs(deltaX) > mouseWheelAxisEpsilon {
            return MouseWheelColumnDelta(axis: .horizontal, value: deltaX)
        }
        guard allowVerticalFallback else {
            return nil
        }
        guard abs(deltaY) > mouseWheelAxisEpsilon else {
            return nil
        }
        return MouseWheelColumnDelta(axis: .vertical, value: deltaY)
    }

    private nonisolated static func processGestureTapCallback(
        type: CGEventType,
        event: CGEvent,
        isMainThread: Bool = Thread.isMainThread
    ) -> Bool {
        guard type.rawValue == NSEvent.EventType.gesture.rawValue else { return false }
        guard isMainThread else { return false }
        guard let snapshot = makeGestureEventSnapshot(from: event) else { return true }

        MainActor.assumeIsolated {
            MouseEventHandler._instance?.receiveTapGestureEvent(snapshot)
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

    private nonisolated static func sanitizedGestureTouchPosition(_ position: CGPoint) -> CGPoint? {
        guard position.x.isFinite, position.y.isFinite else { return nil }
        return position
    }

    private nonisolated static func makeGestureEventSnapshot(from cgEvent: CGEvent) -> GestureEventSnapshot? {
        guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return nil }
        return GestureEventSnapshot(
            location: ScreenCoordinateSpace.toAppKit(point: cgEvent.location),
            phaseRawValue: nsEvent.phase.rawValue,
            timestamp: nsEvent.timestamp,
            touches: nsEvent.allTouches().map { touch in
                GestureTouchSample(
                    phase: touch.phase,
                    normalizedPosition: sanitizedGestureTouchPosition(touch.normalizedPosition)
                )
            }
        )
    }
}
