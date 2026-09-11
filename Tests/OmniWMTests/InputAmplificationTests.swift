// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class InputAmplificationTests: XCTestCase {
    func testMultitouchSourceExistsOnlyWhileGestureFeatureIsEnabled() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "DynamicMultitouch")
        controller.settings.gestures.scrollEnabled = false
        controller.settings.gestures.workspaceSwipeEnabled = false
        controller.hasStartedServices = true
        let handler = controller.mouseEventHandler
        var sourceCreations = 0
        handler.multitouchSourceFactory = {
            sourceCreations += 1
            return MultitouchGestureSource(operations: nil)
        }

        handler.reconcileMultitouchSource()
        XCTAssertEqual(sourceCreations, 0)
        XCTAssertNil(handler.multitouchDiagnosticsSnapshot)

        controller.settings.gestures.workspaceSwipeEnabled = true
        handler.reconcileMultitouchSource()
        XCTAssertEqual(sourceCreations, 1)
        XCTAssertEqual(handler.multitouchDiagnosticsSnapshot?.state, .unavailable)

        controller.settings.gestures.workspaceSwipeEnabled = false
        handler.reconcileMultitouchSource()
        XCTAssertNil(handler.multitouchDiagnosticsSnapshot)
        XCTAssertNil(MultitouchGestureSource.shared)
        controller.hasStartedServices = false
    }

    func testGestureAvailabilityCallbackOnlyFiresForAggregateTransitions() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "GestureAvailability")
        let settings = controller.settings
        settings.gestures.scrollEnabled = false
        settings.gestures.workspaceSwipeEnabled = false
        var states: [Bool] = []
        settings.onTrackpadGestureAvailabilityChanged = { states.append($0) }

        settings.gestures.scrollEnabled = true
        settings.gestures.workspaceSwipeEnabled = true
        settings.gestures.scrollEnabled = false
        settings.gestures.workspaceSwipeEnabled = false

        XCTAssertEqual(states, [true, false])
    }

    func testTrackpadScrollDoesNotEnterEventIntake() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "TrackpadScrollIntake")
        controller.eventIntake.open(sink: controller.eventInterpreter)
        defer { controller.eventIntake.close() }
        let initialSequence = controller.eventIntake.lastSeq

        _ = controller.mouseEventHandler.receiveTapScrollWheel(MouseScrollIntake(
            location: .zero,
            deltaX: 1,
            deltaY: 2,
            momentumPhase: 0,
            phase: CGScrollPhase.changed.rawValue,
            modifiersRawValue: 0
        ))
        XCTAssertEqual(controller.eventIntake.lastSeq, initialSequence)

        _ = controller.mouseEventHandler.receiveTapScrollWheel(MouseScrollIntake(
            location: .zero,
            deltaX: 1,
            deltaY: 2,
            momentumPhase: 0,
            phase: 0,
            modifiersRawValue: 0
        ))
        XCTAssertEqual(controller.eventIntake.lastSeq, initialSequence + 1)
    }
}
