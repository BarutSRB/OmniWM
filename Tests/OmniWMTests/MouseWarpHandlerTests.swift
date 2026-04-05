import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

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
private func makeMouseWarpTestFixture() -> (
    controller: WMController,
    handler: MouseWarpHandler,
    leftMonitor: Monitor,
    rightMonitor: Monitor,
    recorder: WarpEffectRecorder
) {
    let settings = SettingsStore(defaults: makeMouseWarpTestDefaults())
    settings.mouseWarpMonitorOrder = ["Left", "Right"]
    settings.mouseWarpAxis = .horizontal
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
    let leftMonitor = makeMouseWarpTestMonitor(displayId: 1, name: "Left", x: 0)
    let rightMonitor = makeMouseWarpTestMonitor(displayId: 2, name: "Right", x: 1920)
    controller.workspaceManager.applyMonitorConfigurationChange([leftMonitor, rightMonitor])

    let recorder = WarpEffectRecorder()
    let handler = controller.mouseWarpHandler
    handler.warpCursor = { point in recorder.warpedPoints.append(point) }
    handler.postMouseMovedEvent = { point in recorder.postedPoints.append(point) }
    return (controller, handler, leftMonitor, rightMonitor, recorder)
}

@MainActor
private func makeVerticalMouseWarpTestFixture() -> (
    controller: WMController,
    handler: MouseWarpHandler,
    topMonitor: Monitor,
    bottomMonitor: Monitor,
    recorder: WarpEffectRecorder
) {
    let settings = SettingsStore(defaults: makeMouseWarpTestDefaults())
    settings.mouseWarpMonitorOrder = ["Top", "Bottom"]
    settings.mouseWarpAxis = .vertical
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
    let bottomMonitor = makeMouseWarpTestMonitor(displayId: 1, name: "Bottom", x: 0, y: 0, width: 1728)
    let topMonitor = makeMouseWarpTestMonitor(displayId: 2, name: "Top", x: 320, y: 1080, width: 2560)
    controller.workspaceManager.applyMonitorConfigurationChange([bottomMonitor, topMonitor])

    let recorder = WarpEffectRecorder()
    let handler = controller.mouseWarpHandler
    handler.warpCursor = { point in recorder.warpedPoints.append(point) }
    handler.postMouseMovedEvent = { point in recorder.postedPoints.append(point) }
    return (controller, handler, topMonitor, bottomMonitor, recorder)
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
    for _ in 0..<iterations where !condition() {
        await waitForMainRunLoopTurn()
    }

    if !condition() {
        let snapshot = handler.mouseWarpDebugSnapshot()
        Issue.record("Timed out waiting for scheduled mouse warp drain: \(snapshot)")
    }
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
        #expect(fixture.recorder.warpedPoints.isEmpty)
        #expect(fixture.recorder.postedPoints == [expectedPoint])
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
        #expect(fixture.recorder.postedPoints == [expectedPoint])
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
        #expect(fixture.recorder.postedPoints == [expectedPoint])
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
        #expect(fixture.recorder.postedPoints == [expectedPoint])
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
        #expect(fixture.recorder.postedPoints == [expectedPoint])
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
        #expect(fixture.recorder.warpedPoints.isEmpty)
        #expect(fixture.recorder.postedPoints == [expectedPoint])
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
        #expect(fixture.recorder.warpedPoints.isEmpty)
        #expect(fixture.recorder.postedPoints == [expectedPoint])
    }

    @Test @MainActor func verticalModeFallsBackToSideClampWhenNoWarpTargetExists() {
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

        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: fixture.topMonitor.frame.minX + CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: fixture.topMonitor.frame.maxY - CGFloat(fixture.controller.settings.mouseWarpMargin) - 1
        ))

        #expect(fixture.handler.state.lastMonitorId == fixture.topMonitor.id)
        #expect(fixture.recorder.postedPoints.isEmpty)
        #expect(fixture.recorder.warpedPoints == [expectedPoint])
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
