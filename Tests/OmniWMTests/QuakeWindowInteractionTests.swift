// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class QuakeWindowInteractionTests: XCTestCase {
    func testDetachedEventsRemainTerminalEvents() throws {
        let interaction = QuakeWindowInteraction()
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let event = try mouseEvent(.leftMouseDown, at: .zero, modifiers: .option)

        XCTAssertFalse(interaction.handleMouseDown(event, in: view))
        XCTAssertFalse(interaction.handleMouseDrag(in: view))
        XCTAssertFalse(interaction.handleMouseUp(in: view, onFrameChanged: { _ in XCTFail("Unexpected frame change") }))
        interaction.finishMouseUp()
        XCTAssertFalse(interaction.isInteracting)
    }

    func testInteriorUnmodifiedEventsRemainTerminalEvents() throws {
        let (window, view) = makeSurface()
        let interaction = QuakeWindowInteraction()
        let event = try mouseEvent(.leftMouseDown, at: CGPoint(x: 200, y: 100), in: window)

        XCTAssertFalse(interaction.handleMouseDown(event, in: view))
        XCTAssertFalse(interaction.handleMouseDrag(in: view))
        XCTAssertFalse(interaction.handleMouseUp(in: view, onFrameChanged: nil))
        interaction.finishMouseUp()
        XCTAssertFalse(interaction.isInteracting)
        XCTAssertFalse(window.isVisible)
    }

    func testPerimeterResizeTakesPriorityOverOptionAndReportsBeforeReset() throws {
        let (window, view) = makeSurface()
        let down = try mouseEvent(.leftMouseDown, at: CGPoint(x: 1, y: 100), modifiers: .option, in: window)
        let up = try mouseEvent(.leftMouseUp, at: CGPoint(x: 1, y: 100), in: window)
        var deliveredFrames: [CGRect] = []
        var interactionDuringCallback: [Bool] = []
        view.onFrameChanged = { [weak view] frame in
            deliveredFrames.append(frame)
            interactionDuringCallback.append(view?.isInteracting == true)
        }
        defer { view.onFrameChanged = nil }

        view.mouseDown(with: down)
        XCTAssertTrue(view.isInteracting)
        var changedFrame = window.frame
        changedFrame.size.width += 20
        window.setFrame(changedFrame, display: false)
        view.mouseUp(with: up)

        XCTAssertEqual(deliveredFrames, [window.frame])
        XCTAssertEqual(interactionDuringCallback, [true])
        XCTAssertFalse(view.isInteracting)
        XCTAssertFalse(window.isVisible)
    }

    func testOptionMoveIgnoresSizeOnlyChanges() throws {
        let (window, view) = makeSurface()
        let down = try mouseEvent(.leftMouseDown, at: CGPoint(x: 200, y: 100), modifiers: .option, in: window)
        let up = try mouseEvent(.leftMouseUp, at: CGPoint(x: 200, y: 100), in: window)
        view.onFrameChanged = { _ in XCTFail("Size-only change must not count as a move") }
        defer { view.onFrameChanged = nil }

        view.mouseDown(with: down)
        XCTAssertTrue(view.isInteracting)
        var changedFrame = window.frame
        changedFrame.size.width += 20
        window.setFrame(changedFrame, display: false)
        view.mouseUp(with: up)

        XCTAssertFalse(view.isInteracting)
        XCTAssertFalse(window.isVisible)
    }

    func testMoveCallbackCanReenterAndFinalResetStillCompletes() throws {
        let (window, view) = makeSurface()
        let down = try mouseEvent(.leftMouseDown, at: CGPoint(x: 200, y: 100), modifiers: .option, in: window)
        let up = try mouseEvent(.leftMouseUp, at: CGPoint(x: 200, y: 100), in: window)
        var deliveredFrames: [CGRect] = []
        view.onFrameChanged = { [weak view] frame in
            deliveredFrames.append(frame)
            XCTAssertEqual(view?.isInteracting, true)
            view?.mouseDown(with: down)
            XCTAssertEqual(view?.isInteracting, true)
        }
        defer { view.onFrameChanged = nil }

        view.mouseDown(with: down)
        window.setFrameOrigin(CGPoint(x: window.frame.minX + 20, y: window.frame.minY))
        view.mouseUp(with: up)

        XCTAssertEqual(deliveredFrames, [window.frame])
        XCTAssertFalse(view.isInteracting)
        view.mouseUp(with: up)
        XCTAssertEqual(deliveredFrames.count, 1)
        XCTAssertFalse(window.isVisible)
    }

    func testUnchangedResizeFinishesWithoutReportingFrame() throws {
        let (window, view) = makeSurface()
        let down = try mouseEvent(.leftMouseDown, at: CGPoint(x: 1, y: 100), in: window)
        let up = try mouseEvent(.leftMouseUp, at: CGPoint(x: 1, y: 100), in: window)
        view.onFrameChanged = { _ in XCTFail("Unchanged frame must not be reported") }
        defer { view.onFrameChanged = nil }

        view.mouseDown(with: down)
        XCTAssertTrue(view.isInteracting)
        view.mouseUp(with: up)

        XCTAssertFalse(view.isInteracting)
        XCTAssertFalse(window.isVisible)
    }

    private func makeSurface() -> (NSWindow, GhosttySurfaceView) {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 400, height: 200),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        let view = GhosttySurfaceView(occlusionHandlerForTests: { _ in })
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        window.contentView?.addSubview(view)
        return (window, view)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at location: CGPoint,
        modifiers: NSEvent.ModifierFlags = [],
        in window: NSWindow? = nil
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: modifiers,
            timestamp: 1,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}
