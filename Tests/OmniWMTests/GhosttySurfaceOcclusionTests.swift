// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class GhosttySurfaceOcclusionTests: XCTestCase {
    func testInitialDetachedSurfaceIsInvisible() {
        var delivered: [Bool] = []
        let view = GhosttySurfaceView(occlusionHandlerForTests: { delivered.append($0) })

        XCTAssertNil(view.window)
        XCTAssertEqual(delivered, [false])
    }

    func testWindowOcclusionNotificationsUpdateAttachedSurface() {
        var delivered: [Bool] = []
        let view = GhosttySurfaceView(occlusionHandlerForTests: { delivered.append($0) })
        let window = makeWindow(visible: true)
        window.contentView?.addSubview(view)
        XCTAssertEqual(delivered.last, true)
        delivered.removeAll()

        window.simulatedOcclusionState = []
        postOcclusion(window)
        window.simulatedOcclusionState = [.visible]
        postOcclusion(window)

        XCTAssertEqual(delivered, [false, true])
        view.removeFromSuperview()
    }

    func testDetachmentStopsOldWindowNotificationsAndReattachmentUsesNewWindow() {
        var delivered: [Bool] = []
        let view = GhosttySurfaceView(occlusionHandlerForTests: { delivered.append($0) })
        let oldWindow = makeWindow(visible: true)
        let newWindow = makeWindow(visible: false)
        oldWindow.contentView?.addSubview(view)
        delivered.removeAll()

        view.removeFromSuperview()
        XCTAssertEqual(delivered, [false])
        postOcclusion(oldWindow)
        XCTAssertEqual(delivered, [false])
        newWindow.contentView?.addSubview(view)
        XCTAssertEqual(delivered, [false, false])
        postOcclusion(oldWindow)
        XCTAssertEqual(delivered, [false, false])
        newWindow.simulatedOcclusionState = [.visible]
        postOcclusion(newWindow)
        XCTAssertEqual(delivered, [false, false, true])
        view.removeFromSuperview()
    }

    private func makeWindow(visible: Bool) -> OcclusionWindow {
        let window = OcclusionWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        window.simulatedOcclusionState = visible ? [.visible] : []
        return window
    }

    private func postOcclusion(_ window: NSWindow) {
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }
}

@MainActor
private final class OcclusionWindow: NSWindow {
    var simulatedOcclusionState: NSWindow.OcclusionState = []

    override var occlusionState: NSWindow.OcclusionState {
        simulatedOcclusionState
    }
}
