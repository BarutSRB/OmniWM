// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics
@testable import OmniWM
import XCTest

/// Drives the multitouch snapshot pipeline with synthetic frames to exercise window move and resize
/// gestures: fingers dragging across the trackpad without any mouse button held.
@MainActor
final class TrackpadWindowGestureTests: XCTestCase {
    private let workingFrame = CGRect(x: 0, y: 0, width: 1600, height: 900)

    @MainActor
    private struct NiriFixture {
        let controller: WMController
        let engine: NiriLayoutEngine
        let monitor: Monitor
        let workspaceId: WorkspaceDescriptor.ID
        let first: NiriWindow
        let second: NiriWindow
        let firstFrame: CGRect
        let secondFrame: CGRect

        var handler: MouseEventHandler {
            controller.mouseEventHandler
        }

        func windowOrder() -> [WindowToken] {
            engine.columns(in: workspaceId).flatMap { $0.windowNodes.map(\.token) }
        }

        func frames() -> [WindowToken: CGRect] {
            let gap = controller.innerGap(for: monitor)
            return engine.calculateLayout(
                state: controller.workspaceManager.niriViewportState(for: workspaceId),
                workspaceId: workspaceId,
                monitorFrame: controller.insetWorkingFrame(for: monitor),
                gaps: (horizontal: gap, vertical: gap),
                orientation: .horizontal
            )
        }
    }

    @MainActor
    private struct DwindleFixture {
        let controller: WMController
        let engine: DwindleLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let screen: CGRect
        let first: WindowToken
        let second: WindowToken
        let firstFrame: CGRect
        let secondFrame: CGRect

        var handler: MouseEventHandler {
            controller.mouseEventHandler
        }

        func presentedFrame(_ token: WindowToken) -> CGRect? {
            engine.presentedFrame(for: token, in: workspaceId, at: 0)
        }

        func relayout() {
            _ = engine.calculateLayout(for: workspaceId, screen: screen)
            engine.cancelAnimations(in: workspaceId)
        }
    }

    // MARK: - Niri

    func testFourFingerDragMovesWindowAndSwapsOnRelease() throws {
        let fixture = try makeNiriFixture(pid: 9_101)
        let handler = fixture.handler
        let orderBefore = fixture.windowOrder()
        XCTAssertEqual(orderBefore, [fixture.first.token, fixture.second.token])

        // Cursor on the first window; carry the virtual cursor to the second window's center.
        let start = fixture.firstFrame.center
        let travel = (fixture.secondFrame.center.x - start.x) / fixture.monitor.frame.width
        var time: TimeInterval = 100
        sendFrame(handler, phase: .began, fingers: 4, x: 0.2, y: 0.5, at: time, location: start)
        XCTAssertEqual(handler.state.gesturePhase, .armed)
        XCTAssertFalse(handler.state.isMoving)

        for step in 1 ... 10 {
            time += 0.01
            sendFrame(
                handler,
                phase: .changed,
                fingers: 4,
                x: 0.2 + travel * CGFloat(step) / 10,
                y: 0.5,
                at: time,
                location: start
            )
        }

        XCTAssertEqual(handler.state.gesturePhase, .committed)
        XCTAssertEqual(handler.state.activeGestureMode, .windowMove)
        XCTAssertTrue(handler.state.isMoving)
        XCTAssertTrue(handler.state.gestureOwnsWindowInteraction)
        XCTAssertEqual(handler.state.moveLayout, .niri)
        XCTAssertNil(handler.state.activeInteractionButton)
        XCTAssertEqual(fixture.engine.interactiveMove?.windowToken, fixture.first.token)
        XCTAssertFalse(handler.isViewportGestureActive)
        XCTAssertTrue(handler.isInteractiveGestureActive)
        guard case let .window(_, targetToken, insertPosition)? = fixture.engine.interactiveMove?.currentHoverTarget
        else {
            return XCTFail("Expected the virtual cursor to hover the second window")
        }
        XCTAssertEqual(targetToken, fixture.second.token)
        XCTAssertEqual(insertPosition, .swap)

        time += 0.01
        sendFrame(handler, phase: .ended, fingers: 0, x: 0, y: 0, at: time, location: start)

        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertFalse(handler.state.isMoving)
        XCTAssertFalse(handler.state.gestureOwnsWindowInteraction)
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertEqual(fixture.windowOrder(), [fixture.second.token, fixture.first.token])
    }

    func testThreeFingerDragResizesWindowUntilFingersLift() throws {
        let fixture = try makeNiriFixture(pid: 9_102)
        let handler = fixture.handler
        let widthBefore = fixture.firstFrame.width

        // Cursor in the right half of the first window so the gesture grabs its right edge.
        let start = CGPoint(x: fixture.firstFrame.maxX - 20, y: fixture.firstFrame.midY)
        var time: TimeInterval = 100
        sendFrame(handler, phase: .began, fingers: 3, x: 0.4, y: 0.5, at: time, location: start)
        for step in 1 ... 8 {
            time += 0.01
            sendFrame(
                handler,
                phase: .changed,
                fingers: 3,
                x: 0.4 + 0.0125 * CGFloat(step),
                y: 0.5,
                at: time,
                location: start
            )
        }

        XCTAssertEqual(handler.state.activeGestureMode, .windowResize)
        XCTAssertTrue(handler.state.isResizing)
        XCTAssertTrue(handler.state.gestureOwnsWindowInteraction)
        XCTAssertEqual(handler.state.resizeLayout, .niri)
        XCTAssertNil(handler.state.activeInteractionButton)
        let resize = try XCTUnwrap(fixture.engine.interactiveResize)
        XCTAssertTrue(resize.edges.contains(.right))
        XCTAssertEqual(resize.startMouseLocation, start)

        time += 0.01
        sendFrame(handler, phase: .ended, fingers: 0, x: 0, y: 0, at: time, location: start)

        XCTAssertFalse(handler.state.isResizing)
        XCTAssertFalse(handler.state.gestureOwnsWindowInteraction)
        XCTAssertNil(fixture.engine.interactiveResize)
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        let widthAfter = try XCTUnwrap(fixture.frames()[fixture.first.token]).width
        // 0.1 of trackpad travel at sensitivity 1.0 is 160pt on a 1600pt monitor.
        XCTAssertEqual(widthAfter, widthBefore + 160, accuracy: 2)
    }

    func testSensitivityScalesVirtualCursorTravel() throws {
        let fixture = try makeNiriFixture(pid: 9_103)
        fixture.controller.settings.windowGestureSensitivity = 0.5
        let handler = fixture.handler
        let widthBefore = fixture.firstFrame.width
        let start = CGPoint(x: fixture.firstFrame.maxX - 20, y: fixture.firstFrame.midY)
        var time: TimeInterval = 100
        sendFrame(handler, phase: .began, fingers: 3, x: 0.4, y: 0.5, at: time, location: start)
        for step in 1 ... 8 {
            time += 0.01
            sendFrame(
                handler,
                phase: .changed,
                fingers: 3,
                x: 0.4 + 0.0125 * CGFloat(step),
                y: 0.5,
                at: time,
                location: start
            )
        }
        time += 0.01
        sendFrame(handler, phase: .ended, fingers: 0, x: 0, y: 0, at: time, location: start)

        let widthAfter = try XCTUnwrap(fixture.frames()[fixture.first.token]).width
        XCTAssertEqual(widthAfter, widthBefore + 80, accuracy: 2)
    }

    func testWindowGestureWithNoWindowUnderCursorNeverArms() throws {
        let fixture = try makeNiriFixture(pid: 9_104)
        let handler = fixture.handler
        let offMonitor = CGPoint(x: workingFrame.maxX + 400, y: workingFrame.midY)
        var time: TimeInterval = 100
        sendFrame(handler, phase: .began, fingers: 4, x: 0.2, y: 0.5, at: time, location: offMonitor)
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        for step in 1 ... 5 {
            time += 0.01
            sendFrame(
                handler,
                phase: .changed,
                fingers: 4,
                x: 0.2 + 0.05 * CGFloat(step),
                y: 0.5,
                at: time,
                location: offMonitor
            )
        }
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertFalse(handler.state.isMoving)
        XCTAssertNil(fixture.engine.interactiveMove)
        time += 0.01
        sendFrame(handler, phase: .ended, fingers: 0, x: 0, y: 0, at: time, location: offMonitor)
    }

    func testDisabledWindowGesturesIgnoreTheirFingerCount() throws {
        let fixture = try makeNiriFixture(pid: 9_105)
        fixture.controller.settings.windowMoveGestureEnabled = false
        fixture.controller.settings.windowResizeGestureEnabled = false
        fixture.controller.settings.workspaceSwipeEnabled = true
        let handler = fixture.handler
        let start = fixture.firstFrame.center
        var time: TimeInterval = 100
        sendFrame(handler, phase: .began, fingers: 4, x: 0.2, y: 0.5, at: time, location: start)
        for step in 1 ... 5 {
            time += 0.01
            sendFrame(
                handler,
                phase: .changed,
                fingers: 4,
                x: 0.2 + 0.05 * CGFloat(step),
                y: 0.5,
                at: time,
                location: start
            )
        }
        XCTAssertFalse(handler.state.isMoving)
        XCTAssertNil(fixture.engine.interactiveMove)
        time += 0.01
        sendFrame(handler, phase: .ended, fingers: 0, x: 0, y: 0, at: time, location: start)
    }

    func testWindowResizeGestureTakesThreeFingersAwayFromColumnScroll() throws {
        let fixture = try makeNiriFixture(pid: 9_106)
        fixture.controller.settings.scrollGestureEnabled = true
        fixture.controller.settings.gestureFingerCount = .three
        fixture.controller.settings.windowResizeGestureFingerCount = .three
        let handler = fixture.handler
        let start = CGPoint(x: fixture.firstFrame.maxX - 20, y: fixture.firstFrame.midY)
        var time: TimeInterval = 100
        sendFrame(handler, phase: .began, fingers: 3, x: 0.4, y: 0.5, at: time, location: start)
        for step in 1 ... 4 {
            time += 0.01
            sendFrame(
                handler,
                phase: .changed,
                fingers: 3,
                x: 0.4 + 0.02 * CGFloat(step),
                y: 0.5,
                at: time,
                location: start
            )
        }
        XCTAssertEqual(handler.state.activeGestureMode, .windowResize)
        XCTAssertTrue(handler.state.isResizing)
        XCTAssertFalse(handler.isViewportGestureActive)
        time += 0.01
        sendFrame(handler, phase: .ended, fingers: 0, x: 0, y: 0, at: time, location: start)
        XCTAssertFalse(handler.state.isResizing)
    }

    func testCancelledTouchSessionRevertsMoveInsteadOfDropping() throws {
        let fixture = try makeNiriFixture(pid: 9_107)
        let handler = fixture.handler
        let start = fixture.firstFrame.center
        let travel = (fixture.secondFrame.center.x - start.x) / fixture.monitor.frame.width
        var time: TimeInterval = 100
        sendFrame(handler, phase: .began, fingers: 4, x: 0.2, y: 0.5, at: time, location: start)
        for step in 1 ... 10 {
            time += 0.01
            sendFrame(
                handler,
                phase: .changed,
                fingers: 4,
                x: 0.2 + travel * CGFloat(step) / 10,
                y: 0.5,
                at: time,
                location: start
            )
        }
        XCTAssertTrue(handler.state.isMoving)

        time += 0.01
        sendFrame(handler, phase: .cancelled, fingers: 0, x: 0, y: 0, at: time, location: start)

        XCTAssertFalse(handler.state.isMoving)
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertEqual(fixture.windowOrder(), [fixture.first.token, fixture.second.token])
    }

    func testLiftingOneFingerDropsTheWindow() throws {
        let fixture = try makeNiriFixture(pid: 9_108)
        let handler = fixture.handler
        let start = fixture.firstFrame.center
        let travel = (fixture.secondFrame.center.x - start.x) / fixture.monitor.frame.width
        var time: TimeInterval = 100
        sendFrame(handler, phase: .began, fingers: 4, x: 0.2, y: 0.5, at: time, location: start)
        for step in 1 ... 10 {
            time += 0.01
            sendFrame(
                handler,
                phase: .changed,
                fingers: 4,
                x: 0.2 + travel * CGFloat(step) / 10,
                y: 0.5,
                at: time,
                location: start
            )
        }
        XCTAssertTrue(handler.state.isMoving)

        time += 0.01
        sendFrame(
            handler,
            phase: .changed,
            fingers: 3,
            x: 0.2 + travel,
            y: 0.5,
            at: time,
            location: start
        )

        XCTAssertFalse(handler.state.isMoving)
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertEqual(fixture.windowOrder(), [fixture.second.token, fixture.first.token])
        XCTAssertTrue(handler.state.suppressGestureStartUntilAllTouchesLift)

        time += 0.01
        sendFrame(handler, phase: .ended, fingers: 0, x: 0, y: 0, at: time, location: start)
        XCTAssertFalse(handler.state.suppressGestureStartUntilAllTouchesLift)
    }

    func testMouseEventsDoNotDisturbGestureOwnedMove() throws {
        let fixture = try makeNiriFixture(pid: 9_109)
        let handler = fixture.handler
        let start = fixture.firstFrame.center
        var time: TimeInterval = 100
        sendFrame(handler, phase: .began, fingers: 4, x: 0.2, y: 0.5, at: time, location: start)
        for step in 1 ... 4 {
            time += 0.01
            sendFrame(
                handler,
                phase: .changed,
                fingers: 4,
                x: 0.2 + 0.02 * CGFloat(step),
                y: 0.5,
                at: time,
                location: start
            )
        }
        XCTAssertTrue(handler.state.isMoving)

        handler.pressedMouseButtonsProvider = { 0 }
        handler.dispatchMouseDragged(at: fixture.secondFrame.center)
        XCTAssertTrue(handler.state.isMoving, "A mouse drag without a held button must not cancel a gesture move")
        handler.dispatchMouseUp(at: fixture.secondFrame.center)
        XCTAssertTrue(handler.state.isMoving, "A stray mouse-up must not drop a gesture move")
        XCTAssertFalse(
            handler.dispatchMouseDown(at: fixture.secondFrame.center, modifiers: .maskAlternate),
            "A modifier click cannot start a second interaction while the gesture owns one"
        )
        XCTAssertNotNil(fixture.engine.interactiveMove)

        time += 0.01
        sendFrame(handler, phase: .ended, fingers: 0, x: 0, y: 0, at: time, location: start)
        XCTAssertFalse(handler.state.isMoving)
    }

    func testDisablingControllerMidGestureCancelsMoveAndClearsGestureState() throws {
        let fixture = try makeNiriFixture(pid: 9_110)
        let handler = fixture.handler
        let start = fixture.firstFrame.center
        var time: TimeInterval = 100
        sendFrame(handler, phase: .began, fingers: 4, x: 0.2, y: 0.5, at: time, location: start)
        for step in 1 ... 4 {
            time += 0.01
            sendFrame(
                handler,
                phase: .changed,
                fingers: 4,
                x: 0.2 + 0.02 * CGFloat(step),
                y: 0.5,
                at: time,
                location: start
            )
        }
        XCTAssertTrue(handler.state.isMoving)

        fixture.controller.isEnabled = false
        time += 0.01
        sendFrame(
            handler,
            phase: .changed,
            fingers: 4,
            x: 0.3,
            y: 0.5,
            at: time,
            location: start
        )

        XCTAssertFalse(handler.state.isMoving)
        XCTAssertFalse(handler.state.gestureOwnsWindowInteraction)
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertEqual(fixture.windowOrder(), [fixture.first.token, fixture.second.token])

        time += 0.01
        sendFrame(handler, phase: .ended, fingers: 0, x: 0, y: 0, at: time, location: start)
        fixture.controller.isEnabled = true
    }

    func testCleanupWhileGestureOwnsMoveReconcilesEverything() throws {
        let fixture = try makeNiriFixture(pid: 9_111)
        let handler = fixture.handler
        let start = fixture.firstFrame.center
        var time: TimeInterval = 100
        sendFrame(handler, phase: .began, fingers: 4, x: 0.2, y: 0.5, at: time, location: start)
        for step in 1 ... 4 {
            time += 0.01
            sendFrame(
                handler,
                phase: .changed,
                fingers: 4,
                x: 0.2 + 0.02 * CGFloat(step),
                y: 0.5,
                at: time,
                location: start
            )
        }
        XCTAssertTrue(handler.state.isMoving)

        handler.cleanup()

        XCTAssertFalse(handler.state.isMoving)
        XCTAssertFalse(handler.state.gestureOwnsWindowInteraction)
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertFalse(handler.isInteractiveGestureActive)
    }

    // MARK: - Dwindle

    func testFourFingerDragSwapsDwindleTilesOnRelease() throws {
        let fixture = try makeDwindleFixture(pid: 9_201)
        let handler = fixture.handler
        let start = fixture.firstFrame.center
        let travel = (fixture.secondFrame.center.x - start.x) / fixture.screen.width
        var time: TimeInterval = 100
        sendFrame(handler, phase: .began, fingers: 4, x: 0.2, y: 0.5, at: time, location: start)
        for step in 1 ... 10 {
            time += 0.01
            sendFrame(
                handler,
                phase: .changed,
                fingers: 4,
                x: 0.2 + travel * CGFloat(step) / 10,
                y: 0.5,
                at: time,
                location: start
            )
        }

        XCTAssertTrue(handler.state.isMoving)
        XCTAssertEqual(handler.state.moveLayout, .dwindle)
        XCTAssertEqual(fixture.engine.interactiveMove?.token, fixture.first)
        XCTAssertEqual(fixture.engine.interactiveMove?.targetToken, fixture.second)

        time += 0.01
        sendFrame(handler, phase: .ended, fingers: 0, x: 0, y: 0, at: time, location: start)

        XCTAssertFalse(handler.state.isMoving)
        XCTAssertNil(fixture.engine.interactiveMove)
        fixture.relayout()
        XCTAssertEqual(fixture.presentedFrame(fixture.first), fixture.secondFrame)
        XCTAssertEqual(fixture.presentedFrame(fixture.second), fixture.firstFrame)
    }

    func testThreeFingerDragResizesDwindleSplit() throws {
        let fixture = try makeDwindleFixture(pid: 9_202)
        let handler = fixture.handler
        let start = CGPoint(x: fixture.firstFrame.maxX - 20, y: fixture.firstFrame.midY)
        var time: TimeInterval = 100
        sendFrame(handler, phase: .began, fingers: 3, x: 0.4, y: 0.5, at: time, location: start)
        for step in 1 ... 8 {
            time += 0.01
            sendFrame(
                handler,
                phase: .changed,
                fingers: 3,
                x: 0.4 + 0.0125 * CGFloat(step),
                y: 0.5,
                at: time,
                location: start
            )
        }
        XCTAssertTrue(handler.state.isResizing)
        XCTAssertEqual(handler.state.resizeLayout, .dwindle)
        XCTAssertEqual(fixture.engine.interactiveResize?.token, fixture.first)

        time += 0.01
        sendFrame(handler, phase: .ended, fingers: 0, x: 0, y: 0, at: time, location: start)

        XCTAssertFalse(handler.state.isResizing)
        XCTAssertNil(fixture.engine.interactiveResize)
        fixture.relayout()
        let widthAfter = try XCTUnwrap(fixture.presentedFrame(fixture.first)).width
        XCTAssertGreaterThan(widthAfter, fixture.firstFrame.width + 100)
    }

    func testDwindleResizeGestureFallsBackToTheEdgeThatCanMove() throws {
        let fixture = try makeDwindleFixture(pid: 9_203)
        let handler = fixture.handler
        // The first tile sits against the left screen edge: its nearest edge cannot move, its right one can.
        let start = CGPoint(x: fixture.firstFrame.minX + 20, y: fixture.firstFrame.minY + 20)
        XCTAssertEqual(fixture.engine.resizableEdges(for: fixture.first, in: fixture.workspaceId), .right)

        var time: TimeInterval = 100
        sendFrame(handler, phase: .began, fingers: 3, x: 0.4, y: 0.5, at: time, location: start)
        for step in 1 ... 8 {
            time += 0.01
            sendFrame(
                handler,
                phase: .changed,
                fingers: 3,
                x: 0.4 + 0.0125 * CGFloat(step),
                y: 0.5,
                at: time,
                location: start
            )
        }
        XCTAssertTrue(handler.state.isResizing)
        XCTAssertEqual(fixture.engine.interactiveResize?.edges, .right)
        XCTAssertFalse(handler.state.suppressGestureStartUntilAllTouchesLift)

        time += 0.01
        sendFrame(handler, phase: .ended, fingers: 0, x: 0, y: 0, at: time, location: start)

        XCTAssertFalse(handler.state.isResizing)
        fixture.relayout()
        let widthAfter = try XCTUnwrap(fixture.presentedFrame(fixture.first)).width
        XCTAssertGreaterThan(widthAfter, fixture.firstFrame.width + 100)
    }

    func testGestureResizeEdgesPreferNearestThenOppositeThenDropAxis() {
        XCTAssertEqual(
            MouseEventHandler.gestureResizeEdges(nearest: [.left, .top], resizable: .all),
            [.left, .top]
        )
        XCTAssertEqual(
            MouseEventHandler.gestureResizeEdges(nearest: [.left, .top], resizable: [.right, .bottom]),
            [.right, .bottom]
        )
        XCTAssertEqual(
            MouseEventHandler.gestureResizeEdges(nearest: [.left, .top], resizable: [.right]),
            .right
        )
        XCTAssertEqual(
            MouseEventHandler.gestureResizeEdges(nearest: [.right, .bottom], resizable: [.left, .right]),
            .right
        )
        XCTAssertTrue(MouseEventHandler.gestureResizeEdges(nearest: [.left, .top], resizable: []).isEmpty)
    }

    func testLateFourthFingerReArmsFromResizeToMoveBeforeCommit() throws {
        let fixture = try makeNiriFixture(pid: 9_112)
        let handler = fixture.handler
        let start = fixture.firstFrame.center
        let travel = (fixture.secondFrame.center.x - start.x) / fixture.monitor.frame.width
        var time: TimeInterval = 100
        // Three fingers land first and drift a little, staying under the commit threshold.
        sendFrame(handler, phase: .began, fingers: 3, x: 0.2, y: 0.5, at: time, location: start)
        time += 0.01
        sendFrame(handler, phase: .changed, fingers: 3, x: 0.21, y: 0.5, at: time, location: start)
        XCTAssertEqual(handler.state.gesturePhase, .armed)
        XCTAssertEqual(handler.state.lockedGestureContext?.fingerCount, 3)

        // The fourth finger arrives: the gesture must become a four-finger move, not abort.
        for step in 0 ... 10 {
            time += 0.01
            sendFrame(
                handler,
                phase: .changed,
                fingers: 4,
                x: 0.21 + travel * CGFloat(step) / 10,
                y: 0.5,
                at: time,
                location: start
            )
        }
        XCTAssertEqual(handler.state.lockedGestureContext?.fingerCount, 4)
        XCTAssertEqual(handler.state.activeGestureMode, .windowMove)
        XCTAssertTrue(handler.state.isMoving)
        XCTAssertFalse(handler.state.isResizing)

        time += 0.01
        sendFrame(handler, phase: .ended, fingers: 0, x: 0, y: 0, at: time, location: start)
        XCTAssertEqual(fixture.windowOrder(), [fixture.second.token, fixture.first.token])
    }

    // MARK: - Helpers

    private func sendFrame(
        _ handler: MouseEventHandler,
        phase: NSEvent.Phase,
        fingers: Int,
        x: CGFloat,
        y: CGFloat,
        at timestamp: TimeInterval,
        location: CGPoint
    ) {
        let touches = (0 ..< fingers).map { _ in
            MouseEventHandler.GestureTouchSample(phase: .moved, normalizedPosition: CGPoint(x: x, y: y))
        }
        handler.receiveTapGestureEvent(
            MouseEventHandler.GestureEventSnapshot(
                location: location,
                phaseRawValue: phase.rawValue,
                timestamp: timestamp,
                touches: phase == .ended || phase == .cancelled ? [] : touches
            )
        )
    }

    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackpadWindowGestureTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        let controller = WMController(settings: settings)
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        settings.animationsEnabled = false
        // Window gestures alone; column scroll and workspace swipe stay out of the way unless a test opts in.
        settings.scrollGestureEnabled = false
        settings.workspaceSwipeEnabled = false
        settings.windowMoveGestureEnabled = true
        settings.windowMoveGestureFingerCount = .four
        settings.windowResizeGestureEnabled = true
        settings.windowResizeGestureFingerCount = .three
        settings.windowGestureSensitivity = 1.0
        return controller
    }

    private func makeMonitor() -> Monitor {
        Monitor(
            id: .init(displayId: 52_001),
            displayId: 52_001,
            frame: workingFrame,
            visibleFrame: workingFrame,
            hasNotch: false,
            name: "Trackpad Window Gesture"
        )
    }

    private func makeNiriFixture(pid: pid_t) throws -> NiriFixture {
        let controller = makeController()
        let monitor = makeMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)

        var windows: [NiriWindow] = []
        for windowId in 1 ... 2 {
            let token = WindowToken(pid: pid, windowId: windowId)
            _ = controller.workspaceManager.addWindow(
                WindowAdmissionTestSupport.axRef(for: token),
                pid: pid,
                windowId: windowId,
                to: workspaceId
            )
            let window = engine.addWindow(token: token, to: workspaceId, afterSelection: windows.last?.id)
            windows.append(window)
        }
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                windows[0].token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        for column in engine.columns(in: workspaceId) {
            column.cachedWidth = 700
        }
        let gap = controller.innerGap(for: monitor)
        let frames = engine.calculateLayout(
            state: controller.workspaceManager.niriViewportState(for: workspaceId),
            workspaceId: workspaceId,
            monitorFrame: controller.insetWorkingFrame(for: monitor),
            gaps: (horizontal: gap, vertical: gap),
            orientation: .horizontal
        )
        let firstFrame = try XCTUnwrap(frames[windows[0].token])
        let secondFrame = try XCTUnwrap(frames[windows[1].token])
        XCTAssertLessThan(firstFrame.maxX, secondFrame.minX)
        XCTAssertNotNil(engine.hitTestTiled(point: firstFrame.center, in: workspaceId))
        XCTAssertNotNil(engine.hitTestTiled(point: secondFrame.center, in: workspaceId))

        return NiriFixture(
            controller: controller,
            engine: engine,
            monitor: monitor,
            workspaceId: workspaceId,
            first: windows[0],
            second: windows[1],
            firstFrame: firstFrame,
            secondFrame: secondFrame
        )
    }

    private func makeDwindleFixture(pid: pid_t) throws -> DwindleFixture {
        let controller = makeController()
        let monitor = makeMonitor()
        controller.settings.workspaceConfigurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: .dwindle
            )
        ]
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.enableDwindleLayout()
        let engine = try XCTUnwrap(controller.dwindleEngine)
        var tokens: [WindowToken] = []
        for windowId in 1 ... 2 {
            let token = controller.workspaceManager.addWindow(
                WindowAdmissionTestSupport.axRef(for: WindowToken(pid: pid, windowId: windowId)),
                pid: pid,
                windowId: windowId,
                to: workspaceId
            )
            controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
                _ = engine.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
            }
            tokens.append(token)
        }
        let screen = controller.insetWorkingFrame(for: monitor)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)
        engine.cancelAnimations(in: workspaceId)
        let firstFrame = try XCTUnwrap(engine.presentedFrame(for: tokens[0], in: workspaceId, at: 0))
        let secondFrame = try XCTUnwrap(engine.presentedFrame(for: tokens[1], in: workspaceId, at: 0))
        XCTAssertNotEqual(firstFrame, secondFrame)
        XCTAssertEqual(controller.settings.layoutType(for: "1"), .dwindle)

        return DwindleFixture(
            controller: controller,
            engine: engine,
            workspaceId: workspaceId,
            screen: screen,
            first: tokens[0],
            second: tokens[1],
            firstFrame: firstFrame,
            secondFrame: secondFrame
        )
    }
}
