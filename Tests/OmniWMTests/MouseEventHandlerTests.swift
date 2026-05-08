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

private func makeGestureTouchSamples(
    xPositions: [CGFloat],
    yPosition: CGFloat = 0.5,
    phase: NSTouch.Phase = .touching
) -> [MouseEventHandler.GestureTouchSample] {
    xPositions.map { xPosition in
        MouseEventHandler.GestureTouchSample(
            phase: phase,
            normalizedPosition: CGPoint(x: xPosition, y: yPosition)
        )
    }
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

@MainActor
private func prepareCommittedTrackpadGestureFixture() async -> (
    controller: WMController,
    handler: MouseEventHandler,
    workspaceId: WorkspaceDescriptor.ID,
    location: CGPoint
) {
    let controller = makeMouseEventTestController()
    controller.settings.scrollGestureEnabled = true
    controller.enableNiriLayout(maxWindowsPerColumn: 1)
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
    controller.syncMonitorsToNiriEngine()

    guard let workspaceId = controller.activeWorkspace()?.id,
          let monitor = controller.workspaceManager.monitor(for: workspaceId),
          let engine = controller.niriEngine
    else {
        fatalError("Missing Niri context for committed gesture fixture")
    }

    populateNiriWorkspaceForMouseTests(
        controller: controller,
        engine: engine,
        workspaceId: workspaceId,
        monitor: monitor,
        startingWindowId: 540
    )
    controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
    await controller.layoutRefreshController.waitForRefreshWorkForTests()

    let handler = controller.mouseEventHandler
    let location = CGPoint(x: monitor.visibleFrame.midX, y: monitor.visibleFrame.midY)
    let baseTime = CACurrentMediaTime()

    handler.receiveTapGestureEvent(
        .init(
            location: location,
            phaseRawValue: NSEvent.Phase.began.rawValue,
            timestamp: baseTime,
            touches: makeGestureTouchSamples(xPositions: [0.20, 0.25, 0.30])
        )
    )
    handler.receiveTapGestureEvent(
        .init(
            location: location,
            phaseRawValue: NSEvent.Phase.changed.rawValue,
            timestamp: baseTime + 0.016,
            touches: makeGestureTouchSamples(xPositions: [0.60, 0.65, 0.70])
        )
    )

    return (controller, handler, workspaceId, location)
}

@MainActor
@discardableResult
private func populateNiriWorkspaceForMouseTests(
    controller: WMController,
    engine: NiriLayoutEngine,
    workspaceId: WorkspaceDescriptor.ID,
    monitor: Monitor,
    startingWindowId: Int,
    count: Int = 3
) -> WindowHandle {
    var focusedHandle: WindowHandle?
    for index in 0 ..< count {
        let windowId = startingWindowId + index
        let token = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: windowId),
            pid: getpid(),
            windowId: windowId,
            to: workspaceId
        )
        if focusedHandle == nil {
            focusedHandle = controller.workspaceManager.handle(for: token)
        }
    }

    guard let focusedHandle else {
        fatalError("Missing focused handle for niri mouse fixture")
    }

    let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
    _ = engine.syncWindows(
        handles,
        in: workspaceId,
        selectedNodeId: nil,
        focusedHandle: focusedHandle
    )
    _ = controller.workspaceManager.setManagedFocus(focusedHandle, in: workspaceId, onMonitor: monitor.id)
    return focusedHandle
}

@MainActor
private func prepareMouseWheelScrollFixture() async -> (
    controller: WMController,
    handler: MouseEventHandler,
    workspaceId: WorkspaceDescriptor.ID,
    location: CGPoint
) {
    let controller = makeMouseEventTestController()
    controller.settings.scrollGestureEnabled = true
    controller.settings.scrollSensitivity = 1.0
    let frame = CGRect(x: 0, y: 0, width: 640, height: 800)
    let monitor = Monitor(
        id: Monitor.ID(displayId: 1),
        displayId: 1,
        frame: frame,
        visibleFrame: frame,
        hasNotch: false,
        name: "Main"
    )
    controller.workspaceManager.applyMonitorConfigurationChange([monitor])
    controller.enableNiriLayout(maxWindowsPerColumn: 1)
    await controller.layoutRefreshController.waitForRefreshWorkForTests()
    controller.syncMonitorsToNiriEngine()

    guard let workspaceId = controller.activeWorkspace()?.id,
          let monitor = controller.workspaceManager.monitor(for: workspaceId),
          let engine = controller.niriEngine
    else {
        fatalError("Missing Niri context for mouse wheel fixture")
    }

    populateNiriWorkspaceForMouseTests(
        controller: controller,
        engine: engine,
        workspaceId: workspaceId,
        monitor: monitor,
        startingWindowId: 580,
        count: 5
    )

    controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
        state.viewOffsetPixels = .static(0)
    }
    controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
    await controller.layoutRefreshController.waitForRefreshWorkForTests()

    let location = CGPoint(x: monitor.visibleFrame.midX, y: monitor.visibleFrame.midY)
    return (controller, controller.mouseEventHandler, workspaceId, location)
}

@MainActor
private func prepareMouseWheelScrollFixtureWithDefaultSensitivity() async -> (
    controller: WMController,
    handler: MouseEventHandler,
    workspaceId: WorkspaceDescriptor.ID,
    location: CGPoint
) {
    let fixture = await prepareMouseWheelScrollFixture()
    fixture.controller.settings.scrollSensitivity = SettingsExport.defaults().scrollSensitivity
    return fixture
}

@Suite(.serialized) struct MouseEventHandlerTests {
    @Test func niriScrollTrackerMatchesWheelTickSemantics() {
        var tracker = NiriScrollTracker(tick: 120)

        #expect(tracker.accumulate(60) == 0)
        #expect(tracker.accumulate(60) == 1)
        #expect(tracker.accumulate(-60) == 0)
        #expect(tracker.accumulate(-60) == -1)

        tracker.reset()
        #expect(tracker.accumulate(20_000) == 127)
        #expect(abs(tracker.accumulator - 80) < 0.001)
    }

    @Test @MainActor func mouseWheelAxisResolutionPrefersPhysicalHorizontalInput() {
        let belowAxisEpsilonDelta: CGFloat = 0.0005

        #expect(MouseEventHandler.resolvedWheelAxisDelta(pointDelta: 3, fixedPointDelta: 9) == 3)
        #expect(MouseEventHandler.resolvedWheelAxisDelta(pointDelta: 0, fixedPointDelta: 9) == 9)
        #expect(
            MouseEventHandler.resolvedMouseWheelColumnDeltaValue(
                deltaX: 12,
                deltaY: 120,
                allowVerticalFallback: true
            ) == 12
        )
        #expect(
            MouseEventHandler.resolvedMouseWheelColumnDeltaValue(
                deltaX: 0,
                deltaY: 12,
                allowVerticalFallback: true
            ) == 12
        )
        #expect(
            MouseEventHandler.resolvedMouseWheelColumnDeltaValue(
                deltaX: 0,
                deltaY: 12,
                allowVerticalFallback: false
            ) == nil
        )
        #expect(
            MouseEventHandler.resolvedMouseWheelColumnDeltaValue(
                deltaX: belowAxisEpsilonDelta,
                deltaY: belowAxisEpsilonDelta,
                allowVerticalFallback: true
            ) == nil
        )
    }

    @Test @MainActor func mouseWheelModifierMatchingUsesExactNiriBindModifiers() {
        let required: CGEventFlags = [.maskAlternate, .maskShift]

        #expect(MouseEventHandler.mouseWheelModifiersMatch(required, required: required))
        #expect(MouseEventHandler.mouseWheelModifiersMatch([.maskAlternate, .maskShift, .maskCommand], required: required) == false)
        #expect(MouseEventHandler.mouseWheelModifiersMatch([.maskAlternate], required: required) == false)
    }

    @Test @MainActor func mouseWheelHorizontalAxisWinsAndFocusesNextColumn() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let before = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)

        fixture.handler.dispatchScrollWheel(
            at: fixture.location,
            deltaX: 120,
            deltaY: 1_000,
            momentumPhase: 0,
            phase: 0,
            modifiers: fixture.controller.settings.scrollModifierKey.cgEventFlag
        )

        let after = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        #expect(after.activeColumnIndex == before.activeColumnIndex + 1)
        #expect(after.viewOffsetPixels.isGesture == false)
    }

    @Test @MainActor func mouseWheelAccumulatesDiscreteNiriTicksBeforeFocusingColumn() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let before = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)

        fixture.handler.dispatchScrollWheel(
            at: fixture.location,
            deltaX: 60,
            deltaY: 0,
            momentumPhase: 0,
            phase: 0,
            modifiers: fixture.controller.settings.scrollModifierKey.cgEventFlag
        )

        let afterSmallDelta = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        #expect(afterSmallDelta.activeColumnIndex == before.activeColumnIndex)

        fixture.handler.dispatchScrollWheel(
            at: fixture.location,
            deltaX: 60,
            deltaY: 0,
            momentumPhase: 0,
            phase: 0,
            modifiers: fixture.controller.settings.scrollModifierKey.cgEventFlag
        )

        let after = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        #expect(after.activeColumnIndex == before.activeColumnIndex + 1)
        #expect(after.viewOffsetPixels.isGesture == false)
    }

    @Test @MainActor func mouseWheelDefaultSensitivityDoesNotMultiplyNiriTicks() async {
        let fixture = await prepareMouseWheelScrollFixtureWithDefaultSensitivity()
        let before = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)

        fixture.handler.dispatchScrollWheel(
            at: fixture.location,
            deltaX: 120,
            deltaY: 0,
            momentumPhase: 0,
            phase: 0,
            modifiers: fixture.controller.settings.scrollModifierKey.cgEventFlag
        )

        let after = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        #expect(after.activeColumnIndex == before.activeColumnIndex + 1)
    }

    @Test @MainActor func mouseWheelVerticalShiftFallbackFocusesNextColumn() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let before = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)

        fixture.handler.dispatchScrollWheel(
            at: fixture.location,
            deltaX: 0,
            deltaY: 120,
            momentumPhase: 0,
            phase: 0,
            modifiers: fixture.controller.settings.scrollModifierKey.cgEventFlag
        )

        let after = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        #expect(after.activeColumnIndex == before.activeColumnIndex + 1)
        #expect(after.viewOffsetPixels.isGesture == false)
    }

    @Test @MainActor func mouseWheelExtraModifiersDoNotTriggerConfiguredScroll() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let before = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)

        fixture.handler.dispatchScrollWheel(
            at: fixture.location,
            deltaX: 120,
            deltaY: 0,
            momentumPhase: 0,
            phase: 0,
            modifiers: fixture.controller.settings.scrollModifierKey.cgEventFlag.union(.maskCommand)
        )

        let after = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        #expect(after.activeColumnIndex == before.activeColumnIndex)
        #expect(after.selectedNodeId == before.selectedNodeId)
    }

    @Test @MainActor func mouseWheelScrollRebasesActiveColumnAfterCrossingColumnBoundary() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let focusedTokenBeforeScroll = fixture.controller.workspaceManager.focusedToken
        let before = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)

        fixture.handler.dispatchScrollWheel(
            at: fixture.location,
            deltaX: 1_000,
            deltaY: 0,
            momentumPhase: 0,
            phase: 0,
            modifiers: fixture.controller.settings.scrollModifierKey.cgEventFlag
        )

        let after = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        #expect(after.activeColumnIndex == min(before.activeColumnIndex + Int(1_000 / 120), 4))
        #expect(after.viewOffsetPixels.isGesture == false)
        #expect(after.selectionProgress == 0)

        guard let engine = fixture.controller.niriEngine else {
            Issue.record("Missing Niri engine after mouse wheel scroll")
            return
        }
        let columns = engine.columns(in: fixture.workspaceId)
        guard columns.indices.contains(after.activeColumnIndex) else {
            Issue.record("Mouse wheel scroll rebased to an invalid active column")
            return
        }
        let activeColumn = columns[after.activeColumnIndex]
        let windows = activeColumn.windowNodes
        guard !windows.isEmpty else {
            Issue.record("Mouse wheel scroll rebased to an empty active column")
            return
        }
        let expectedWindow = windows[activeColumn.activeTileIdx.clamped(to: 0 ... (windows.count - 1))]
        #expect(after.selectedNodeId == expectedWindow.id)
        #expect(fixture.controller.workspaceManager.lastFocusedToken(in: fixture.workspaceId) == expectedWindow.token)
        #expect(fixture.controller.workspaceManager.focusedToken == focusedTokenBeforeScroll)
    }

    @Test @MainActor func trackpadLikeScrollWheelEventDoesNotUseMouseWheelPath() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let before = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
            .viewOffsetPixels.current()

        fixture.handler.dispatchScrollWheel(
            at: fixture.location,
            deltaX: 50,
            deltaY: 0,
            momentumPhase: 1,
            phase: 0,
            modifiers: fixture.controller.settings.scrollModifierKey.cgEventFlag
        )

        let after = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        #expect(abs(after.viewOffsetPixels.current() - before) < 0.001)
        #expect(after.viewOffsetPixels.isGesture == false)
    }

    @Test @MainActor func trackpadGestureStartsFromCurrentAnimationOffset() async {
        let fixture = await prepareMouseWheelScrollFixture()
        guard let engine = fixture.controller.niriEngine,
              let monitor = fixture.controller.workspaceManager.monitor(for: fixture.workspaceId)
        else {
            Issue.record("Missing Niri context for animation handoff regression test")
            return
        }

        let animationStart = CACurrentMediaTime()
        fixture.controller.workspaceManager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.viewOffsetPixels = .spring(
                SpringAnimation(
                    from: 20,
                    to: 500,
                    startTime: animationStart,
                    config: .niriHorizontalViewMovement
                )
            )
        }

        fixture.handler.applyTrackpadViewportScrollDelta(
            0,
            engine: engine,
            wsId: fixture.workspaceId,
            monitor: monitor,
            timestamp: animationStart
        )

        let after = fixture.controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        guard let gesture = after.viewOffsetPixels.gestureRef else {
            Issue.record("Expected new trackpad gesture after interrupting animation")
            return
        }
        #expect(abs(gesture.stationaryViewOffset - 20) < 5)
    }

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

    @Test @MainActor func receiveTapGestureEventIsSuppressedWhileLocked() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let controller = fixture.controller
        let handler = fixture.handler
        let initialState = controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        handler.resetDebugStateForTests()
        handler.receiveTapMouseMoved(at: fixture.location)
        controller.isLockScreenActive = true

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        let baseTime = CACurrentMediaTime()
        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.began.rawValue,
                timestamp: baseTime,
                touches: makeGestureTouchSamples(xPositions: [0.20, 0.25, 0.30])
            )
        )
        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.016,
                touches: makeGestureTouchSamples(xPositions: [0.70, 0.75, 0.80])
            )
        )

        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let after = controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        let debugSnapshot = handler.mouseTapDebugSnapshot()
        #expect(abs(after.viewOffsetPixels.current() - initialState.viewOffsetPixels.current()) < 0.001)
        #expect(after.activeColumnIndex == initialState.activeColumnIndex)
        #expect(after.selectedNodeId == initialState.selectedNodeId)
        #expect(handler.state.gesturePhase == .idle)
        #expect(handler.state.lockedGestureContext == nil)
        #expect(controller.workspaceManager.pendingFocusedHandle == nil)
        #expect(debugSnapshot.queuedTransientEvents == 1)
        #expect(debugSnapshot.drainedTransientEvents == 0)
        #expect(relayoutReasons.isEmpty)
    }

    @Test @MainActor func receiveTapScrollWheelDropsLockedEventsBeforeQueueing() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let controller = fixture.controller
        let handler = fixture.handler
        let initialState = controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        let focusedTokenBeforeScroll = controller.workspaceManager.focusedToken
        controller.isLockScreenActive = true
        handler.resetDebugStateForTests()

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        handler.receiveTapScrollWheel(
            at: fixture.location,
            deltaX: 120,
            deltaY: 0,
            momentumPhase: 0,
            phase: 0,
            modifiers: controller.settings.scrollModifierKey.cgEventFlag
        )

        controller.isLockScreenActive = false
        handler.flushPendingTapEventsForTests()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let after = controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        let debugSnapshot = handler.mouseTapDebugSnapshot()
        #expect(after.activeColumnIndex == initialState.activeColumnIndex)
        #expect(after.selectedNodeId == initialState.selectedNodeId)
        #expect(abs(after.viewOffsetPixels.current() - initialState.viewOffsetPixels.current()) < 0.001)
        #expect(controller.workspaceManager.focusedToken == focusedTokenBeforeScroll)
        #expect(controller.workspaceManager.pendingFocusedHandle == nil)
        #expect(debugSnapshot.queuedTransientEvents == 0)
        #expect(relayoutReasons.isEmpty)
    }

    @Test @MainActor func lockTransitionDropsQueuedScrollBeforeUnlock() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let controller = fixture.controller
        let handler = fixture.handler
        let initialState = controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        handler.resetDebugStateForTests()

        handler.receiveTapScrollWheel(
            at: fixture.location,
            deltaX: 120,
            deltaY: 0,
            momentumPhase: 0,
            phase: 0,
            modifiers: controller.settings.scrollModifierKey.cgEventFlag
        )
        #expect(handler.state.pendingTapEvents.hasPendingEvents)

        controller.isLockScreenActive = true
        controller.isLockScreenActive = false
        handler.flushPendingTapEventsForTests()

        let after = controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        let debugSnapshot = handler.mouseTapDebugSnapshot()
        #expect(handler.state.pendingTapEvents.hasPendingEvents == false)
        #expect(after.activeColumnIndex == initialState.activeColumnIndex)
        #expect(after.selectedNodeId == initialState.selectedNodeId)
        #expect(debugSnapshot.queuedTransientEvents == 1)
        #expect(debugSnapshot.drainedTransientEvents == 0)
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

    @Test @MainActor func trackpadGestureDoesNotMutateNiriViewportStateOnDwindleWorkspace() async {
        let controller = makeMouseEventTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main, layoutType: .dwindle)
            ]
        )
        controller.settings.scrollGestureEnabled = true
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        controller.enableDwindleLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let workspaceId = controller.activeWorkspace()?.id,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing active workspace for Dwindle gesture regression test")
            return
        }

        let handler = controller.mouseEventHandler
        let location = CGPoint(x: monitor.visibleFrame.midX, y: monitor.visibleFrame.midY)

        controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
            state.activeColumnIndex = 2
            state.viewOffsetPixels = .static(-321)
            state.selectionProgress = 13
            state.viewOffsetToRestore = 77
            state.activatePrevColumnOnRemoval = 88
        }

        let baselineViewportState = controller.workspaceManager.niriViewportState(for: workspaceId)
        var relayoutReasons: [RefreshReason] = []

        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        #expect(baselineViewportState.viewOffsetPixels.isGesture == false)
        #expect(Double(baselineViewportState.viewOffsetPixels.target()) == -321)
        #expect(baselineViewportState.selectionProgress == 13)

        func assertViewportMatchesBaseline(
            _ actual: ViewportState,
            label: String
        ) {
            #expect(
                actual.activeColumnIndex == baselineViewportState.activeColumnIndex,
                Comment(rawValue: label)
            )
            #expect(
                abs(Double(actual.viewOffsetPixels.target()) - Double(baselineViewportState.viewOffsetPixels.target())) < 0.001,
                Comment(rawValue: label)
            )
            #expect(
                actual.viewOffsetPixels.isGesture == baselineViewportState.viewOffsetPixels.isGesture,
                Comment(rawValue: label)
            )
            #expect(
                actual.selectionProgress == baselineViewportState.selectionProgress,
                Comment(rawValue: label)
            )
            #expect(
                actual.viewOffsetToRestore == baselineViewportState.viewOffsetToRestore,
                Comment(rawValue: label)
            )
            #expect(
                actual.activatePrevColumnOnRemoval == baselineViewportState.activatePrevColumnOnRemoval,
                Comment(rawValue: label)
            )
        }

        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.began.rawValue,
                touches: makeGestureTouchSamples(xPositions: [0.20, 0.25, 0.30])
            )
        )
        #expect(handler.state.gesturePhase == .idle)
        #expect(handler.state.lockedGestureContext == nil)
        assertViewportMatchesBaseline(
            controller.workspaceManager.niriViewportState(for: workspaceId),
            label: "after began"
        )

        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                touches: makeGestureTouchSamples(xPositions: [0.70, 0.75, 0.80])
            )
        )
        #expect(handler.state.gesturePhase == .idle)
        #expect(handler.state.lockedGestureContext == nil)
        assertViewportMatchesBaseline(
            controller.workspaceManager.niriViewportState(for: workspaceId),
            label: "after changed"
        )

        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.ended.rawValue,
                touches: []
            )
        )

        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let mutatedViewportState = controller.workspaceManager.niriViewportState(for: workspaceId)
        assertViewportMatchesBaseline(mutatedViewportState, label: "after ended")
        #expect(relayoutReasons.isEmpty)
        #expect(controller.niriLayoutHandler.scrollAnimationByDisplay[monitor.displayId] == nil)
        #expect(handler.state.gesturePhase == .idle)
        #expect(handler.state.lockedGestureContext == nil)
    }

    @Test @MainActor func trackpadGestureFinalizesViewportGesture() async {
        let controller = makeMouseEventTestController()
        controller.settings.scrollGestureEnabled = true
        controller.settings.gestureInvertDirection = false
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let workspaceId = controller.activeWorkspace()?.id,
              let monitor = controller.workspaceManager.monitor(for: workspaceId),
              let engine = controller.niriEngine
        else {
            Issue.record("Missing Niri context for gesture diagnostic trace test")
            return
        }

        let firstToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 551),
            pid: getpid(),
            windowId: 551,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 552),
            pid: getpid(),
            windowId: 552,
            to: workspaceId
        )
        guard let firstHandle = controller.workspaceManager.handle(for: firstToken),
              controller.workspaceManager.handle(for: secondToken) != nil
        else {
            Issue.record("Missing handles for gesture diagnostic trace test")
            return
        }

        let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
        _ = engine.syncWindows(
            handles,
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: firstHandle
        )
        _ = controller.workspaceManager.setManagedFocus(firstHandle, in: workspaceId, onMonitor: monitor.id)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let handler = controller.mouseEventHandler
        let location = CGPoint(x: monitor.visibleFrame.midX, y: monitor.visibleFrame.midY)
        let baseTime = CACurrentMediaTime()

        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.began.rawValue,
                timestamp: baseTime,
                touches: makeGestureTouchSamples(xPositions: [0.20, 0.25, 0.30])
            )
        )
        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.016,
                touches: makeGestureTouchSamples(xPositions: [0.60, 0.65, 0.70])
            )
        )
        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.ended.rawValue,
                timestamp: baseTime + 0.032,
                touches: []
            )
        )

        let finalizedState = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(handler.state.gesturePhase == .idle)
        #expect(handler.state.lockedGestureContext == nil)
        #expect(finalizedState.viewOffsetPixels.isGesture == false)
        #expect(finalizedState.viewOffsetPixels.isAnimating)
    }

    @Test @MainActor func trackpadGestureWaitsForNiriRecognitionThreshold() async {
        let controller = makeMouseEventTestController()
        controller.settings.scrollGestureEnabled = true
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let workspaceId = controller.activeWorkspace()?.id,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for gesture recognition threshold test")
            return
        }

        let handler = controller.mouseEventHandler
        let location = CGPoint(x: monitor.visibleFrame.midX, y: monitor.visibleFrame.midY)
        let baselineState = controller.workspaceManager.niriViewportState(for: workspaceId)
        let baseTime = CACurrentMediaTime()

        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.began.rawValue,
                timestamp: baseTime,
                touches: makeGestureTouchSamples(xPositions: [0.50, 0.50, 0.50])
            )
        )
        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.016,
                touches: makeGestureTouchSamples(xPositions: [0.51, 0.51, 0.51])
            )
        )

        let updatedState = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(handler.state.gesturePhase == .armed)
        #expect(handler.state.lockedGestureContext?.workspaceId == workspaceId)
        #expect(updatedState.viewOffsetPixels.target() == baselineState.viewOffsetPixels.target())
        #expect(updatedState.viewOffsetPixels.isGesture == false)
    }

    @Test @MainActor func trackpadGestureCommitAppliesOnlyCurrentUpdateDelta() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let controller = fixture.controller
        controller.settings.gestureInvertDirection = false
        let handler = fixture.handler
        let baseTime = CACurrentMediaTime()

        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.began.rawValue,
                timestamp: baseTime,
                touches: makeGestureTouchSamples(xPositions: [0.20, 0.20, 0.20])
            )
        )
        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.016,
                touches: makeGestureTouchSamples(xPositions: [0.215, 0.215, 0.215])
            )
        )
        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.032,
                touches: makeGestureTouchSamples(xPositions: [0.235, 0.235, 0.235])
            )
        )

        let updatedState = controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        guard let monitor = controller.workspaceManager.monitor(for: fixture.workspaceId) else {
            Issue.record("Missing monitor for trackpad current-delta regression test")
            return
        }
        let viewportWidth = controller.insetWorkingFrame(for: monitor).width
        guard let gesture = updatedState.viewOffsetPixels.gestureRef else {
            Issue.record("Expected in-flight viewport gesture after crossing threshold")
            return
        }
        let expectedAppliedDelta = CGFloat((0.235 - 0.215) * 500.0) * viewportWidth / 1200.0
        let actualAppliedDelta = CGFloat(gesture.currentViewOffset - gesture.stationaryViewOffset)
        #expect(handler.state.gesturePhase == .committed)
        #expect(abs(actualAppliedDelta - expectedAppliedDelta) < 0.1)
    }

    @Test @MainActor func committedTrackpadGestureKeepsSubPixelDeltasForVelocity() async {
        let fixture = await prepareMouseWheelScrollFixture()
        let controller = fixture.controller
        controller.settings.gestureInvertDirection = false
        let handler = fixture.handler
        let baseTime = CACurrentMediaTime()

        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.began.rawValue,
                timestamp: baseTime,
                touches: makeGestureTouchSamples(xPositions: [0.20, 0.20, 0.20])
            )
        )
        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.016,
                touches: makeGestureTouchSamples(xPositions: [0.24, 0.24, 0.24])
            )
        )

        let beforeTinyDelta = controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        guard let beforeGesture = beforeTinyDelta.viewOffsetPixels.gestureRef else {
            Issue.record("Expected committed gesture before tiny delta")
            return
        }
        let beforeOffset = beforeGesture.currentViewOffset

        handler.receiveTapGestureEvent(
            .init(
                location: fixture.location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.032,
                touches: makeGestureTouchSamples(xPositions: [0.2404, 0.2404, 0.2404])
            )
        )

        let afterTinyDelta = controller.workspaceManager.niriViewportState(for: fixture.workspaceId)
        guard let afterGesture = afterTinyDelta.viewOffsetPixels.gestureRef else {
            Issue.record("Expected committed gesture after tiny delta")
            return
        }
        #expect(afterGesture.currentViewOffset > beforeOffset)
    }

    @Test @MainActor func verticalDominantThreeFingerGestureDoesNotScrollViewport() async {
        let controller = makeMouseEventTestController()
        controller.settings.scrollGestureEnabled = true
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let workspaceId = controller.activeWorkspace()?.id,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for vertical gesture rejection test")
            return
        }

        let handler = controller.mouseEventHandler
        let location = CGPoint(x: monitor.visibleFrame.midX, y: monitor.visibleFrame.midY)
        let baselineState = controller.workspaceManager.niriViewportState(for: workspaceId)
        let baseTime = CACurrentMediaTime()

        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.began.rawValue,
                timestamp: baseTime,
                touches: makeGestureTouchSamples(xPositions: [0.50, 0.50, 0.50])
            )
        )
        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.016,
                touches: makeGestureTouchSamples(
                    xPositions: [0.51, 0.51, 0.51],
                    yPosition: 0.62
                )
            )
        )

        let updatedState = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(handler.state.gesturePhase == .idle)
        #expect(handler.state.lockedGestureContext == nil)
        #expect(updatedState.viewOffsetPixels.target() == baselineState.viewOffsetPixels.target())
        #expect(updatedState.viewOffsetPixels.isGesture == false)
    }

    @Test @MainActor func committedTrackpadGestureFinalizesWhenFingerSetDropsDuringLift() async {
        let controller = makeMouseEventTestController()
        controller.settings.scrollGestureEnabled = true
        controller.settings.gestureInvertDirection = false
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let workspaceId = controller.activeWorkspace()?.id,
              let monitor = controller.workspaceManager.monitor(for: workspaceId),
              let engine = controller.niriEngine
        else {
            Issue.record("Missing Niri context for trackpad release regression test")
            return
        }

        let firstToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 561),
            pid: getpid(),
            windowId: 561,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 562),
            pid: getpid(),
            windowId: 562,
            to: workspaceId
        )
        _ = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 563),
            pid: getpid(),
            windowId: 563,
            to: workspaceId
        )
        guard let firstHandle = controller.workspaceManager.handle(for: firstToken) else {
            Issue.record("Missing first handle for trackpad release regression test")
            return
        }

        let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
        _ = engine.syncWindows(
            handles,
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: firstHandle
        )
        guard engine.findNode(for: secondToken) != nil else {
            Issue.record("Missing second node for trackpad release regression test")
            return
        }
        for column in engine.columns(in: workspaceId) {
            column.cachedWidth = 900
            column.cachedHeight = 800
        }
        _ = controller.workspaceManager.setManagedFocus(firstHandle, in: workspaceId, onMonitor: monitor.id)
        let focusedTokenBeforeGesture = controller.workspaceManager.focusedToken
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let handler = controller.mouseEventHandler
        let location = CGPoint(x: monitor.visibleFrame.midX, y: monitor.visibleFrame.midY)
        let baseTime = CACurrentMediaTime()

        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.began.rawValue,
                timestamp: baseTime,
                touches: makeGestureTouchSamples(xPositions: [0.20, 0.25, 0.30])
            )
        )
        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                timestamp: baseTime + 0.016,
                touches: makeGestureTouchSamples(xPositions: [0.60, 0.65, 0.70])
            )
        )

        let inFlightState = controller.workspaceManager.niriViewportState(for: workspaceId)
        guard let gesture = inFlightState.viewOffsetPixels.gestureRef else {
            Issue.record("Expected committed gesture before partial finger lift")
            return
        }
        let columns = engine.columns(in: workspaceId)
        let expectedActiveColumnIndex = columns.count - 1
        guard columns.indices.contains(expectedActiveColumnIndex),
              !columns[expectedActiveColumnIndex].windowNodes.isEmpty
        else {
            Issue.record("Expected a target Niri column for trackpad release regression test")
            return
        }
        let expectedSelectedNode = columns[expectedActiveColumnIndex].windowNodes[
            columns[expectedActiveColumnIndex].activeTileIdx.clamped(to: 0 ... (columns[expectedActiveColumnIndex].windowNodes.count - 1))
        ]
        _ = gesture

        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: 0,
                timestamp: baseTime + 0.032,
                touches: [
                    .init(phase: .touching, normalizedPosition: CGPoint(x: 0.62, y: 0.5)),
                    .init(phase: .ended, normalizedPosition: CGPoint(x: 0.65, y: 0.5)),
                    .init(phase: .ended, normalizedPosition: CGPoint(x: 0.70, y: 0.5)),
                ]
            )
        )

        let finalizedState = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(finalizedState.viewOffsetPixels.isGesture == false)
        #expect(finalizedState.viewOffsetPixels.isAnimating == true)
        #expect(finalizedState.activeColumnIndex == expectedActiveColumnIndex)
        #expect(finalizedState.selectedNodeId == expectedSelectedNode.id)
        #expect(controller.workspaceManager.lastFocusedToken(in: workspaceId) == expectedSelectedNode.token)
        #expect(controller.workspaceManager.focusedToken == focusedTokenBeforeGesture)
        #expect(handler.state.gesturePhase == .idle)
        #expect(handler.state.lockedGestureContext == nil)
    }

    @Test @MainActor func committedTrackpadGestureFinalizesWhenContextBecomesUnsupported() async {
        let controller = makeMouseEventTestController(
            workspaceConfigurations: [
                WorkspaceConfiguration(name: "1", monitorAssignment: .main, layoutType: .niri),
                WorkspaceConfiguration(name: "2", monitorAssignment: .main, layoutType: .dwindle),
            ]
        )
        controller.settings.scrollGestureEnabled = true
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        controller.enableDwindleLayout()
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()

        guard let firstWorkspace = controller.activeWorkspace(),
              let monitor = controller.workspaceManager.monitor(for: firstWorkspace.id),
              let engine = controller.niriEngine
        else {
            Issue.record("Missing initial workspace for gesture cleanup regression test")
            return
        }

        let handler = controller.mouseEventHandler
        let location = CGPoint(x: monitor.visibleFrame.midX, y: monitor.visibleFrame.midY)
        populateNiriWorkspaceForMouseTests(
            controller: controller,
            engine: engine,
            workspaceId: firstWorkspace.id,
            monitor: monitor,
            startingWindowId: 570
        )
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        controller.workspaceManager.withNiriViewportState(for: firstWorkspace.id) { state in
            state.viewOffsetPixels = .static(-84)
            state.selectionProgress = 9
            state.viewOffsetToRestore = 123
            state.activatePrevColumnOnRemoval = 456
        }

        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.began.rawValue,
                touches: makeGestureTouchSamples(xPositions: [0.20, 0.25, 0.30])
            )
        )
        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                touches: makeGestureTouchSamples(xPositions: [0.70, 0.75, 0.80])
            )
        )

        let inFlightViewportState = controller.workspaceManager.niriViewportState(for: firstWorkspace.id)
        guard inFlightViewportState.viewOffsetPixels.gestureRef != nil else {
            Issue.record("Expected committed gesture state before switching to unsupported context")
            return
        }

        #expect(handler.state.gesturePhase == .committed)
        #expect(handler.state.lockedGestureContext?.workspaceId == firstWorkspace.id)

        guard let switchedWorkspace = controller.workspaceManager.focusWorkspace(named: "2") else {
            Issue.record("Failed to switch to Dwindle workspace for gesture cleanup regression test")
            return
        }
        #expect(switchedWorkspace.workspace.name == "2")
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        var relayoutReasons: [RefreshReason] = []
        controller.layoutRefreshController.resetDebugState()
        controller.layoutRefreshController.debugHooks.onRelayout = { reason, _ in
            relayoutReasons.append(reason)
            return true
        }

        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                touches: makeGestureTouchSamples(xPositions: [0.75, 0.80, 0.85])
            )
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let finalizedViewportState = controller.workspaceManager.niriViewportState(for: firstWorkspace.id)
        #expect(finalizedViewportState.viewOffsetPixels.isGesture == false)
        #expect(finalizedViewportState.viewOffsetPixels.isAnimating)
        #expect(finalizedViewportState.selectionProgress == 0)
        #expect(finalizedViewportState.viewOffsetToRestore == 123)
        #expect(finalizedViewportState.activatePrevColumnOnRemoval == nil)
        #expect(handler.state.gesturePhase == .idle)
        #expect(handler.state.lockedGestureContext == nil)
        #expect(relayoutReasons.isEmpty)
    }

    @Test @MainActor func committedTrackpadGestureResetsWhenControllerIsDisabled() async {
        let (controller, handler, workspaceId, location) = await prepareCommittedTrackpadGestureFixture()
        #expect(handler.state.gesturePhase == .committed)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).viewOffsetPixels.isGesture)

        controller.isEnabled = false
        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                touches: makeGestureTouchSamples(xPositions: [0.70, 0.75, 0.80])
            )
        )

        let finalizedState = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(handler.state.gesturePhase == .idle)
        #expect(handler.state.lockedGestureContext == nil)
        #expect(finalizedState.viewOffsetPixels.isGesture == false)
        #expect(finalizedState.viewOffsetPixels.isAnimating)
    }

    @Test @MainActor func committedTrackpadGestureResetsWhenScrollGesturesAreDisabled() async {
        let (controller, handler, workspaceId, location) = await prepareCommittedTrackpadGestureFixture()
        #expect(handler.state.gesturePhase == .committed)
        #expect(controller.workspaceManager.niriViewportState(for: workspaceId).viewOffsetPixels.isGesture)

        controller.settings.scrollGestureEnabled = false
        handler.receiveTapGestureEvent(
            .init(
                location: location,
                phaseRawValue: NSEvent.Phase.changed.rawValue,
                touches: makeGestureTouchSamples(xPositions: [0.70, 0.75, 0.80])
            )
        )

        let finalizedState = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(handler.state.gesturePhase == .idle)
        #expect(handler.state.lockedGestureContext == nil)
        #expect(finalizedState.viewOffsetPixels.isGesture == false)
        #expect(finalizedState.viewOffsetPixels.isAnimating)
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

    @Test @MainActor func scrollBurstFlushesBeforeDirectionChanges() {
        let controller = makeMouseEventTestController()
        let handler = controller.mouseEventHandler

        handler.resetDebugStateForTests()
        handler.receiveTapScrollWheel(
            at: CGPoint(x: 10, y: 10),
            deltaX: 60,
            deltaY: 0,
            momentumPhase: 0,
            phase: 0,
            modifiers: [.maskAlternate, .maskShift]
        )
        handler.receiveTapScrollWheel(
            at: CGPoint(x: 10, y: 10),
            deltaX: -60,
            deltaY: 0,
            momentumPhase: 0,
            phase: 0,
            modifiers: [.maskAlternate, .maskShift]
        )
        handler.flushPendingTapEventsForTests()

        let debugSnapshot = handler.mouseTapDebugSnapshot()
        #expect(debugSnapshot.queuedTransientEvents == 2)
        #expect(debugSnapshot.coalescedTransientEvents == 0)
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

    @Test @MainActor func focusFollowsMouseActivatesVisibleNiriWindowWithoutRecenteringViewport() async {
        let controller = makeMouseEventTestController()
        controller.enableNiriLayout(maxWindowsPerColumn: 1)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()
        controller.syncMonitorsToNiriEngine()
        controller.setFocusFollowsMouse(true)

        guard let workspaceId = controller.activeWorkspace()?.id,
              let engine = controller.niriEngine,
              let monitor = controller.workspaceManager.monitor(for: workspaceId)
        else {
            Issue.record("Missing Niri context for hover focus-follow viewport regression test")
            return
        }

        let firstToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 931),
            pid: getpid(),
            windowId: 931,
            to: workspaceId
        )
        let secondToken = controller.workspaceManager.addWindow(
            makeMouseEventTestWindow(windowId: 932),
            pid: getpid(),
            windowId: 932,
            to: workspaceId
        )
        guard let firstHandle = controller.workspaceManager.handle(for: firstToken),
              let secondHandle = controller.workspaceManager.handle(for: secondToken)
        else {
            Issue.record("Missing handles for Niri hover focus-follow viewport regression test")
            return
        }

        let handles = controller.workspaceManager.entries(in: workspaceId).map(\.handle)
        _ = engine.syncWindows(
            handles,
            in: workspaceId,
            selectedNodeId: nil,
            focusedHandle: firstHandle
        )
        _ = controller.workspaceManager.setManagedFocus(firstHandle, in: workspaceId, onMonitor: monitor.id)
        controller.layoutRefreshController.requestImmediateRelayout(reason: .workspaceTransition)
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        guard let secondNode = engine.findNode(for: secondHandle),
              let hoveredFrame = secondNode.frame
        else {
            Issue.record("Missing second node frame for Niri hover focus-follow viewport regression test")
            return
        }

        let initialState = controller.workspaceManager.niriViewportState(for: workspaceId)

        controller.mouseEventHandler.dispatchMouseMoved(
            at: CGPoint(x: hoveredFrame.midX, y: hoveredFrame.midY)
        )
        await controller.layoutRefreshController.waitForRefreshWorkForTests()

        let updatedState = controller.workspaceManager.niriViewportState(for: workspaceId)
        #expect(controller.workspaceManager.focusedHandle == firstHandle)
        #expect(controller.workspaceManager.pendingFocusedHandle == secondHandle)
        #expect(updatedState.selectedNodeId == secondNode.id)
        #expect(updatedState.activeColumnIndex == initialState.activeColumnIndex)
        #expect(updatedState.viewOffsetPixels.target() == initialState.viewOffsetPixels.target())
        #expect(controller.niriLayoutHandler.scrollAnimationByDisplay[monitor.displayId] == nil)
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
