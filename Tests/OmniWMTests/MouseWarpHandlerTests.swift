// SPDX-License-Identifier: GPL-2.0-only
import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

private final class WarpEffectRecorder: @unchecked Sendable {
    enum Event: Equatable {
        case warp(CGPoint)
        case post(CGPoint)
    }

    var warpedPoints: [CGPoint] = []
    var postedPoints: [CGPoint] = []
    var orderedEvents: [Event] = []
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
    var remainingByName = Dictionary(grouping: monitors, by: \.name)
    settings.mouseWarpMonitorOrder = monitorOrder.compactMap { name in
        guard var matches = remainingByName[name], !matches.isEmpty else { return nil }
        let monitor = matches.removeFirst()
        remainingByName[name] = matches
        return OutputId(from: monitor)
    }
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
    controller.lockScreenObserver.frontmostSnapshotProvider = { nil }
    controller.workspaceManager.applyMonitorConfigurationChange(monitors)

    let recorder = WarpEffectRecorder()
    let handler = controller.mouseWarpHandler
    handler.warpCursor = { point in
        recorder.warpedPoints.append(point)
        recorder.orderedEvents.append(.warp(point))
    }
    handler.postMouseMovedEvent = { point in
        recorder.postedPoints.append(point)
        recorder.orderedEvents.append(.post(point))
    }
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
    for _ in 0..<iterations where !condition() {
        await waitForMainRunLoopTurn()
    }

    if !condition() {
        let snapshot = handler.mouseWarpDebugSnapshot()
        Issue.record("Timed out waiting for scheduled mouse warp drain: \(snapshot)")
    }
}

private func ratioMappedY(sourceY: CGFloat, sourceFrame: CGRect, targetFrame: CGRect) -> CGFloat {
    guard sourceFrame.height > 0 else { return targetFrame.midY }
    let distanceFromBottom = sourceY - sourceFrame.minY
    let normalizedHeight = distanceFromBottom / sourceFrame.height
    return targetFrame.minY + (normalizedHeight * targetFrame.height)
}

private func expectPointApproximatelyEqual(
    _ actual: CGPoint?,
    to expected: CGPoint,
    tolerance: CGFloat
) {
    guard let actual else {
        Issue.record("Expected a warped point")
        return
    }

    #expect(abs(actual.x - expected.x) <= tolerance)
    #expect(abs(actual.y - expected.y) <= tolerance)
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
        #expect(fixture.recorder.warpedPoints.last == expectedPoint)
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

        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: fixture.rightMonitor.frame.minX + CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: location.y
        ))

        #expect(fixture.handler.state.lastMonitorId == fixture.rightMonitor.id)
        #expect(fixture.recorder.warpedPoints.last == expectedPoint)
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

    @Test @MainActor func policyUsesEffectiveOrderBeforeWarpingFreshMultiMonitorSetup() {
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

        #expect(fixture.controller.settings.mouseWarpMonitorOrder.isEmpty)
        #expect(fixture.recorder.warpedPoints.last == expectedPoint)
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

    @Test @MainActor func verticalModeWarpsFromBottomMonitorToTopMonitorPreservingXCoordinate() {
        let fixture = makeVerticalMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        let location = CGPoint(
            x: fixture.bottomMonitor.frame.minX + 432,
            y: fixture.bottomMonitor.frame.maxY - CGFloat(fixture.controller.settings.mouseWarpMargin) + 1
        )

        fixture.handler.resetDebugStateForTests()
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: 960,
            y: fixture.topMonitor.frame.minY + CGFloat(fixture.controller.settings.mouseWarpMargin) + 1
        ))

        #expect(fixture.handler.state.lastMonitorId == fixture.topMonitor.id)
        #expect(fixture.recorder.warpedPoints.last == expectedPoint)
    }

    @Test @MainActor func verticalModeWarpsFromTopMonitorToBottomMonitorPreservingXCoordinate() {
        let fixture = makeVerticalMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        let location = CGPoint(
            x: fixture.topMonitor.frame.minX + 1280,
            y: fixture.topMonitor.frame.minY + CGFloat(fixture.controller.settings.mouseWarpMargin) - 1
        )

        fixture.handler.resetDebugStateForTests()
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: 864,
            y: fixture.bottomMonitor.frame.maxY - CGFloat(fixture.controller.settings.mouseWarpMargin) - 1
        ))

        #expect(fixture.handler.state.lastMonitorId == fixture.bottomMonitor.id)
        #expect(fixture.recorder.warpedPoints.last == expectedPoint)
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
        #expect(fixture.recorder.warpedPoints.last == expectedPoint)
    }

    @Test @MainActor func verticalModeKeepsRightOverflowFallbackInsideDestinationMonitor() {
        let fixture = makeVerticalMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        fixture.handler.resetDebugStateForTests()
        fixture.handler.state.lastMonitorId = fixture.bottomMonitor.id

        let location = CGPoint(
            x: fixture.bottomMonitor.frame.maxX + 24,
            y: fixture.bottomMonitor.frame.maxY + 5
        )

        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        guard let warpedPoint = fixture.recorder.warpedPoints.last else {
            Issue.record("Expected a warped point")
            return
        }

        let actualPoint = ScreenCoordinateSpace.toAppKit(point: warpedPoint)
        let expectedY = fixture.topMonitor.frame.minY + CGFloat(fixture.controller.settings.mouseWarpMargin) + 1

        #expect(fixture.handler.state.lastMonitorId == fixture.topMonitor.id)
        #expect(actualPoint.x < fixture.topMonitor.frame.maxX)
        #expect(actualPoint.x > fixture.topMonitor.frame.maxX - 1)
        #expect(abs(actualPoint.y - expectedY) < 0.001)
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

        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: 2868,
            y: fixture.topMonitor.frame.minY + CGFloat(fixture.controller.settings.mouseWarpMargin) + 1
        ))

        #expect(fixture.handler.state.lastMonitorId == fixture.topMonitor.id)
        expectPointApproximatelyEqual(fixture.recorder.warpedPoints.last, to: expectedPoint, tolerance: 1.0)
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
        #expect(fixture.recorder.warpedPoints.last == expectedPoint)
        #expect(fixture.recorder.postedPoints.isEmpty)
    }

    @Test @MainActor func verticalAxisClampPicksNearestMonitorWhenCursorEscapesRightEdge() {
        let fixture = makeVerticalAxisSideBySideMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        let location = CGPoint(x: 2900, y: 500)
        fixture.handler.resetDebugStateForTests()
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        let margin = CGFloat(fixture.controller.settings.mouseWarpMargin)
        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: fixture.rightMonitor.frame.maxX - margin - 1,
            y: location.y
        ))

        #expect(fixture.recorder.warpedPoints.last == expectedPoint)
        #expect(fixture.recorder.postedPoints.isEmpty)
    }

    @Test @MainActor func nearestRectClampBringsCursorInsideChosenMonitorWhenAboveAllMonitors() {
        let fixture = makeVerticalAxisSideBySideMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        let location = CGPoint(x: fixture.rightMonitor.frame.midX, y: fixture.rightMonitor.frame.maxY + 20)
        fixture.handler.resetDebugStateForTests()
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        let margin = CGFloat(fixture.controller.settings.mouseWarpMargin)
        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: location.x,
            y: fixture.rightMonitor.frame.maxY - margin - 1
        ))

        #expect(fixture.recorder.warpedPoints.last == expectedPoint)
        #expect(fixture.recorder.postedPoints.isEmpty)
    }

    @Test @MainActor func horizontalAxisClampPicksNearestMonitorWhenCursorEscapesBelowBottomMonitor() {
        let fixture = makeHorizontalAxisStackedMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        let location = CGPoint(x: fixture.bottomMonitor.frame.midX, y: fixture.bottomMonitor.frame.minY - 20)
        fixture.handler.resetDebugStateForTests()
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        let margin = CGFloat(fixture.controller.settings.mouseWarpMargin)
        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: location.x,
            y: fixture.bottomMonitor.frame.minY + margin + 1
        ))

        #expect(fixture.recorder.warpedPoints.last == expectedPoint)
        #expect(fixture.recorder.postedPoints.isEmpty)
    }

    @Test @MainActor func clampPrefersStickyLastMonitorWhenSet() {
        let leftMonitor = makeMouseWarpTestMonitor(displayId: 1, name: "Left", x: 0, width: 100, height: 100)
        let rightMonitor = makeMouseWarpTestMonitor(displayId: 2, name: "Right", x: 200, width: 100, height: 100)
        let fixture = makeConfiguredMouseWarpTestFixture(
            monitors: [leftMonitor, rightMonitor],
            monitorOrder: ["Left", "Right"],
            axis: .vertical
        )
        defer { fixture.handler.cleanup() }

        fixture.handler.resetDebugStateForTests()
        fixture.handler.state.lastMonitorId = rightMonitor.id
        fixture.handler.receiveTapMouseWarpMoved(at: CGPoint(x: 150, y: 50))
        fixture.handler.flushPendingWarpEventsForTests()

        let margin = CGFloat(fixture.controller.settings.mouseWarpMargin)
        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: rightMonitor.frame.minX + margin + 1,
            y: 50
        ))

        #expect(fixture.recorder.warpedPoints.last == expectedPoint)
        #expect(fixture.handler.state.lastMonitorId == rightMonitor.id)
    }

    @Test @MainActor func clampNearestRectTieBreakUsesAxisSortWhenNoLastMonitor() {
        let leftMonitor = makeMouseWarpTestMonitor(displayId: 1, name: "Left", x: 0, width: 100, height: 100)
        let rightMonitor = makeMouseWarpTestMonitor(displayId: 2, name: "Right", x: 200, width: 100, height: 100)
        let fixture = makeConfiguredMouseWarpTestFixture(
            monitors: [leftMonitor, rightMonitor],
            monitorOrder: ["Left", "Right"],
            axis: .vertical
        )
        defer { fixture.handler.cleanup() }

        fixture.handler.resetDebugStateForTests()
        fixture.handler.receiveTapMouseWarpMoved(at: CGPoint(x: 150, y: 50))
        fixture.handler.flushPendingWarpEventsForTests()

        let margin = CGFloat(fixture.controller.settings.mouseWarpMargin)
        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: leftMonitor.frame.maxX - margin - 1,
            y: 50
        ))

        #expect(fixture.recorder.warpedPoints.last == expectedPoint)
    }

    @Test @MainActor func crossMonitorWarpPreservesOrthogonalCoordinate() {
        let sourceMonitor = makeMouseWarpTestMonitor(
            displayId: 1,
            name: "Source",
            x: 0,
            y: 0,
            width: 1440,
            height: 900
        )
        let destinationMonitor = makeMouseWarpTestMonitor(
            displayId: 2,
            name: "Destination",
            x: 1440,
            y: -200,
            width: 1920,
            height: 1080
        )
        let fixture = makeConfiguredMouseWarpTestFixture(
            monitors: [sourceMonitor, destinationMonitor],
            monitorOrder: ["Source", "Destination"],
            axis: .horizontal
        )
        defer { fixture.handler.cleanup() }

        let location = CGPoint(
            x: sourceMonitor.frame.maxX - CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: 500
        )
        fixture.handler.resetDebugStateForTests()
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: destinationMonitor.frame.minX + CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: ratioMappedY(
                sourceY: location.y,
                sourceFrame: sourceMonitor.frame,
                targetFrame: destinationMonitor.frame
            )
        ))

        #expect(fixture.recorder.warpedPoints.last == expectedPoint)
    }

    @Test @MainActor func crossMonitorWarpAppliesRatioWithinDestinationSpan() {
        let sourceMonitor = makeMouseWarpTestMonitor(
            displayId: 1,
            name: "Source",
            x: 0,
            y: 0,
            width: 1440,
            height: 900
        )
        let destinationMonitor = makeMouseWarpTestMonitor(
            displayId: 2,
            name: "Destination",
            x: 1440,
            y: 200,
            width: 1920,
            height: 400
        )
        let fixture = makeConfiguredMouseWarpTestFixture(
            monitors: [sourceMonitor, destinationMonitor],
            monitorOrder: ["Source", "Destination"],
            axis: .horizontal
        )
        defer { fixture.handler.cleanup() }

        let margin = CGFloat(fixture.controller.settings.mouseWarpMargin)
        let location = CGPoint(
            x: sourceMonitor.frame.maxX - margin + 1,
            y: 50
        )
        fixture.handler.resetDebugStateForTests()
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: destinationMonitor.frame.minX + margin + 1,
            y: 222.22
        ))

        expectPointApproximatelyEqual(fixture.recorder.warpedPoints.last, to: expectedPoint, tolerance: 0.5)
    }

    @Test @MainActor func horizontalWarpPreservesVisualYAcrossDiagonallyOffsetMonitors() {
        let leftMonitor = makeMouseWarpTestMonitor(displayId: 1, name: "Left", x: 0, y: 0, width: 1920, height: 1080)
        let rightMonitor = makeMouseWarpTestMonitor(
            displayId: 2,
            name: "Right",
            x: 1920,
            y: 1080,
            width: 1920,
            height: 1080
        )
        let sourceCases: [(CGPoint, CGFloat)] = [
            (CGPoint(x: 1919, y: 1079), 2159),
            (CGPoint(x: 1919, y: 1), 1081),
            (CGPoint(x: 1919, y: 540), 1620),
        ]

        for (location, expectedY) in sourceCases {
            let fixture = makeConfiguredMouseWarpTestFixture(
                monitors: [leftMonitor, rightMonitor],
                monitorOrder: ["Left", "Right"],
                axis: .horizontal
            )
            defer { fixture.handler.cleanup() }

            fixture.handler.resetDebugStateForTests()
            fixture.handler.receiveTapMouseWarpMoved(at: location)
            fixture.handler.flushPendingWarpEventsForTests()

            let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(x: 1923, y: expectedY))
            expectPointApproximatelyEqual(fixture.recorder.warpedPoints.last, to: expectedPoint, tolerance: 0.5)
        }
    }

    @Test @MainActor func horizontalModeUsesLastValidMonitorWhenCursorLeavesThroughNonOverlappingBand() {
        let leftMonitor = makeMouseWarpTestMonitor(displayId: 1, name: "Left", x: 0, y: 0, width: 1920, height: 1080)
        let rightMonitor = makeMouseWarpTestMonitor(
            displayId: 2,
            name: "Right",
            x: 1920,
            y: 400,
            width: 1920,
            height: 1080
        )
        let fixture = makeConfiguredMouseWarpTestFixture(
            monitors: [leftMonitor, rightMonitor],
            monitorOrder: ["Left", "Right"],
            axis: .horizontal
        )
        defer { fixture.handler.cleanup() }

        fixture.handler.resetDebugStateForTests()
        fixture.handler.state.lastMonitorId = leftMonitor.id

        let location = CGPoint(x: leftMonitor.frame.maxX + 24, y: 100)
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: rightMonitor.frame.minX + CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: ratioMappedY(
                sourceY: location.y,
                sourceFrame: leftMonitor.frame,
                targetFrame: rightMonitor.frame
            )
        ))

        #expect(fixture.handler.state.lastMonitorId == rightMonitor.id)
        expectPointApproximatelyEqual(fixture.recorder.warpedPoints.last, to: expectedPoint, tolerance: 0.5)
    }

    @Test @MainActor func duplicateNamedMonitorsWarpToExplicitOutputIdDestination() {
        let leftMonitor = makeMouseWarpTestMonitor(displayId: 1, name: "Studio Display", x: 0, y: 0)
        let rightMonitor = makeMouseWarpTestMonitor(displayId: 2, name: "Studio Display", x: 1920, y: 0)
        let fixture = makeConfiguredMouseWarpTestFixture(
            monitors: [leftMonitor, rightMonitor],
            monitorOrder: ["Studio Display", "Studio Display"],
            axis: .horizontal
        )
        defer { fixture.handler.cleanup() }

        fixture.controller.settings.mouseWarpMonitorOrder = [
            OutputId(from: leftMonitor),
            OutputId(from: rightMonitor)
        ]

        let location = CGPoint(
            x: leftMonitor.frame.maxX - CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: leftMonitor.frame.midY
        )
        fixture.handler.resetDebugStateForTests()
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        fixture.handler.flushPendingWarpEventsForTests()

        let expectedPoint = ScreenCoordinateSpace.toWindowServer(point: CGPoint(
            x: rightMonitor.frame.minX + CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: rightMonitor.frame.midY
        ))

        #expect(fixture.handler.state.lastMonitorId == rightMonitor.id)
        #expect(fixture.recorder.warpedPoints.last == expectedPoint)
    }

    @Test @MainActor func crossMonitorWarpDriveBothHardwareAndSyntheticEventAtSamePoint() {
        let fixture = makeMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

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

        #expect(fixture.recorder.orderedEvents == [.warp(expectedPoint), .post(expectedPoint)])
    }

    @Test @MainActor func slowCrossMonitorTransitionDoesNotOscillate() {
        let fixture = makeMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        let margin = CGFloat(fixture.controller.settings.mouseWarpMargin)
        let sourceLocation = CGPoint(
            x: fixture.leftMonitor.frame.maxX - margin + 1,
            y: fixture.leftMonitor.frame.midY
        )
        let destinationLocation = CGPoint(
            x: fixture.rightMonitor.frame.minX + margin + 1,
            y: fixture.rightMonitor.frame.midY
        )

        fixture.handler.resetDebugStateForTests()
        fixture.handler.receiveTapMouseWarpMoved(at: sourceLocation)
        fixture.handler.flushPendingWarpEventsForTests()
        fixture.handler.receiveTapMouseWarpMoved(at: destinationLocation)
        fixture.handler.flushPendingWarpEventsForTests()

        #expect(fixture.recorder.warpedPoints.count == 1)
        #expect(fixture.recorder.postedPoints.count == 1)
        #expect(fixture.handler.state.isWarping == true)
    }

    @Test @MainActor func warpSuppressedWhileLockScreenActive() {
        let fixture = makeMouseWarpTestFixture()
        defer { fixture.handler.cleanup() }

        let location = CGPoint(
            x: fixture.leftMonitor.frame.maxX - CGFloat(fixture.controller.settings.mouseWarpMargin) + 1,
            y: fixture.leftMonitor.frame.midY
        )

        fixture.handler.resetDebugStateForTests()
        fixture.controller.isLockScreenActive = true
        fixture.handler.receiveTapMouseWarpMoved(at: location)

        #expect(fixture.handler.mouseWarpDebugSnapshot() == .init())
        #expect(fixture.handler.state.pendingWarpEvents.hasPendingEvents == false)

        fixture.controller.isLockScreenActive = false
        fixture.handler.receiveTapMouseWarpMoved(at: location)
        #expect(fixture.handler.state.pendingWarpEvents.hasPendingEvents == true)

        fixture.controller.isLockScreenActive = true
        fixture.handler.flushPendingWarpEventsForTests()

        let snapshot = fixture.handler.mouseWarpDebugSnapshot()
        #expect(snapshot.queuedTransientEvents == 1)
        #expect(snapshot.drainedTransientEvents == 1)
        #expect(snapshot.drainRuns == 1)
        #expect(fixture.handler.state.pendingWarpEvents.hasPendingEvents == false)
        #expect(fixture.recorder.warpedPoints.isEmpty)
        #expect(fixture.recorder.postedPoints.isEmpty)
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
