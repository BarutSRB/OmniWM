// SPDX-License-Identifier: GPL-2.0-only
import CoreGraphics
import Foundation
import Testing

@testable import OmniWM

@Suite(.serialized) @MainActor struct EventTapTeardownTests {
    struct ScheduledTapFixture {
        let tap: CFMachPort
        let runLoopSource: CFRunLoopSource
    }

    @Test func tearDownDisablesUnschedulesInvalidatesAndClearsReferences() throws {
        var tap: CFMachPort? = try #require(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
        var runLoopSource: CFRunLoopSource? = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        var operations: [String] = []

        let teardownOperations = EventTapTeardownOperations(
            disableTap: { _ in operations.append("disable") },
            removeRunLoopSource: { _, _, _ in operations.append("remove-source") },
            invalidateTap: { _ in operations.append("invalidate") }
        )

        EventTapTeardown.tearDown(
            tap: &tap,
            runLoopSource: &runLoopSource,
            operations: teardownOperations
        )

        #expect(operations == ["disable", "remove-source", "invalidate"])
        #expect(tap == nil)
        #expect(runLoopSource == nil)
    }

    @Test func liveTearDownInvalidatesMachPortAndUnschedulesRunLoopSource() throws {
        let fixture = try makeScheduledTapFixture()
        var tap: CFMachPort? = fixture.tap
        var runLoopSource: CFRunLoopSource? = fixture.runLoopSource

        #expect(CFMachPortIsValid(fixture.tap))
        #expect(CFRunLoopContainsSource(CFRunLoopGetMain(), fixture.runLoopSource, .commonModes))

        EventTapTeardown.tearDown(tap: &tap, runLoopSource: &runLoopSource)

        expectInvalidatedAndUnscheduled(fixture)
        #expect(tap == nil)
        #expect(runLoopSource == nil)
    }

    @Test func mouseEventHandlerCleanupInvalidatesMouseAndGestureTaps() throws {
        let controller = makeLayoutPlanTestController()
        let handler = MouseEventHandler(controller: controller)
        let mouseFixture = try makeScheduledTapFixture()
        let gestureFixture = try makeScheduledTapFixture()
        handler.state.eventTap = mouseFixture.tap
        handler.state.runLoopSource = mouseFixture.runLoopSource
        handler.state.gestureTap = gestureFixture.tap
        handler.state.gestureRunLoopSource = gestureFixture.runLoopSource

        handler.cleanup()

        expectInvalidatedAndUnscheduled(mouseFixture)
        expectInvalidatedAndUnscheduled(gestureFixture)
        #expect(handler.state.eventTap == nil)
        #expect(handler.state.runLoopSource == nil)
        #expect(handler.state.gestureTap == nil)
        #expect(handler.state.gestureRunLoopSource == nil)
    }

    @Test func mouseWarpHandlerCleanupInvalidatesWarpTap() throws {
        let controller = makeLayoutPlanTestController()
        let handler = MouseWarpHandler(controller: controller)
        let fixture = try makeScheduledTapFixture()
        handler.state.eventTap = fixture.tap
        handler.state.runLoopSource = fixture.runLoopSource

        handler.cleanup()

        expectInvalidatedAndUnscheduled(fixture)
        #expect(handler.state.eventTap == nil)
        #expect(handler.state.runLoopSource == nil)
    }

    @Test func secureInputMonitorStopInvalidatesSecureInputTap() throws {
        let monitor = SecureInputMonitor()
        let fixture = try makeScheduledTapFixture()
        monitor.secureInputStateProviderForTests = { false }
        monitor.eventTapInstallerForTests = { (tap: fixture.tap, runLoopSource: fixture.runLoopSource) }

        monitor.start { _ in }
        monitor.stop()

        expectInvalidatedAndUnscheduled(fixture)
    }

    private func makeScheduledTapFixture() throws -> ScheduledTapFixture {
        let tap = try #require(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
        let source = try #require(CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0))
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return ScheduledTapFixture(tap: tap, runLoopSource: source)
    }

    private func expectInvalidatedAndUnscheduled(_ fixture: ScheduledTapFixture) {
        #expect(!CFMachPortIsValid(fixture.tap))
        #expect(!CFRunLoopContainsSource(CFRunLoopGetMain(), fixture.runLoopSource, .commonModes))
    }
}
