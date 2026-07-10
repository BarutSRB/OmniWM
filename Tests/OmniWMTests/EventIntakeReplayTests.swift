// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
@testable import OmniWM
import XCTest

final class EventIntakeReplayTests: XCTestCase {
    @MainActor
    private final class RecordingSink: EventIntakeSink {
        var received: [StampedIntakeEvent] = []

        func handleIntakeEvent(_ stamped: StampedIntakeEvent) {
            received.append(stamped)
        }
    }

    @MainActor
    func testIntakeStampsMonotonicallyAndPreservesOrder() {
        let intake = EventIntake()
        let sink = RecordingSink()
        intake.open(sink: sink)
        defer { intake.close() }

        intake.enqueue(.appActivated(pid: 1))
        intake.enqueue(.cgs(.frameChanged(windowId: 7)))
        intake.enqueue(.appDeactivated(pid: 1))
        intake.drainNow()
        intake.enqueue(.appHidden(pid: 1))
        intake.drainNow()

        XCTAssertEqual(sink.received.count, 4)
        let seqs = sink.received.map(\.seq)
        XCTAssertEqual(seqs, seqs.sorted())
        XCTAssertEqual(Set(seqs).count, seqs.count)
        guard case .appActivated = sink.received[0].event,
              case .cgs(.frameChanged) = sink.received[1].event,
              case .appDeactivated = sink.received[2].event,
              case .appHidden = sink.received[3].event
        else {
            return XCTFail("Events drained out of order: \(sink.received)")
        }
    }

    @MainActor
    func testWindowConstraintsResolvedDrainsInOrderWithoutCoalescing() {
        let intake = EventIntake()
        let sink = RecordingSink()
        intake.open(sink: sink)
        defer { intake.close() }

        let fact = WindowConstraintsFact(
            token: WindowToken(pid: 42, windowId: 7),
            constraints: .fixed(size: CGSize(width: 320, height: 240))
        )
        intake.enqueue(.appActivated(pid: 42))
        intake.enqueue(.windowConstraintsResolved(fact))
        intake.enqueue(.windowConstraintsResolved(fact))
        intake.drainNow()

        let resolvedTokens = sink.received.compactMap { stamped -> WindowToken? in
            if case let .windowConstraintsResolved(resolved) = stamped.event {
                return resolved.token
            }
            return nil
        }
        XCTAssertEqual(resolvedTokens, [fact.token, fact.token])
        XCTAssertEqual(sink.received.count, 3)
    }

    @MainActor
    func testCGSFrameEventsCoalescePerWindowAndClearOnDestroy() {
        let intake = EventIntake()
        let sink = RecordingSink()
        intake.open(sink: sink)
        defer { intake.close() }

        intake.enqueue(.cgs(.frameChanged(windowId: 7)))
        intake.enqueue(.cgs(.frameChanged(windowId: 7)))
        intake.enqueue(.cgs(.frameChanged(windowId: 8)))
        intake.enqueue(.cgs(.destroyed(windowId: 7, spaceId: 1)))
        intake.drainNow()

        let frames = sink.received.compactMap { stamped -> UInt32? in
            if case let .cgs(.frameChanged(windowId)) = stamped.event {
                return windowId
            }
            return nil
        }
        XCTAssertEqual(frames, [8])
        XCTAssertEqual(sink.received.count, 2)
    }

    @MainActor
    func testMouseMovedCoalescesLatestPayloadInPlace() {
        let intake = EventIntake()
        let sink = RecordingSink()
        intake.open(sink: sink)
        defer { intake.close() }

        intake.enqueue(
            .mouseMoved(
                location: CGPoint(x: 10, y: 10),
                modifiersRawValue: 1,
                windowIdUnderPointer: 7
            )
        )
        intake.enqueue(
            .mouseMoved(
                location: CGPoint(x: 20, y: 20),
                modifiersRawValue: 2,
                windowIdUnderPointer: 8
            )
        )
        intake.enqueue(.appActivated(pid: 1))
        intake.drainNow()

        XCTAssertEqual(sink.received.count, 2)
        guard case let .mouseMoved(
            location,
            modifiersRawValue,
            windowIdUnderPointer
        ) = sink.received[0].event else {
            return XCTFail("Expected coalesced mouseMoved first: \(sink.received)")
        }
        XCTAssertEqual(location, CGPoint(x: 20, y: 20))
        XCTAssertEqual(modifiersRawValue, 2)
        XCTAssertEqual(windowIdUnderPointer, 8)
        guard case .appActivated = sink.received[1].event else {
            return XCTFail("Expected appActivated second: \(sink.received)")
        }
    }

    @MainActor
    func testNonCoalescibleEventBarsDraggedCoalescingAcrossIt() {
        let intake = EventIntake()
        let sink = RecordingSink()
        intake.open(sink: sink)
        defer { intake.close() }

        intake.enqueue(.mouseDragged(button: .left, location: CGPoint(x: 10, y: 10)))
        intake.enqueue(.hotkeyCommand(.focusPrevious))
        intake.enqueue(.mouseDragged(button: .left, location: CGPoint(x: 20, y: 20)))
        intake.drainNow()

        XCTAssertEqual(sink.received.count, 3)
        guard case let .mouseDragged(_, firstLocation) = sink.received[0].event,
              case .hotkeyCommand(.focusPrevious) = sink.received[1].event,
              case let .mouseDragged(_, secondLocation) = sink.received[2].event
        else {
            return XCTFail("Expected dragged, command, dragged in order: \(sink.received)")
        }
        XCTAssertEqual(firstLocation, CGPoint(x: 10, y: 10))
        XCTAssertEqual(secondLocation, CGPoint(x: 20, y: 20))
    }

    @MainActor
    func testDraggedCoalescesToLatestLocationWithoutBarrier() {
        let intake = EventIntake()
        let sink = RecordingSink()
        intake.open(sink: sink)
        defer { intake.close() }

        intake.enqueue(.mouseDragged(button: .left, location: CGPoint(x: 10, y: 10)))
        intake.enqueue(.mouseDragged(button: .left, location: CGPoint(x: 20, y: 20)))
        intake.drainNow()

        XCTAssertEqual(sink.received.count, 1)
        guard case let .mouseDragged(_, location) = sink.received[0].event else {
            return XCTFail("Expected a single coalesced mouseDragged: \(sink.received)")
        }
        XCTAssertEqual(location, CGPoint(x: 20, y: 20))
    }

    @MainActor
    func testMovedDraggedMovedDrainsInArrivalOrder() {
        let intake = EventIntake()
        let sink = RecordingSink()
        intake.open(sink: sink)
        defer { intake.close() }

        intake.enqueue(
            .mouseMoved(
                location: CGPoint(x: 10, y: 10),
                modifiersRawValue: 0,
                windowIdUnderPointer: nil
            )
        )
        intake.enqueue(.mouseDragged(button: .left, location: CGPoint(x: 20, y: 20)))
        intake.enqueue(
            .mouseMoved(
                location: CGPoint(x: 30, y: 30),
                modifiersRawValue: 0,
                windowIdUnderPointer: nil
            )
        )
        intake.drainNow()

        XCTAssertEqual(sink.received.count, 3)
        guard case let .mouseMoved(firstLocation, _, _) = sink.received[0].event,
              case let .mouseDragged(_, draggedLocation) = sink.received[1].event,
              case let .mouseMoved(lastLocation, _, _) = sink.received[2].event
        else {
            return XCTFail("Expected moved, dragged, moved in order: \(sink.received)")
        }
        XCTAssertEqual(firstLocation, CGPoint(x: 10, y: 10))
        XCTAssertEqual(draggedLocation, CGPoint(x: 20, y: 20))
        XCTAssertEqual(lastLocation, CGPoint(x: 30, y: 30))
    }

    @MainActor
    func testAlternatingDragButtonsDrainInArrivalOrder() {
        let intake = EventIntake()
        let sink = RecordingSink()
        intake.open(sink: sink)
        defer { intake.close() }

        intake.enqueue(.mouseDragged(button: .left, location: CGPoint(x: 10, y: 10)))
        intake.enqueue(.mouseDragged(button: .right, location: CGPoint(x: 20, y: 20)))
        intake.enqueue(.mouseDragged(button: .left, location: CGPoint(x: 30, y: 30)))
        intake.drainNow()

        XCTAssertEqual(sink.received.count, 3)
        guard case let .mouseDragged(firstButton, firstLocation) = sink.received[0].event,
              case let .mouseDragged(secondButton, secondLocation) = sink.received[1].event,
              case let .mouseDragged(thirdButton, thirdLocation) = sink.received[2].event
        else {
            return XCTFail("Expected left, right, left drags in order: \(sink.received)")
        }
        XCTAssertEqual(firstButton, .left)
        XCTAssertEqual(firstLocation, CGPoint(x: 10, y: 10))
        XCTAssertEqual(secondButton, .right)
        XCTAssertEqual(secondLocation, CGPoint(x: 20, y: 20))
        XCTAssertEqual(thirdButton, .left)
        XCTAssertEqual(thirdLocation, CGPoint(x: 30, y: 30))
    }

    @MainActor
    func testCGSFrameChangedBarsDraggedCoalescingAcrossIt() {
        let intake = EventIntake()
        let sink = RecordingSink()
        intake.open(sink: sink)
        defer { intake.close() }

        intake.enqueue(.mouseDragged(button: .left, location: CGPoint(x: 10, y: 10)))
        intake.enqueue(.cgs(.frameChanged(windowId: 7)))
        intake.enqueue(.mouseDragged(button: .left, location: CGPoint(x: 20, y: 20)))
        intake.drainNow()

        XCTAssertEqual(sink.received.count, 3)
        guard case let .mouseDragged(_, firstLocation) = sink.received[0].event,
              case .cgs(.frameChanged) = sink.received[1].event,
              case let .mouseDragged(_, secondLocation) = sink.received[2].event
        else {
            return XCTFail("Expected dragged, frameChanged, dragged in order: \(sink.received)")
        }
        XCTAssertEqual(firstLocation, CGPoint(x: 10, y: 10))
        XCTAssertEqual(secondLocation, CGPoint(x: 20, y: 20))
    }

    @MainActor
    func testScrollAccumulatesSameAxisAndSplitsOnFlip() {
        let intake = EventIntake()
        let sink = RecordingSink()
        intake.open(sink: sink)
        defer { intake.close() }

        intake.enqueue(.mouseScroll(scroll(deltaY: 5)))
        intake.enqueue(.mouseScroll(scroll(deltaY: 3)))
        intake.enqueue(.mouseScroll(scroll(deltaY: -2)))
        intake.drainNow()

        let deltas = sink.received.compactMap { stamped -> CGFloat? in
            if case let .mouseScroll(payload) = stamped.event {
                return payload.deltaY
            }
            return nil
        }
        XCTAssertEqual(deltas, [8, -2])
    }

    private func scroll(deltaY: CGFloat) -> MouseScrollIntake {
        MouseScrollIntake(
            location: .zero,
            deltaX: 0,
            deltaY: deltaY,
            momentumPhase: 0,
            phase: 0,
            modifiersRawValue: 0
        )
    }

    private final class FakeWindowSystem {
        var focusedWindowIdByPid: [pid_t: Int] = [:]
        var staleFocusedWindowIds: [Int] = []
    }

    @MainActor
    private struct ReplayScenario {
        let controller: WMController
        let system: FakeWindowSystem
        let tokenA: WindowToken
        let tokenB: WindowToken
        let workspaceId: WorkspaceDescriptor.ID

        func drainToQuiescence() {
            var iterations = 0
            while controller.eventIntake.hasPendingEvents, iterations < 64 {
                controller.eventIntake.drainNow()
                iterations += 1
            }
        }

        func committedState() -> String {
            let focused = controller.workspaceManager.focusedToken?.windowId ?? -1
            let intents = controller.intentLedger.entries
                .filter { $0.kind.isFocusWindow }
                .map { intent in
                    "\(intent.kind.focusTargetToken?.windowId ?? -1):\(intent.phase)"
                }
                .joined(separator: ",")
            return "focused=\(focused) intents=[\(intents)]"
        }

        func tearDown() {
            controller.deadlineWheel.stop()
            controller.eventIntake.close()
        }
    }

    @MainActor
    func testStaleActivationFactsCannotCancelNewerFocusIntent() throws {
        let pid: pid_t = 100
        let staleFacts = IntakeEvent.activationFactsResolved(
            ActivationFacts(
                pid: pid,
                source: .focusedWindowChanged,
                origin: .external,
                requestedAtSeq: 0,
                focusedWindow: FocusedWindowFact(
                    axRef: AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 42),
                    isFullscreen: false,
                    isSystemModalSurface: false
                )
            )
        )
        let observationStream: [IntakeEvent] = [
            .cgs(.frontAppChanged(pid: pid)),
            .axFocusedWindowChanged(pid: pid)
        ]

        var outcomes: [String] = []
        for events in Self.interleavings([staleFacts], observationStream) {
            let scenario = try makeScenario(pid: pid)
            for event in events {
                scenario.controller.eventIntake.enqueue(event)
            }
            scenario.drainToQuiescence()
            XCTAssertEqual(scenario.controller.workspaceManager.focusedToken, scenario.tokenB)
            outcomes.append(scenario.committedState())
            scenario.tearDown()
        }

        XCTAssertEqual(Set(outcomes).count, 1, "Interleavings diverged: \(outcomes)")
    }

    @MainActor
    func testStaleFocusEchoOfConfirmedIntentDoesNotPreemptNewerIntent() throws {
        let pid: pid_t = 100
        let echoStream: [IntakeEvent] = [
            .axFocusedWindowChanged(pid: pid),
            .axFocusedWindowChanged(pid: pid)
        ]
        let hintStream: [IntakeEvent] = [
            .cgs(.frontAppChanged(pid: pid))
        ]

        var outcomes: [String] = []
        for events in Self.interleavings(echoStream, hintStream) {
            let scenario = try makeScenario(pid: pid)
            scenario.system.staleFocusedWindowIds = [scenario.tokenA.windowId]
            for event in events {
                scenario.controller.eventIntake.enqueue(event)
            }
            scenario.drainToQuiescence()
            XCTAssertEqual(scenario.controller.workspaceManager.focusedToken, scenario.tokenB)
            let newestIntentForB = scenario.controller.intentLedger.entries
                .last { $0.kind.focusTargetToken == scenario.tokenB }
            XCTAssertEqual(newestIntentForB?.phase, .confirmed)
            outcomes.append(scenario.committedState())
            scenario.tearDown()
        }

        XCTAssertEqual(Set(outcomes).count, 1, "Interleavings diverged: \(outcomes)")
    }

    @MainActor
    func testSystemModalFocusSuppressesBorderAndClearsOnNormalFocus() throws {
        let pid: pid_t = 100
        let scenario = try makeScenario(pid: pid)
        defer { scenario.tearDown() }
        let controller = scenario.controller
        let system = scenario.system

        var reportSystemModal = true
        controller.factResolver.factProvider = { pid in
            guard let windowId = system.focusedWindowIdByPid[pid] else { return nil }
            return FocusedWindowFact(
                axRef: AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                isFullscreen: false,
                isSystemModalSurface: reportSystemModal
            )
        }

        system.focusedWindowIdByPid[pid] = scenario.tokenB.windowId
        controller.eventIntake.enqueue(.axFocusedWindowChanged(pid: pid))
        scenario.drainToQuiescence()

        XCTAssertEqual(controller.workspaceManager.systemModalFocusToken, scenario.tokenB)
        XCTAssertEqual(WorldView(controller: controller).systemModalFocusToken, scenario.tokenB)
        XCTAssertNil(SurfaceDerivation.deriveBorder(world: WorldView(controller: controller)))

        reportSystemModal = false
        system.focusedWindowIdByPid[pid] = scenario.tokenA.windowId
        controller.eventIntake.enqueue(.axFocusedWindowChanged(pid: pid))
        scenario.drainToQuiescence()

        XCTAssertNil(controller.workspaceManager.systemModalFocusToken)
    }

    @MainActor
    func testStaleSystemModalFocusTokenDoesNotSuppressDifferentRenderableToken() throws {
        let pid: pid_t = 100
        let scenario = try makeScenario(pid: pid)
        defer { scenario.tearDown() }
        let controller = scenario.controller
        let system = scenario.system

        system.focusedWindowIdByPid[pid] = scenario.tokenB.windowId
        controller.eventIntake.enqueue(.axFocusedWindowChanged(pid: pid))
        scenario.drainToQuiescence()

        controller.workspaceManager.setSystemModalFocus(scenario.tokenA)
        let world = WorldView(controller: controller, borderFrameResolver: { windowId in
            windowId == scenario.tokenB.windowId ? CGRect(x: 0, y: 0, width: 200, height: 150) : nil
        })

        XCTAssertEqual(controller.workspaceManager.renderableFocusToken, scenario.tokenB)
        XCTAssertEqual(world.systemModalFocusToken, scenario.tokenA)
        XCTAssertNotNil(SurfaceDerivation.deriveBorder(world: world))
    }

    @MainActor
    func testDisabledBorderConfigYieldsNoBorder() throws {
        let pid: pid_t = 100
        let scenario = try makeScenario(pid: pid)
        defer { scenario.tearDown() }
        let controller = scenario.controller

        scenario.system.focusedWindowIdByPid[pid] = scenario.tokenB.windowId
        controller.eventIntake.enqueue(.axFocusedWindowChanged(pid: pid))
        scenario.drainToQuiescence()

        let frame = CGRect(x: 0, y: 0, width: 200, height: 150)
        let enabledWorld = WorldView(controller: controller, borderFrameResolver: { _ in frame })
        let border = try XCTUnwrap(SurfaceDerivation.deriveBorder(world: enabledWorld))
        XCTAssertEqual(border.windowId, scenario.tokenB.windowId)
        XCTAssertEqual(border.frame, frame)

        controller.settings.bordersEnabled = false
        let disabledWorld = WorldView(controller: controller, borderFrameResolver: { _ in frame })
        XCTAssertNil(SurfaceDerivation.deriveBorder(world: disabledWorld))
    }

    @MainActor
    func testZeroSizedBorderFrameYieldsNoBorder() throws {
        let pid: pid_t = 100
        let scenario = try makeScenario(pid: pid)
        defer { scenario.tearDown() }
        let controller = scenario.controller

        scenario.system.focusedWindowIdByPid[pid] = scenario.tokenB.windowId
        controller.eventIntake.enqueue(.axFocusedWindowChanged(pid: pid))
        scenario.drainToQuiescence()

        let world = WorldView(controller: controller, borderFrameResolver: { _ in .zero })
        XCTAssertNil(SurfaceDerivation.deriveBorder(world: world))
    }

    @MainActor
    private func makeScenario(pid: pid_t) throws -> ReplayScenario {
        let system = FakeWindowSystem()
        let controller = WMController(
            settings: Self.settingsStore(),
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    system.focusedWindowIdByPid[pid] = Int(windowId)
                },
                raiseWindow: { _ in }
            )
        )
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()

        let tokenA = try addNiriWindow(controller, pid: pid, windowId: 42, workspaceId: workspaceId)
        let tokenB = try addNiriWindow(controller, pid: pid, windowId: 43, workspaceId: workspaceId)

        controller.factResolver.factProvider = { pid in
            let windowId: Int?
            if system.staleFocusedWindowIds.isEmpty {
                windowId = system.focusedWindowIdByPid[pid]
            } else {
                windowId = system.staleFocusedWindowIds.removeFirst()
            }
            guard let windowId else { return nil }
            return FocusedWindowFact(
                axRef: AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                isFullscreen: false,
                isSystemModalSurface: false
            )
        }
        controller.hasStartedServices = true
        controller.eventIntake.open(sink: controller.eventInterpreter)

        let scenario = ReplayScenario(
            controller: controller,
            system: system,
            tokenA: tokenA,
            tokenB: tokenB,
            workspaceId: workspaceId
        )

        controller.focusWindow(tokenA)
        controller.eventIntake.enqueue(.axFocusedWindowChanged(pid: pid))
        scenario.drainToQuiescence()
        XCTAssertEqual(controller.workspaceManager.focusedToken, tokenA)

        controller.focusWindow(tokenB)
        return scenario
    }

    @MainActor
    private func addNiriWindow(
        _ controller: WMController,
        pid: pid_t,
        windowId: Int,
        workspaceId: WorkspaceDescriptor.ID
    ) throws -> WindowToken {
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        let node = try XCTUnwrap(
            controller.niriEngine?.addWindow(
                token: token,
                to: workspaceId,
                afterSelection: nil
            )
        )
        let frame = CGRect(x: 0, y: 0, width: 200, height: 150)
        node.frame = frame
        node.renderedFrame = frame
        return token
    }

    private static func interleavings(_ a: [IntakeEvent], _ b: [IntakeEvent]) -> [[IntakeEvent]] {
        if a.isEmpty { return [b] }
        if b.isEmpty { return [a] }
        var result: [[IntakeEvent]] = []
        for merged in interleavings(Array(a.dropFirst()), b) {
            result.append([a[0]] + merged)
        }
        for merged in interleavings(a, Array(b.dropFirst())) {
            result.append([b[0]] + merged)
        }
        return result
    }

    @MainActor
    private static func settingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMReplayTests-\(UUID().uuidString)", isDirectory: true)
        return SettingsStore(
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
    }
}
