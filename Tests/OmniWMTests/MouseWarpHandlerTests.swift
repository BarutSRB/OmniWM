import CoreGraphics
import Foundation
@testable import OmniWM
import Testing

private final class WarpEffectRecorder: @unchecked Sendable {
    var warpedPoints: [CGPoint] = []
    var postedPoints: [CGPoint] = []
}

private func makeMouseWarpTestDefaults() -> UserDefaults {
    let suiteName = "com.omniwm.mouse-warp.test.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func makeMouseWarpTestMonitor(
    displayId: CGDirectDisplayID,
    name: String,
    x: CGFloat,
    y: CGFloat = 0,
    width: CGFloat = 1920,
    height: CGFloat = 1080
) -> Monitor {
    let frame = CGRect(x: x, y: y, width: width, height: height)
    return Monitor(
        id: Monitor.ID(displayId: displayId),
        displayId: displayId,
        frame: frame,
        visibleFrame: frame,
        hasNotch: false,
        name: name
    )
}

@MainActor
private func makeConfiguredMouseWarpTestFixture(
    monitors: [Monitor],
    monitorOrder: [String],
    axis: MouseWarpAxis
) -> (
    controller: WMController,
    handler: MouseWarpHandler,
    recorder: WarpEffectRecorder
) {
    let settings = SettingsStore(defaults: makeMouseWarpTestDefaults())
    settings.mouseWarpMonitorOrder = monitorOrder
    settings.mouseWarpAxis = axis
    settings.mouseWarpMargin = 2

    let operations = WindowFocusOperations(
        activateApp: { _ in },
        focusSpecificWindow: { _, _, _ in },
        raiseWindow: { _ in }
    )

    let controller = WMController(
        settings: settings,
        windowFocusOperations: operations
    )
    controller.lockScreenObserver.frontmostApplicationProvider = { nil }
    controller.workspaceManager.applyMonitorConfigurationChange(monitors)

    let recorder = WarpEffectRecorder()
    let handler = controller.mouseWarpHandler
    handler.warpCursor = { point in recorder.warpedPoints.append(point) }
    handler.postMouseMovedEvent = { point in recorder.postedPoints.append(point) }
    return (controller, handler, recorder)
}

@MainActor
private func makeMouseWarpTestFixture() -> (
    controller: WMController,
    handler: MouseWarpHandler,
    leftMonitor: Monitor,
    rightMonitor: Monitor,
    recorder: WarpEffectRecorder
) {
    let leftMonitor = makeMouseWarpTestMonitor(displayId: 1, name: "Left", x: 0)
    let rightMonitor = makeMouseWarpTestMonitor(displayId: 2, name: "Right", x: 1920)
    let fixture = makeConfiguredMouseWarpTestFixture(
        monitors: [leftMonitor, rightMonitor],
        monitorOrder: ["Left", "Right"],
        axis: .horizontal
    )
    return (fixture.controller, fixture.handler, leftMonitor, rightMonitor, fixture.recorder)
}

@MainActor
private func makeVerticalMouseWarpTestFixture() -> (
    controller: WMController,
    handler: MouseWarpHandler,
    topMonitor: Monitor,
    bottomMonitor: Monitor,
    recorder: WarpEffectRecorder
) {
    let bottomMonitor = makeMouseWarpTestMonitor(displayId: 1, name: "Bottom", x: 0, y: 0, width: 1728)
    let topMonitor = makeMouseWarpTestMonitor(displayId: 2, name: "Top", x: 320, y: 1080, width: 2560)
    let fixture = makeConfiguredMouseWarpTestFixture(
        monitors: [bottomMonitor, topMonitor],
        monitorOrder: ["Top", "Bottom"],
        axis: .vertical
    )
    return (fixture.controller, fixture.handler, topMonitor, bottomMonitor, fixture.recorder)
}

@MainActor
private func makeVerticalAxisSideBySideMouseWarpTestFixture() -> (
    controller: WMController,
    handler: MouseWarpHandler,
    leftMonitor: Monitor,
    rightMonitor: Monitor,
    recorder: WarpEffectRecorder
) {
    let leftMonitor = makeMouseWarpTestMonitor(
        displayId: 1,
        name: "Left",
        x: 0,
        y: 0,
        width: 1440,
        height: 900
    )
    let rightMonitor = makeMouseWarpTestMonitor(
        displayId: 2,
        name: "Right",
        x: 1440,
        y: 0,
        width: 1440,
        height: 900
    )
    let fixture = makeConfiguredMouseWarpTestFixture(
        monitors: [leftMonitor, rightMonitor],
        monitorOrder: ["Left", "Right"],
        axis: .vertical
    )
    return (fixture.controller, fixture.handler, leftMonitor, rightMonitor, fixture.recorder)
}

@MainActor
private func makeHorizontalAxisStackedMouseWarpTestFixture() -> (
    controller: WMController,
    handler: MouseWarpHandler,
    topMonitor: Monitor,
    bottomMonitor: Monitor,
    recorder: WarpEffectRecorder
) {
    let bottomMonitor = makeMouseWarpTestMonitor(
        displayId: 1,
        name: "Bottom",
        x: 0,
        y: 0,
        width: 1440,
        height: 900
    )
    let topMonitor = makeMouseWarpTestMonitor(
        displayId: 2,
        name: "Top",
        x: 0,
        y: 900,
        width: 1440,
        height: 900
    )
    let fixture = makeConfiguredMouseWarpTestFixture(
        monitors: [bottomMonitor, topMonitor],
        monitorOrder: ["Top", "Bottom"],
        axis: .horizontal
    )
    return (fixture.controller, fixture.handler, topMonitor, bottomMonitor, fixture.recorder)
}

@MainActor
private func waitForMainRunLoopTurn() async {
    await withCheckedContinuation { continuation in
        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) {
            continuation.resume()
        }
        CFRunLoopWakeUp(mainRunLoop)
    }
}

@MainActor
private func waitUntilMouseWarpDrain(
    handler: MouseWarpHandler,
    iterations: Int = 100,
    condition: () -> Bool
) async {
    for _ in 0 ..< iterations where !condition() {
        await waitForMainRunLoopTurn()
    }

    if !condition() {
        let snapshot = handler.mouseWarpDebugSnapshot()
        Issue.record("Timed out waiting for scheduled mouse warp drain: \(snapshot)")
    }
}

private func expectWarpAndPost(_ recorder: WarpEffectRecorder, _ expectedPoint: CGPoint) {
    #expect(recorder.warpedPoints == [expectedPoint])
    #expect(recorder.postedPoints == [expectedPoint])
}

@Suite struct MouseWarpHandlerTests {
    @Test @MainActor func queuedWarpMovesCollapseToLatestLocation() {
        let fixture = makeMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        let firstLocation = CGPoint(x: fixture.leftMonitor.frame.midX, y: fixture.leftMonitor.frame.midY)
        let secondLocation = CGPoint(
            x: fixture.leftMonitor.frame.maxX - CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: fixture.leftMonitor.frame.midY
        )

        fixture.handler.resetDebugStateForTests()
        fixture.handler.receiveTapMouseWarpMoved(at: firstLocation)
        fixture.handler.receiveTapMouseWarpMoved(at: secondLocation)
        fixture.handler.flushPendingWarpEventsForTests()

        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: fixture.rightMonitor.frame.minX + CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: fixture.rightMonitor.frame.midY
        ))
        let snapshot = fixture.handler.mouseWarpDebugSnapshot()

        #expect(snapshot.queuedTransientEvents == 2)
        #expect(snapshot.coalescedTransientEvents == 1)
        #expect(snapshot.drainedTransientEvents == 1)
        #expect(snapshot.drainRuns == 1)
        #expect(fixture.handler.state.lastMonitorId == fixture.rightMonitor.id)
        #expect(fixture.controller.workspaceManager.interactionMonitorId == fixture.rightMonitor.id)
        expectWarpAndPost(fixture.recorder, expectedPoint)
    }

    @Test @MainActor func scheduledDrainProcessesOneBurstWithoutManualFlush() async {
        let fixture = makeMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        let location = CGPoint(
            x: fixture.leftMonitor.frame.maxX - CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: fixture.leftMonitor.frame.midY
        )

        fixture.handler.resetDebugStateForTests()
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.receiveTapMouseWarpMoved(at: location)

        await waitUntilMouseWarpDrain(handler: fixture.handler) {
            fixture.handler.mouseWarpDebugSnapshot().drainedTransientEvents == 1
        }

        let snapshot = fixture.handler.mouseWarpDebugSnapshot()
        #expect(snapshot.queuedTransientEvents == 2)
        #expect(snapshot.coalescedTransientEvents == 1)
        #expect(snapshot.drainedTransientEvents == 1)
        #expect(snapshot.drainRuns == 1)
        #expect(fixture.recorder.warpedPoints.count == 1)
        #expect(fixture.recorder.postedPoints.count == 1)
    }

    @Test @MainActor func latestDrainedLocationWarpsToCorrectNeighborMonitorAtEdge() {
        let fixture = makeMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        let location = CGPoint(
            x: fixture.leftMonitor.frame.maxX - CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: fixture.leftMonitor.frame.minY + 270
        )

        fixture.handler.resetDebugStateForTests()
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        let yRatio = (fixture.leftMonitor.frame.maxY - location.y) / fixture.leftMonitor.frame.height
        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: fixture.rightMonitor.frame.minX + CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: fixture.rightMonitor.frame.maxY - (yRatio * fixture.rightMonitor.frame.height)
        ))

        #expect(fixture.handler.state.lastMonitorId == fixture.rightMonitor.id)
        expectWarpAndPost(fixture.recorder, expectedPoint)
    }

    @Test @MainActor func exactMaxEdgeCrossingWarpsFromLastMonitor() {
        let fixture = makeMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        fixture.handler.resetDebugStateForTests()
        fixture.handler.state.lastMonitorId = fixture.leftMonitor.id

        let location = CGPoint(
            x: fixture.leftMonitor.frame.maxX,
            y: fixture.leftMonitor.frame.midY
        )
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: fixture.rightMonitor.frame.minX + CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: fixture.rightMonitor.frame.midY
        ))

        #expect(fixture.handler.state.lastMonitorId == fixture.rightMonitor.id)
        expectWarpAndPost(fixture.recorder, expectedPoint)
    }

    @Test @MainActor func horizontalModeWarpsFromRightMonitorToLeftMonitorAtLeftBoundary() {
        let fixture = makeMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        let location = CGPoint(
            x: fixture.rightMonitor.frame.minX + CGFloat(fixture.controller.settings.mouseWarpMargin) - 1,
            y: fixture.rightMonitor.frame.midY
        )

        fixture.handler.resetDebugStateForTests()
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: fixture.leftMonitor.frame.maxX - CGFloat(fixture.controller.settings.mouseWarpMargin) - 1,
            y: fixture.leftMonitor.frame.midY
        ))

        #expect(fixture.handler.state.lastMonitorId == fixture.leftMonitor.id)
        #expect(fixture.controller.workspaceManager.interactionMonitorId == fixture.leftMonitor.id)
        expectWarpAndPost(fixture.recorder, expectedPoint)
    }

    @Test @MainActor func offMainThreadWarpTapCallbackFailsOpenWithoutQueueingState() {
        let fixture = makeMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 80, y: 90),
            mouseButton: .left
        ) else {
            Issue.record("Failed to create CGEvent")
            return
        }

        let processed = fixture.handler.handleTapCallbackForTests(
            event: event,
            isMainThread: false
        )

        #expect(processed == false)
        #expect(fixture.handler.mouseWarpDebugSnapshot() == .init())
        #expect(fixture.handler.state.pendingWarpEvents.hasPendingEvents == false)
        #expect(fixture.recorder.postedPoints.isEmpty)
    }

    @Test @MainActor func policySeedsDefaultOrderBeforeWarpingFreshMultiMonitorSetup() {
        let fixture = makeMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        fixture.controller.settings.mouseWarpMonitorOrder = []
        _ = fixture.controller.syncMouseWarpPolicy(for: [fixture.leftMonitor, fixture.rightMonitor])

        let location = CGPoint(
            x: fixture.leftMonitor.frame.maxX - CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: fixture.leftMonitor.frame.midY
        )

        fixture.handler.resetDebugStateForTests()
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: fixture.rightMonitor.frame.minX + CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: fixture.rightMonitor.frame.midY
        ))

        #expect(fixture.controller.settings.mouseWarpMonitorOrder == ["Left", "Right"])
        expectWarpAndPost(fixture.recorder, expectedPoint)
    }

    @Test @MainActor func isWarpingSuppressesDrainedHandlerPath() {
        let fixture = makeMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        let location = CGPoint(
            x: fixture.leftMonitor.frame.maxX - CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: fixture.leftMonitor.frame.midY
        )

        fixture.handler.resetDebugStateForTests()
        fixture.handler.state.isWarping = true
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        let snapshot = fixture.handler.mouseWarpDebugSnapshot()
        #expect(snapshot.queuedTransientEvents == 1)
        #expect(snapshot.coalescedTransientEvents == 0)
        #expect(snapshot.drainedTransientEvents == 1)
        #expect(snapshot.drainRuns == 1)
        #expect(fixture.handler.state.lastMonitorId == nil)
        #expect(fixture.recorder.warpedPoints.isEmpty)
        #expect(fixture.recorder.postedPoints.isEmpty)
    }

    @Test @MainActor func verticalModeWarpsFromBottomMonitorToTopMonitorUsingTopBoundaryAndXRatio() {
        let fixture = makeVerticalMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        let location = CGPoint(
            x: fixture.bottomMonitor.frame.minX + 432,
            y: fixture.bottomMonitor.frame.maxY - CGFloat(fixture.controller.settings.mouseWarpMargin) + 1
        )

        fixture.handler.resetDebugStateForTests()
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        let xRatio = (location.x - fixture.bottomMonitor.frame.minX) / fixture.bottomMonitor.frame.width
        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: fixture.topMonitor.frame.minX + (xRatio * fixture.topMonitor.frame.width),
            y: fixture.topMonitor.frame.minY + CGFloat(fixture.controller.settings.mouseWarpMargin) + 1
        ))

        #expect(fixture.handler.state.lastMonitorId == fixture.topMonitor.id)
        expectWarpAndPost(fixture.recorder, expectedPoint)
    }

    @Test @MainActor func verticalModeWarpsFromTopMonitorToBottomMonitorUsingBottomBoundaryAndXRatio() {
        let fixture = makeVerticalMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        let location = CGPoint(
            x: fixture.topMonitor.frame.minX + 1280,
            y: fixture.topMonitor.frame.minY + CGFloat(fixture.controller.settings.mouseWarpMargin) - 1
        )

        fixture.handler.resetDebugStateForTests()
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        let xRatio = (location.x - fixture.topMonitor.frame.minX) / fixture.topMonitor.frame.width
        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: fixture.bottomMonitor.frame.minX + (xRatio * fixture.bottomMonitor.frame.width),
            y: fixture.bottomMonitor.frame.maxY - CGFloat(fixture.controller.settings.mouseWarpMargin) - 1
        ))

        #expect(fixture.handler.state.lastMonitorId == fixture.bottomMonitor.id)
        expectWarpAndPost(fixture.recorder, expectedPoint)
    }

    @Test @MainActor func verticalModeUsesLastValidMonitorForFarLeftTopEdgeOutsideAllMonitors() {
        let fixture = makeVerticalMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        fixture.handler.resetDebugStateForTests()
        fixture.handler.state.lastMonitorId = fixture.bottomMonitor.id

        let location = CGPoint(
            x: fixture.bottomMonitor.frame.minX - 24,
            y: fixture.bottomMonitor.frame.maxY + 5
        )

        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: fixture.topMonitor.frame.minX,
            y: fixture.topMonitor.frame.minY + CGFloat(fixture.controller.settings.mouseWarpMargin) + 1
        ))

        #expect(fixture.handler.state.lastMonitorId == fixture.topMonitor.id)
        expectWarpAndPost(fixture.recorder, expectedPoint)
    }

    @Test @MainActor func verticalModeUsesLastValidMonitorWhenLatestLocationAlreadyEnteredNextMonitor() {
        let fixture = makeVerticalMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        fixture.handler.resetDebugStateForTests()
        fixture.handler.state.lastMonitorId = fixture.bottomMonitor.id

        let location = CGPoint(
            x: fixture.bottomMonitor.frame.maxX - 8,
            y: fixture.topMonitor.frame.minY + 12
        )

        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        let xRatio = (location.x - fixture.bottomMonitor.frame.minX) / fixture.bottomMonitor.frame.width
        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: fixture.topMonitor.frame.minX + (min(max(xRatio, 0), 1) * fixture.topMonitor.frame.width),
            y: fixture.topMonitor.frame.minY + CGFloat(fixture.controller.settings.mouseWarpMargin) + 1
        ))

        #expect(fixture.handler.state.lastMonitorId == fixture.topMonitor.id)
        expectWarpAndPost(fixture.recorder, expectedPoint)
    }

    @Test @MainActor func verticalWarpClampsMappedCoordinateInsideTargetFrame() {
        let fixture = makeVerticalMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        fixture.handler.resetDebugStateForTests()
        fixture.handler.state.lastMonitorId = fixture.bottomMonitor.id

        let location = CGPoint(
            x: fixture.bottomMonitor.frame.maxX + 20,
            y: fixture.bottomMonitor.frame.maxY + 5
        )

        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: fixture.topMonitor.frame.maxX.nextDown,
            y: fixture.topMonitor.frame.minY + CGFloat(fixture.controller.settings.mouseWarpMargin) + 1
        ))

        #expect(fixture.handler.state.lastMonitorId == fixture.topMonitor.id)
        #expect(fixture.controller.workspaceManager.interactionMonitorId == fixture.topMonitor.id)
        expectWarpAndPost(fixture.recorder, expectedPoint)
    }

    @Test @MainActor func horizontalWarpClampsMappedCoordinateToTopEdgeInsideTargetFrame() {
        let fixture = makeMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        fixture.handler.resetDebugStateForTests()
        fixture.handler.state.lastMonitorId = fixture.leftMonitor.id

        let location = CGPoint(
            x: fixture.leftMonitor.frame.maxX + CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: fixture.leftMonitor.frame.maxY + 20
        )

        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: fixture.rightMonitor.frame.minX + CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: fixture.rightMonitor.frame.maxY.nextDown
        ))

        #expect(fixture.handler.state.lastMonitorId == fixture.rightMonitor.id)
        #expect(fixture.controller.workspaceManager.interactionMonitorId == fixture.rightMonitor.id)
        expectWarpAndPost(fixture.recorder, expectedPoint)
    }

    @Test @MainActor func horizontalWarpClampsMappedCoordinateToBottomEdgeInsideTargetFrame() {
        let fixture = makeMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        fixture.handler.resetDebugStateForTests()
        fixture.handler.state.lastMonitorId = fixture.leftMonitor.id

        let location = CGPoint(
            x: fixture.leftMonitor.frame.maxX + CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: fixture.leftMonitor.frame.minY - 20
        )

        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: fixture.rightMonitor.frame.minX + CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: fixture.rightMonitor.frame.minY
        ))

        #expect(fixture.handler.state.lastMonitorId == fixture.rightMonitor.id)
        #expect(fixture.controller.workspaceManager.interactionMonitorId == fixture.rightMonitor.id)
        expectWarpAndPost(fixture.recorder, expectedPoint)
    }

    @Test @MainActor func verticalLastMonitorWarpStillRunsWhenOnlyPerpendicularCoordinateEscapes() {
        let fixture = makeVerticalMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        fixture.handler.resetDebugStateForTests()
        fixture.handler.state.lastMonitorId = fixture.bottomMonitor.id

        let location = CGPoint(
            x: fixture.bottomMonitor.frame.minX - 24,
            y: fixture.bottomMonitor.frame.maxY - CGFloat(fixture.controller.settings.mouseWarpMargin) + 1
        )

        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: fixture.topMonitor.frame.minX,
            y: fixture.topMonitor.frame.minY + CGFloat(fixture.controller.settings.mouseWarpMargin) + 1
        ))

        #expect(fixture.handler.state.lastMonitorId == fixture.topMonitor.id)
        #expect(fixture.controller.workspaceManager.interactionMonitorId == fixture.topMonitor.id)
        expectWarpAndPost(fixture.recorder, expectedPoint)
    }

    @Test @MainActor func verticalModeDoesNotClampWhenNoWarpTargetExists() {
        let fixture = makeVerticalMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        fixture.handler.resetDebugStateForTests()
        fixture.handler.state.lastMonitorId = fixture.topMonitor.id

        let location = CGPoint(
            x: fixture.topMonitor.frame.minX - 36,
            y: fixture.topMonitor.frame.maxY + 10
        )

        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        #expect(fixture.handler.state.lastMonitorId == fixture.topMonitor.id)
        #expect(fixture.handler.state.isWarping == false)
        #expect(fixture.recorder.postedPoints.isEmpty)
        #expect(fixture.recorder.warpedPoints.isEmpty)
    }

    @Test @MainActor func verticalAxisAllowsHorizontalMovementIntoSideBySideMonitor() {
        let fixture = makeVerticalAxisSideBySideMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        fixture.handler.resetDebugStateForTests()
        fixture.handler.state.lastMonitorId = fixture.leftMonitor.id

        let location = CGPoint(x: fixture.rightMonitor.frame.midX, y: fixture.rightMonitor.frame.midY)
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        #expect(fixture.handler.state.lastMonitorId == fixture.rightMonitor.id)
        #expect(fixture.handler.state.isWarping == false)
        #expect(fixture.recorder.warpedPoints.isEmpty)
        #expect(fixture.recorder.postedPoints.isEmpty)
    }

    @Test @MainActor func verticalAxisAllowsHorizontalMovementNearWarpEdgeIntoSideBySideMonitor() {
        let fixture = makeVerticalAxisSideBySideMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        fixture.handler.resetDebugStateForTests()
        fixture.handler.state.lastMonitorId = fixture.rightMonitor.id

        let location = CGPoint(
            x: fixture.leftMonitor.frame.midX,
            y: fixture.leftMonitor.frame.maxY - CGFloat(fixture.controller.settings.mouseWarpMargin) + 1
        )
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        #expect(fixture.handler.state.lastMonitorId == fixture.leftMonitor.id)
        #expect(fixture.handler.state.isWarping == false)
        #expect(fixture.recorder.warpedPoints.isEmpty)
        #expect(fixture.recorder.postedPoints.isEmpty)
    }

    @Test @MainActor func horizontalAxisAllowsVerticalMovementIntoStackedMonitor() {
        let fixture = makeHorizontalAxisStackedMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        fixture.handler.resetDebugStateForTests()
        fixture.handler.state.lastMonitorId = fixture.bottomMonitor.id

        let location = CGPoint(x: fixture.topMonitor.frame.midX, y: fixture.topMonitor.frame.midY)
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        #expect(fixture.handler.state.lastMonitorId == fixture.topMonitor.id)
        #expect(fixture.handler.state.isWarping == false)
        #expect(fixture.recorder.warpedPoints.isEmpty)
        #expect(fixture.recorder.postedPoints.isEmpty)
    }

    @Test @MainActor func cursorOutsideAllMonitorsWithoutValidAxisWarpDoesNotClampToNearestMonitor() {
        let fixture = makeVerticalAxisSideBySideMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        let location = CGPoint(x: fixture.rightMonitor.frame.midX, y: fixture.rightMonitor.frame.maxY + 20)
        fixture.handler.resetDebugStateForTests()
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        #expect(fixture.handler.state.lastMonitorId == nil)
        #expect(fixture.handler.state.isWarping == false)
        #expect(fixture.recorder.warpedPoints.isEmpty)
        #expect(fixture.recorder.postedPoints.isEmpty)
    }

    @Test @MainActor func horizontalCursorOutsideAllMonitorsWithoutLastMonitorDoesNotClampToNearestMonitor() {
        let fixture = makeHorizontalAxisStackedMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        let location = CGPoint(x: fixture.topMonitor.frame.midX, y: fixture.topMonitor.frame.maxY + 20)
        fixture.handler.resetDebugStateForTests()
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        #expect(fixture.handler.state.lastMonitorId == nil)
        #expect(fixture.handler.state.isWarping == false)
        #expect(fixture.recorder.warpedPoints.isEmpty)
        #expect(fixture.recorder.postedPoints.isEmpty)
    }

    @Test @MainActor func horizontalModeDoesNotClampWhenNoWarpTargetExists() {
        let fixture = makeMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        fixture.handler.resetDebugStateForTests()
        fixture.handler.state.lastMonitorId = fixture.leftMonitor.id

        let location = CGPoint(
            x: fixture.leftMonitor.frame.minX - 20,
            y: fixture.leftMonitor.frame.midY
        )
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        #expect(fixture.handler.state.lastMonitorId == fixture.leftMonitor.id)
        #expect(fixture.handler.state.isWarping == false)
        #expect(fixture.recorder.warpedPoints.isEmpty)
        #expect(fixture.recorder.postedPoints.isEmpty)
    }

    @Test @MainActor func horizontalModeUsesLastValidMonitorForRightEdgeOutsideAllMonitors() {
        let leftMonitor = makeMouseWarpTestMonitor(
            displayId: 1,
            name: "Left",
            x: 0,
            y: 0,
            width: 1000,
            height: 900
        )
        let rightMonitor = makeMouseWarpTestMonitor(
            displayId: 2,
            name: "Right",
            x: 1200,
            y: 0,
            width: 1000,
            height: 900
        )
        let fixture = makeConfiguredMouseWarpTestFixture(
            monitors: [leftMonitor, rightMonitor],
            monitorOrder: ["Left", "Right"],
            axis: .horizontal
        )
        defer { fixture.handler.cleanup() }

        fixture.handler.resetDebugStateForTests()
        fixture.handler.state.lastMonitorId = leftMonitor.id

        let location = CGPoint(
            x: leftMonitor.frame.maxX + CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: leftMonitor.frame.midY
        )
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: rightMonitor.frame.minX + CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: rightMonitor.frame.midY
        ))

        #expect(fixture.handler.state.lastMonitorId == rightMonitor.id)
        expectWarpAndPost(fixture.recorder, expectedPoint)
    }

    @Test @MainActor func cleanupClearsPendingWarpStateBeforeScheduledDrain() async {
        let fixture = makeMouseWarpTestFixture()

        let location = CGPoint(
            x: fixture.leftMonitor.frame.maxX - CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: fixture.leftMonitor.frame.midY
        )

        fixture.handler.resetDebugStateForTests()
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.cleanup()
        await waitForMainRunLoopTurn()

        let snapshot = fixture.handler.mouseWarpDebugSnapshot()
        #expect(snapshot.queuedTransientEvents == 0)
        #expect(snapshot.coalescedTransientEvents == 0)
        #expect(snapshot.drainedTransientEvents == 0)
        #expect(snapshot.drainRuns == 0)
        #expect(fixture.handler.state.pendingWarpEvents.pendingLocation == nil)
        #expect(fixture.handler.state.pendingWarpEvents.drainScheduled == false)
        #expect(fixture.handler.state.lastMonitorId == nil)
        #expect(fixture.handler.state.isWarping == false)
        #expect(fixture.recorder.warpedPoints.isEmpty)
        #expect(fixture.recorder.postedPoints.isEmpty)
    }
}
