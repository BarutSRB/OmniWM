import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

private func makeMouseEventTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.mouse-event.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func makeMouseEventTestWindow(windowId: Int = 101) -> AXWindowRef {
    AXWindowRef(element: AXUIElementCreateSystemWide(), windowId: windowId)
}

@MainActor
private func makeOwnedUtilityTestWindow(
    frame: CGRect = CGRect(x: 40, y: 40, width: 240, height: 180)
) -> NSWindow {
    let window = NSWindow(
        contentRect: frame,
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    return window
}

@MainActor
private func makeMouseEventTestController(
    workspaceConfigurations: [WorkspaceConfiguration]? = nil
) -> WMController {
    let operations = WindowFocusOperations(
        activateApp: { _ in },
        focusSpecificWindow: { _, _, _ in },
        raiseWindow: { _ in }
    )
    let settings = SettingsStore(defaults: makeMouseEventTestDefaults())
    if let workspaceConfigurations {
        settings.workspaceConfigurations = workspaceConfigurations
    }
    let controller = WMController(settings: settings, windowFocusOperations: operations)
    controller.lockScreenObserver.frontmostApplicationProvider = { nil }
    let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let monitor = Monitor(
        id: Monitor.ID(displayId: 1),
        displayId: 1,
        frame: frame,
        visibleFrame: frame,
        hasNotch: false,
        name: "Main"
    )
    controller.workspaceManager.applyMonitorConfigurationChange([monitor])
    return controller
}

@MainActor
private func prepareMouseResizeFixture(
    constraints: WindowSizeConstraints = .unconstrained
) async -> (
    controller: WMController,
    handler: MouseEventHandler,
    handle: WindowHandle,
    workspaceId: WorkspaceDescriptor.ID,
    nodeId: NodeId,
    nodeFrame: CGRect,
    location: CGPoint
) {
    let controller = makeMouseEventTestController()
    controller.enableNiriLayout()
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
    controller.syncMonitorsToNiriEngine()

    guard let workspaceId = controller.activeWorkspace()?.id else {
        fatalError("Missing active workspace for mouse fixture")
    }

    let token = controller.workspaceManager.addWindow(
        makeMouseEventTestWindow(windowId: 901),
        pid: getpid(),
        windowId: 901,
        to: workspaceId
    )
    controller.workspaceManager.setCachedConstraints(constraints, for: token)
    guard let handle = controller.workspaceManager.handle(for: token) else {
        fatalError("Missing bridge handle for mouse fixture")
    }
    _ = controller.workspaceManager.rememberFocus(handle, in: workspaceId)

    guard let engine = controller.niriEngine else {
        fatalError("Missing Niri engine for mouse fixture")
    }

    let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
    _ = engine.syncWindows(
        handles,
        in: workspaceId,
        selectedNodeId: nil,
        focusedHandle: handle
    )

    controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
    await controller.layoutRefreshController.waitForRefreshWorkForTests()

    guard let node = engine.findNode(for: handle),
          let nodeFrame = node.frame,
          let monitor = controller.workspaceManager.monitor(for: workspaceId)
    else {
        fatalError("Failed to prepare interactive resize fixture")
    }

    controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
        state.selectedNodeId = node.id
    }

    let location = CGPoint(x: monitor.visibleFrame.midX, y: monitor.visibleFrame.midY)
    return (controller, controller.mouseEventHandler, handle, workspaceId, node.id, nodeFrame, location)
}

@Suite(.serialized) struct MouseEventHandlerTests {
    @Test @MainActor func lockedInputHandlersAreNoOps() async {
        let controller = makeMouseEventTestController()
        controller.isLockScreenActive = true

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        let handler = controller.mouseEventHandler
        handler.dispatchMouseMoved(at: CGPoint(x: 50, y: 50))
        handler.dispatchMouseDown(at: CGPoint(x: 50, y: 50), modifiers: [])
        handler.dispatchMouseDragged(at: CGPoint(x: 60, y: 60))
        handler.dispatchMouseUp(at: CGPoint(x: 60, y: 60))
        handler.dispatchScrollWheel(
            at: CGPoint(x: 50, y: 50),
            deltaX: 0,
            deltaY: 12,
            momentumPhase: 0,
            phase: 0,
            modifiers: []
        )

        guard let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: .zero,
            mouseButton: .left
        ) else {
            Issue.record("Failed to create CGEvent")
            return
        }
        handler.dispatchGestureEvent(from: cgEvent)

        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(relayoutReasons.isEmpty)
        #expect(handler.state.isMoving == false)
        #expect(handler.state.isResizing == false)
        #expect(controller.workspaceManager.pendingFocusedHandle == nil)
    }

    @Test @MainActor func resizeEndUsesInteractiveGestureImmediateRelayout() async {
        let fixture = await prepareMouseResizeFixture()
        guard let engine = fixture.controller.niriEngine else {
            Issue.record("Missing Niri engine")
            return
        }

        #expect(engine.interactiveResizeBegin(
            windowId: fixture.nodeId,
            edges: [.right],
            startLocation: fixture.location,
            in: fixture.workspaceId
        ))

        fixture.handler.state.isResizing = true

        var relayoutEvents: [(RefreshReason, LayoutRefreshController.RefreshRoute)] = []
        fixture.controller.layoutRefreshController.resetDebugState()
        fixture.controller.layoutRefreshController.debugHooks.onRelayout = { reason, route in
            relayoutEvents.append((reason, route))
            return true
        }

        fixture.handler.dispatchMouseUp(at: fixture.location)
        await fixture.controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(relayoutEvents.map(\.0) == [.interactiveGesture])
        #expect(relayoutEvents.map(\.1) == [.immediateRelayout])
        #expect(fixture.handler.state.isResizing == false)
    }

    @Test @MainActor func queuedMouseMovesCollapseToLatestLocation() async {
        let fixture = await prepareMouseResizeFixture()

        let center = CGPoint(x: fixture.nodeFrame.midX, y: fixture.nodeFrame.midY)
        let rightEdge = CGPoint(x: fixture.nodeFrame.maxX - 1, y: fixture.nodeFrame.midY)

        fixture.handler.resetDebugStateForTests()
        fixture.handler.receiveTapMouseMoved(at: center)
        fixture.handler.receiveTapMouseMoved(at: rightEdge)
        fixture.handler.flushPendingTapEventsForTests()

        let debugSnapshot = fixture.handler.mouseTapDebugSnapshot()
        #expect(debugSnapshot.queuedTransientEvents == 2)
        #expect(debugSnapshot.coalescedTransientEvents == 1)
        #expect(debugSnapshot.drainedTransientEvents == 1)
        #expect(fixture.handler.state.currentHoveredEdges == [.right])
    }

    @Test @MainActor func queuedResizeDragFlushesBeforeMouseUpUsingLatestLocation() async {
        let fixture = await prepareMouseResizeFixture()
        guard let engine = fixture.controller.niriEngine,
              let resizeWindow = engine.findNode(for: fixture.handle),
              let column = engine.findColumn(containing: resizeWindow, in: fixture.workspaceId),
              let monitor = fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)
        else {
            Issue.record("Missing Niri resize state")
            return
        }

        let originalWidth = column.cachedWidth
        let insetFrame = fixture.controller.insetWorkingFrame(for: monitor)
        let maxWidth = insetFrame.width - CGFloat(fixture.controller.workspaceManager.gaps)
        let expectedWidth = min(originalWidth + 24, maxWidth)

        #expect(engine.interactiveResizeBegin(
            windowId: fixture.nodeId,
            edges: [.right],
            startLocation: fixture.location,
            in: fixture.workspaceId
        ))

        fixture.handler.state.isResizing = true
        fixture.handler.resetDebugStateForTests()

        fixture.handler.receiveTapMouseDragged(
            at: CGPoint(x: fixture.location.x + 8, y: fixture.location.y)
        )
        fixture.handler.receiveTapMouseDragged(
            at: CGPoint(x: fixture.location.x + 24, y: fixture.location.y)
        )
        fixture.handler.pressedMouseButtonsProvider = { 0 }
        fixture.handler.receiveTapMouseUp(
            at: CGPoint(x: fixture.location.x + 24, y: fixture.location.y)
        )
        await fixture.controller.layoutRefreshController.waitForRefreshWorkForTests()

        let debugSnapshot = fixture.handler.mouseTapDebugSnapshot()
        #expect(debugSnapshot.queuedTransientEvents == 2)
        #expect(debugSnapshot.coalescedTransientEvents == 1)
        #expect(debugSnapshot.drainedTransientEvents == 1)
        #expect(debugSnapshot.flushedBeforeImmediateDispatch == 1)
        #expect(abs(column.cachedWidth - expectedWidth) < 0.001)
        #expect(fixture.handler.state.isResizing == false)
    }

    @Test @MainActor func queuedResizeDragClampsToColumnMaxWidthConstraint() async {
        let fixture = await prepareMouseResizeFixture()
        guard let engine = fixture.controller.niriEngine,
              let resizeWindow = engine.findNode(for: fixture.handle),
              let column = engine.findColumn(containing: resizeWindow, in: fixture.workspaceId)
        else {
            Issue.record("Missing Niri resize state for max-width regression test")
            return
        }

        let originalWidth = column.cachedWidth
        let cappedWidth = originalWidth + 12
        let constraints = WindowSizeConstraints(
            minSize: CGSize(width: 1, height: 1),
            maxSize: CGSize(width: cappedWidth, height: 0),
            isFixed: false
        )

        fixture.controller.workspaceManager.setCachedConstraints(constraints, for: fixture.handle.id)
        engine.updateWindowConstraints(for: fixture.handle, constraints: constraints)

        #expect(engine.interactiveResizeBegin(
            windowId: fixture.nodeId,
            edges: [.right],
            startLocation: fixture.location,
            in: fixture.workspaceId
        ))

        fixture.handler.state.isResizing = true
        fixture.handler.receiveTapMouseDragged(
            at: CGPoint(x: fixture.location.x + 24, y: fixture.location.y)
        )
        fixture.handler.pressedMouseButtonsProvider = { 0 }
        fixture.handler.receiveTapMouseUp(
            at: CGPoint(x: fixture.location.x + 24, y: fixture.location.y)
        )
        await fixture.controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(abs(column.cachedWidth - cappedWidth) < 0.001)
        #expect(fixture.handler.state.isResizing == false)
    }

    @Test @MainActor func offMainThreadMouseTapCallbackFailsOpenWithoutQueueingState() {
        let controller = makeMouseEventTestController()
        let handler = controller.mouseEventHandler

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 50, y: 50),
            mouseButton: .left
        ) else {
            Issue.record("Failed to create CGEvent")
            return
        }

        let processed = handler.handleTapCallbackForTests(
            type: .mouseMoved,
            event: event,
            isMainThread: false
        )

        #expect(processed == false)
        #expect(handler.mouseTapDebugSnapshot() == .init())
        #expect(handler.state.pendingTapEvents.hasPendingEvents == false)
        #expect(handler.state.currentHoveredEdges == [])
    }

    @Test @MainActor func offMainThreadGestureTapCallbackFailsOpenWithoutMutatingGestureState() {
        let controller = makeMouseEventTestController()
        let handler = controller.mouseEventHandler

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 50, y: 50),
            mouseButton: .left
        ) else {
            Issue.record("Failed to create CGEvent")
            return
        }

        guard let gestureType = CGEventType(rawValue: UInt32(NSEvent.EventType.gesture.rawValue)) else {
            Issue.record("Failed to create gesture CGEventType")
            return
        }

        let processed = handler.handleGestureTapCallbackForTests(
            type: gestureType,
            event: event,
            isMainThread: false
        )

        #expect(processed == false)
        #expect(handler.state.pendingTapEvents.hasPendingEvents == false)
    }

    @Test @MainActor func gestureTouchAverageRejectsInvalidTouchPositions() {
        let touches: [MouseEventHandler.GestureTouchSample] = [
            .init(phase: .touching, normalizedPosition: CGPoint(x: 0.25, y: 0.5)),
            .init(phase: .touching, normalizedPosition: nil),
        ]

        let average = MouseEventHandler.averageGestureTouchPosition(
            requiredFingers: 2,
            touches: touches
        )

        #expect(average == nil)
    }

    @Test @MainActor func scrollBurstOnlyMergesWithinMatchingModifierAndPhaseGroups() {
        let controller = makeMouseEventTestController()
        let handler = controller.mouseEventHandler

        handler.resetDebugStateForTests()
        handler.receiveTapScrollWheel(
            at: CGPoint(x: 10, y: 10),
            deltaX: 0,
            deltaY: 4,
            momentumPhase: 0,
            phase: 0,
            modifiers: [.maskAlternate]
        )
        handler.receiveTapScrollWheel(
            at: CGPoint(x: 10, y: 10),
            deltaX: 0,
            deltaY: 6,
            momentumPhase: 0,
            phase: 0,
            modifiers: [.maskAlternate]
        )
        handler.receiveTapScrollWheel(
            at: CGPoint(x: 10, y: 10),
            deltaX: 0,
            deltaY: 8,
            momentumPhase: 1,
            phase: 0,
            modifiers: [.maskAlternate]
        )
        handler.flushPendingTapEventsForTests()

        let debugSnapshot = handler.mouseTapDebugSnapshot()
        #expect(debugSnapshot.queuedTransientEvents == 3)
        #expect(debugSnapshot.coalescedTransientEvents == 1)
        #expect(debugSnapshot.drainRuns == 2)
        #expect(debugSnapshot.drainedTransientEvents == 2)
    }

    @Test @MainActor func ownedWindowMouseDownDropsQueuedTapEventsInsteadOfFlushingThem() {
        let controller = makeMouseEventTestController()
        let handler = controller.mouseEventHandler
        let window = makeOwnedUtilityTestWindow()
        let registry = OwnedWindowRegistry.shared

        registry.resetForTests()
        registry.register(window)
        defer {
            registry.unregister(window)
            window.close()
            registry.resetForTests()
        }

        handler.resetDebugStateForTests()
        handler.receiveTapMouseMoved(at: CGPoint(x: 10, y: 10))
        #expect(handler.state.pendingTapEvents.hasPendingEvents)

        handler.receiveTapMouseDown(at: CGPoint(x: 80, y: 80), modifiers: [])

        let debugSnapshot = handler.mouseTapDebugSnapshot()
        #expect(debugSnapshot.flushedBeforeImmediateDispatch == 0)
        #expect(debugSnapshot.drainRuns == 0)
        #expect(debugSnapshot.drainedTransientEvents == 0)
        #expect(handler.state.pendingTapEvents.hasPendingEvents == false)
    }

    @Test @MainActor func ownedWindowDragCancelsActiveNiriMoveAndResize() async {
        let fixture = await prepareMouseResizeFixture()
        guard let engine = fixture.controller.niriEngine,
              let monitor = fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)
        else {
            Issue.record("Missing Niri context for owned-window drag cancellation test")
            return
        }

        let ownedWindow = makeOwnedUtilityTestWindow(
            frame: CGRect(x: fixture.location.x - 40, y: fixture.location.y - 40, width: 80, height: 80)
        )
        let registry = OwnedWindowRegistry.shared
        registry.resetForTests()
        registry.register(ownedWindow)
        defer {
            registry.unregister(ownedWindow)
            ownedWindow.close()
            registry.resetForTests()
        }

        var moveStarted = false
        fixture.controller.workspaceManager.withNiriViewportState(for: fixture.workspaceId) { state in
            moveStarted = engine.interactiveMoveBegin(
                windowId: fixture.nodeId,
                windowHandle: fixture.handle,
                startLocation: fixture.location,
                in: fixture.workspaceId,
                state: &state,
                workingFrame: fixture.controller.insetWorkingFrame(for: monitor),
                gaps: CGFloat(fixture.controller.workspaceManager.gaps)
            )
        }
        #expect(moveStarted)
        fixture.handler.state.isMoving = true

        fixture.handler.dispatchMouseDragged(at: fixture.location)

        #expect(fixture.handler.state.isMoving == false)
        #expect(engine.interactiveMove == nil)

        #expect(engine.interactiveResizeBegin(
            windowId: fixture.nodeId,
            edges: [.right],
            startLocation: fixture.location,
            in: fixture.workspaceId
        ))
        fixture.handler.state.isResizing = true

        fixture.handler.dispatchMouseDragged(at: fixture.location)

        #expect(fixture.handler.state.isResizing == false)
        #expect(engine.interactiveResize == nil)
    }

    @Test @MainActor func focusFollowsMouseIgnoresCoveredTileBehindManagedFullscreen() async {
        let controller = makeMouseEventTestController()
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.setFocusFollowsMouse(true)

        guard let workspaceId = controller.activeWorkspace()?.id,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for fullscreen focus-follow regression test")
            return
        }

        let coveredToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 921),
            pid: getpid(),
            windowId: 921,
            to: workspaceId
        )
        let fullscreenToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 922),
            pid: getpid(),
            windowId: 922,
            to: workspaceId
        )
        guard let coveredHandle = controller.workspaceManager.handle(for: coveredToken),
              let fullscreenHandle = controller.workspaceManager.handle(for: fullscreenToken)
        else {
            Issue.record("Missing handles for fullscreen focus-follow regression test")
            return
        }

        let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
        _ = engine.syncWindows(
            handles,
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: fullscreenHandle
        )
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let coveredNode = engine.findNode(for: coveredHandle),
              let coveredFrame = coveredNode.frame,
              let fullscreenNode = engine.findNode(for: fullscreenHandle)
        else {
            Issue.record("Missing node frames for fullscreen focus-follow regression test")
            return
        }

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.selectedNodeId = fullscreenNode.id
            engine.toggleFullscreen(fullscreenNode, state: &state)
        }
        _ = controller.workspaceManager.setManagedFocus(fullscreenHandle, in: workspaceId, onMonitor: monitor.id)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let overlapPoint = CGPoint(x: coveredFrame.midX, y: coveredFrame.midY)
        #expect(coveredFrame.contains(overlapPoint))

        controller.mouseEventHandler.dispatchMouseMoved(at: overlapPoint)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.focusedHandle == fullscreenHandle)
        #expect(controller.workspaceManager.pendingFocusedHandle == nil)
    }

    @Test @MainActor func focusFollowsMouseActivatesHoveredDwindleWindow() async {
        let controller = makeMouseEventTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main, layoutType: .dwindle)
            ]
        )
        controller.enableDwindleLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.setFocusFollowsMouse(true)

        guard let workspaceId = controller.activeWorkspace()?.id,
              let engine = controller.dwindleEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Dwindle context for hover focus-follow test")
            return
        }

        let firstToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 941),
            pid: getpid(),
            windowId: 941,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 942),
            pid: getpid(),
            windowId: 942,
            to: workspaceId
        )
        guard let firstHandle = controller.workspaceManager.handle(for: firstToken),
              let secondHandle = controller.workspaceManager.handle(for: secondToken)
        else {
            Issue.record("Missing handles for Dwindle hover focus-follow test")
            return
        }

        _ = controller.workspaceManager.setManagedFocus(firstHandle, in: workspaceId, onMonitor: monitor.id)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let hoveredFrame = engine.findNode(for: secondToken)?.cachedFrame else {
            Issue.record("Missing Dwindle frame for hover focus-follow test")
            return
        }

        controller.mouseEventHandler.dispatchMouseMoved(
            at: CGPoint(x: hoveredFrame.midX, y: hoveredFrame.midY)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.focusedHandle == firstHandle)
        #expect(controller.workspaceManager.pendingFocusedHandle == secondHandle)
        #expect(engine.selectedNode(in: workspaceId)?.windowToken == secondToken)

        _ = controller.workspaceManager.setManagedFocus(secondHandle, in: workspaceId, onMonitor: monitor.id)
        #expect(controller.workspaceManager.focusedHandle == secondHandle)
        #expect(controller.workspaceManager.pendingFocusedHandle == nil)
    }

    @Test @MainActor func focusFollowsMousePrefersDwindleFullscreenWindowOverCoveredTile() async {
        let controller = makeMouseEventTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main, layoutType: .dwindle)
            ]
        )
        controller.enableDwindleLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.setFocusFollowsMouse(true)

        guard let workspaceId = controller.activeWorkspace()?.id,
              let engine = controller.dwindleEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Dwindle context for fullscreen focus-follow test")
            return
        }

        let coveredToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 951),
            pid: getpid(),
            windowId: 951,
            to: workspaceId
        )
        let fullscreenToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 952),
            pid: getpid(),
            windowId: 952,
            to: workspaceId
        )
        guard let coveredHandle = controller.workspaceManager.handle(for: coveredToken),
              let fullscreenHandle = controller.workspaceManager.handle(for: fullscreenToken)
        else {
            Issue.record("Missing handles for Dwindle fullscreen focus-follow test")
            return
        }

        _ = controller.workspaceManager.setManagedFocus(coveredHandle, in: workspaceId, onMonitor: monitor.id)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let fullscreenNode = engine.findNode(for: fullscreenToken) else {
            Issue.record("Missing Dwindle fullscreen node for focus-follow test")
            return
        }

        engine.setSelectedNode(fullscreenNode, in: workspaceId)
        #expect(engine.toggleFullscreen(in: workspaceId) == fullscreenToken)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .layoutCommand)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        engine.tickAnimations(at: controller.animationClock.now() + 10.0, in: workspaceId)

        guard let coveredFrame = engine.findNode(for: coveredToken)?.cachedFrame,
              let fullscreenFrame = engine.findNode(for: fullscreenToken)?.cachedFrame
        else {
            Issue.record("Missing Dwindle frames for fullscreen focus-follow test")
            return
        }

        let overlapPoint = CGPoint(x: coveredFrame.midX, y: coveredFrame.midY)
        #expect(coveredFrame.contains(overlapPoint))
        #expect(fullscreenFrame.contains(overlapPoint))
        #expect(
            engine.hitTestFocusableWindow(
                point: overlapPoint,
                in: workspaceId,
                at: controller.animationClock.now()
            ) == fullscreenToken
        )

        controller.mouseEventHandler.dispatchMouseMoved(at: overlapPoint)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.focusedHandle == coveredHandle)
        #expect(controller.workspaceManager.pendingFocusedHandle == fullscreenHandle)
        #expect(engine.selectedNode(in: workspaceId)?.windowToken == fullscreenToken)

        _ = controller.workspaceManager.setManagedFocus(fullscreenHandle, in: workspaceId, onMonitor: monitor.id)
        #expect(controller.workspaceManager.focusedHandle == fullscreenHandle)
        #expect(controller.workspaceManager.pendingFocusedHandle == nil)
    }

    @Test @MainActor func focusFollowsMouseUsesDwindleGeometryWithoutConsultingNiriLayout() async {
        let controller = makeMouseEventTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main, layoutType: .dwindle)
            ]
        )
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        controller.enableDwindleLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.setFocusFollowsMouse(true)

        guard let workspaceId = controller.activeWorkspace()?.id,
              let niriEngine = controller.niriEngine,
              let dwindleEngine = controller.dwindleEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing layout context for cross-layout focus-follow regression test")
            return
        }

        let token = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 931),
            pid: getpid(),
            windowId: 931,
            to: workspaceId
        )
        guard let handle = controller.workspaceManager.handle(for: token) else {
            Issue.record("Missing handle for cross-layout focus-follow regression test")
            return
        }

        _ = niriEngine.syncWindows(
            [handle],
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: handle
        )
        _ = niriEngine.calculateCombinedLayoutUsingPools(
            in: workspaceId,
            monitor: monitor,
            gaps: LayoutGaps(
                horizontal: CGFloat(controller.workspaceManager.gaps),
                vertical: CGFloat(controller.workspaceManager.gaps),
                outer: controller.workspaceManager.outerGaps
            ),
            state: controller.workspaceManager.niriViewportState(for: workspaceId),
            workingArea: WorkingAreaContext(
                workingFrame: monitor.visibleFrame,
                viewFrame: monitor.frame,
                scale: 2.0
            ),
            animationTime: nil
        )

        guard let staleNiriFrame = niriEngine.findNode(for: handle)?.frame else {
            Issue.record("Missing stale Niri frame for cross-layout focus-follow regression test")
            return
        }

        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let dwindleFrame = dwindleEngine.findNode(for: token)?.cachedFrame else {
            Issue.record("Missing Dwindle frame for cross-layout focus-follow regression test")
            return
        }

        let staleOnlyCandidates = [
            CGPoint(x: staleNiriFrame.midX, y: staleNiriFrame.midY),
            CGPoint(x: staleNiriFrame.minX + 1, y: staleNiriFrame.minY + 1),
            CGPoint(x: staleNiriFrame.maxX - 1, y: staleNiriFrame.minY + 1),
            CGPoint(x: staleNiriFrame.minX + 1, y: staleNiriFrame.maxY - 1),
            CGPoint(x: staleNiriFrame.maxX - 1, y: staleNiriFrame.maxY - 1)
        ]
        guard let staleOnlyPoint = staleOnlyCandidates.first(where: {
            staleNiriFrame.contains($0) && !dwindleFrame.contains($0)
        }) else {
            Issue.record("Expected a Niri-only hover point for cross-layout focus-follow regression test")
            return
        }

        controller.mouseEventHandler.dispatchMouseMoved(at: staleOnlyPoint)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.pendingFocusedHandle == nil)
        #expect(controller.workspaceManager.focusedHandle == nil)

        controller.mouseEventHandler.dispatchMouseMoved(
            at: CGPoint(x: dwindleFrame.midX, y: dwindleFrame.midY)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        #expect(controller.workspaceManager.focusedHandle == nil)
        #expect(controller.workspaceManager.pendingFocusedHandle == handle)

        _ = controller.workspaceManager.setManagedFocus(handle, in: workspaceId, onMonitor: monitor.id)
        #expect(controller.workspaceManager.focusedHandle == handle)
        #expect(controller.workspaceManager.pendingFocusedHandle == nil)
    }
}
