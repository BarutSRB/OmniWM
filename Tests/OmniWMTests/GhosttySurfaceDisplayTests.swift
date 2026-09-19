// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import GhosttyKit
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class GhosttySurfaceDisplayTests: XCTestCase {
    func testAttachmentSynchronizesAnOrdinaryHostedLayerWithGhostty() {
        let recorder = DisplayRecorder()
        let view = makeSurface(recorder)
        let hostedLayer = view.layer
        let window = makeWindow(displayId: 11, scale: 2)

        window.contentView?.addSubview(view)
        defer { view.removeFromSuperview() }

        XCTAssertNil(view.ghosttySurface)
        XCTAssertTrue(view.layer === hostedLayer)
        XCTAssertEqual(view.layer?.contentsScale, 2)
        XCTAssertEqual(recorder.operations, [
            .display(11), .scale(2), .size(.init(widthPx: 800, heightPx: 400))
        ])
        XCTAssertGreaterThan(recorder.readCount, 0)
    }

    func testDetachedResizingWaitsForDestinationScaleAndFinalFrame() {
        let recorder = DisplayRecorder()
        let view = makeSurface(recorder)

        view.setFrameSize(NSSize(width: 600, height: 300))
        view.setFrameSize(NSSize(width: 731, height: 257))
        view.syncGhosttySurfaceSize()
        view.viewDidChangeBackingProperties()
        view.refreshDisplayStateForCurrentScreen()

        XCTAssertNil(view.window)
        XCTAssertEqual(recorder.readCount, 0)
        XCTAssertTrue(recorder.operations.isEmpty)

        let window = makeWindow(displayId: 22, scale: 2)
        window.contentView?.addSubview(view)
        defer { view.removeFromSuperview() }

        XCTAssertEqual(view.layer?.contentsScale, 2)
        XCTAssertEqual(recorder.operations, [
            .display(22), .scale(2), .size(.init(widthPx: 1462, heightPx: 514))
        ])
    }

    func testBackingScaleChangesInBothDirectionsWithUnchangedPointSize() {
        let recorder = DisplayRecorder()
        let view = makeSurface(recorder)
        let window = makeWindow(displayId: 11, scale: 1)
        window.contentView?.addSubview(view)
        defer { view.removeFromSuperview() }
        recorder.reset()

        window.simulatedScale = 2
        view.viewDidChangeBackingProperties()

        XCTAssertEqual(view.frame.size, NSSize(width: 400, height: 200))
        XCTAssertEqual(view.layer?.contentsScale, 2)
        XCTAssertEqual(recorder.operations, [
            .scale(2), .size(.init(widthPx: 800, heightPx: 400))
        ])
        recorder.reset()

        window.simulatedScale = 1
        postBackingChange(window)

        XCTAssertEqual(view.frame.size, NSSize(width: 400, height: 200))
        XCTAssertEqual(view.layer?.contentsScale, 1)
        XCTAssertEqual(recorder.operations, [
            .scale(1), .size(.init(widthPx: 400, heightPx: 200))
        ])
    }

    func testScreenThenBackingChangeDeduplicatesUnchangedWrites() {
        let recorder = DisplayRecorder()
        let view = makeSurface(recorder)
        let window = makeWindow(displayId: 11, scale: 1)
        window.contentView?.addSubview(view)
        defer { view.removeFromSuperview() }
        recorder.reset()

        window.simulatedDisplayId = 22
        postScreenChange(window)

        XCTAssertEqual(recorder.operations, [
            .display(22), .size(.init(widthPx: 400, heightPx: 200))
        ])
        window.simulatedScale = 2
        postBackingChange(window)

        let expected: [DisplayOperation] = [
            .display(22), .size(.init(widthPx: 400, heightPx: 200)),
            .scale(2), .size(.init(widthPx: 800, heightPx: 400))
        ]
        XCTAssertEqual(view.layer?.contentsScale, 2)
        XCTAssertEqual(recorder.operations, expected)

        postScreenChange(window)
        postBackingChange(window)
        view.viewDidChangeBackingProperties()
        view.syncGhosttySurfaceSize()

        XCTAssertEqual(recorder.operations, expected)
    }

    func testReattachmentStopsOldWindowNotifications() {
        let recorder = DisplayRecorder()
        let view = makeSurface(recorder)
        let oldWindow = makeWindow(displayId: 11, scale: 1)
        let newWindow = makeWindow(displayId: 22, scale: 2)
        oldWindow.contentView?.addSubview(view)
        view.removeFromSuperview()
        recorder.reset()

        postScreenChange(oldWindow)
        postBackingChange(oldWindow)
        XCTAssertEqual(recorder.readCount, 0)
        XCTAssertTrue(recorder.operations.isEmpty)

        newWindow.contentView?.addSubview(view)
        defer { view.removeFromSuperview() }
        XCTAssertEqual(recorder.operations, [
            .display(22), .scale(2), .size(.init(widthPx: 800, heightPx: 400))
        ])
        recorder.reset()

        newWindow.simulatedDisplayId = 33
        newWindow.simulatedScale = 1
        postScreenChange(oldWindow)
        postBackingChange(oldWindow)

        XCTAssertEqual(view.layer?.contentsScale, 2)
        XCTAssertEqual(recorder.readCount, 0)
        XCTAssertTrue(recorder.operations.isEmpty)

        postScreenChange(newWindow)
        XCTAssertEqual(view.layer?.contentsScale, 1)
        XCTAssertEqual(recorder.operations, [
            .display(33), .scale(1), .size(.init(widthPx: 400, heightPx: 200))
        ])
    }

    func testExplicitRevealRefreshResendsCurrentDisplayScaleAndSize() {
        let recorder = DisplayRecorder()
        let view = makeSurface(recorder)
        let window = makeWindow(displayId: 22, scale: 2)
        window.contentView?.addSubview(view)
        defer { view.removeFromSuperview() }
        recorder.reset()

        view.refreshDisplayStateForCurrentScreen()

        XCTAssertEqual(recorder.operations, [
            .display(22), .scale(2), .size(.init(widthPx: 800, heightPx: 400))
        ])
        XCTAssertEqual(view.layer?.contentsScale, 2)
        recorder.reset()
        postBackingChange(window)
        XCTAssertTrue(recorder.operations.isEmpty)
    }

    private func makeSurface(_ recorder: DisplayRecorder) -> GhosttySurfaceView {
        let hooks = GhosttySurfaceDisplayTestHooks(
            displayId: { ($0 as? DisplayWindow)?.simulatedDisplayId },
            readSize: {
                recorder.readCount += 1
                var size = ghostty_surface_size_s()
                size.cell_width_px = 8
                size.cell_height_px = 16
                return size
            },
            setDisplayId: { recorder.operations.append(.display($0)) },
            setContentScale: { recorder.operations.append(.scale($0)) },
            setSize: { recorder.operations.append(.size($0)) }
        )
        let view = GhosttySurfaceView(occlusionHandlerForTests: { _ in }, displayHooksForTests: hooks)
        view.layer = CALayer()
        view.wantsLayer = true
        view.setFrameSize(NSSize(width: 400, height: 200))
        return view
    }

    private func makeWindow(displayId: UInt32, scale: CGFloat) -> DisplayWindow {
        let window = DisplayWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        window.simulatedDisplayId = displayId
        window.simulatedScale = scale
        return window
    }

    private func postScreenChange(_ window: NSWindow) {
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
    }

    private func postBackingChange(_ window: NSWindow) {
        NotificationCenter.default.post(name: NSWindow.didChangeBackingPropertiesNotification, object: window)
    }
}

private enum DisplayOperation: Equatable {
    case display(UInt32)
    case scale(CGFloat)
    case size(GhosttySurfacePixelSize)
}

@MainActor
private final class DisplayRecorder {
    var operations: [DisplayOperation] = []
    var readCount = 0

    func reset() {
        operations.removeAll()
        readCount = 0
    }
}

@MainActor
private final class DisplayWindow: NSWindow {
    var simulatedDisplayId: UInt32 = 0
    var simulatedScale: CGFloat = 1

    override var backingScaleFactor: CGFloat {
        simulatedScale
    }
}
