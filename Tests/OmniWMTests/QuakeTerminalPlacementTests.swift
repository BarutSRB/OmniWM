// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class QuakeTerminalPlacementTests: XCTestCase {
    private let upperFrame = CGRect(x: 200, y: 1000, width: 1000, height: 900)
    private let lowerFrame = CGRect(x: 1200, y: -300, width: 800, height: 600)

    func testInitialPlacementReadsGeometryAfterAlphaAndWritesUndisplayedFrame() {
        let effects = Effects()
        let screen = Screen(frames: [upperFrame], effects: effects)
        let window = makeWindow(effects: effects)
        let placement = QuakeTerminalPlacement(position: .top, on: screen, widthPercent: 50, heightPercent: 40)
        XCTAssertTrue(effects.events.isEmpty)

        placement.setInitial(in: window)

        XCTAssertEqual(effects.events, [
            .alpha(0), .visibleFrame, .visibleFrame,
            .frame(CGRect(x: 450, y: 1900, width: 500, height: 360), display: false)
        ])
        XCTAssertFalse(window.isVisible)
    }

    func testFinalPlacementReadsGeometryAfterAlphaAndWritesDisplayedFrame() {
        let effects = Effects()
        let screen = Screen(frames: [upperFrame], effects: effects)
        let window = makeWindow(effects: effects)
        let placement = QuakeTerminalPlacement(position: .bottom, on: screen, widthPercent: 50, heightPercent: 40)
        XCTAssertTrue(effects.events.isEmpty)

        placement.setFinal(in: window)

        XCTAssertEqual(effects.events, [
            .alpha(1), .visibleFrame, .visibleFrame,
            .frame(CGRect(x: 450, y: 1000, width: 500, height: 360), display: true)
        ])
        XCTAssertFalse(window.isVisible)
    }

    func testReusingPlacementReadsUpdatedScreenGeometryAtEachApplication() {
        let effects = Effects()
        let screen = Screen(frames: [upperFrame, upperFrame, lowerFrame, lowerFrame], effects: effects)
        let window = makeWindow(effects: effects)
        let placement = QuakeTerminalPlacement(position: .center, on: screen, widthPercent: 50, heightPercent: 40)

        placement.setInitial(in: window)
        placement.setFinal(in: window)

        XCTAssertEqual(effects.events, [
            .alpha(0), .visibleFrame, .visibleFrame,
            .frame(CGRect(x: 450, y: 1270, width: 500, height: 360), display: false),
            .alpha(1), .visibleFrame, .visibleFrame,
            .frame(CGRect(x: 1400, y: -120, width: 400, height: 240), display: true)
        ])
        XCTAssertFalse(window.isVisible)
    }

    func testInitialPlacementUsesFirstScreenReadForSizeAndSecondForOrigin() {
        let effects = Effects()
        let screen = Screen(frames: [upperFrame, lowerFrame], effects: effects)
        let window = makeWindow(effects: effects)
        let placement = QuakeTerminalPlacement(position: .top, on: screen, widthPercent: 50, heightPercent: 40)

        placement.setInitial(in: window)

        XCTAssertEqual(effects.events, [
            .alpha(0), .visibleFrame, .visibleFrame,
            .frame(CGRect(x: 1350, y: 300, width: 500, height: 360), display: false)
        ])
    }

    func testFinalPlacementUsesFirstScreenReadForSizeAndSecondForOrigin() {
        let effects = Effects()
        let screen = Screen(frames: [upperFrame, lowerFrame], effects: effects)
        let window = makeWindow(effects: effects)
        let placement = QuakeTerminalPlacement(position: .bottom, on: screen, widthPercent: 50, heightPercent: 40)

        placement.setFinal(in: window)

        XCTAssertEqual(effects.events, [
            .alpha(1), .visibleFrame, .visibleFrame,
            .frame(CGRect(x: 1350, y: -300, width: 500, height: 360), display: true)
        ])
    }

    private func makeWindow(effects: Effects) -> RecordingWindow {
        let window = RecordingWindow(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        window.effects = effects
        return window
    }

    private enum Effect: Equatable {
        case alpha(CGFloat)
        case visibleFrame
        case frame(CGRect, display: Bool)
    }

    private final class Effects {
        var events: [Effect] = []
    }

    private final class Screen: NSScreen {
        private let frames: [CGRect]
        private let effects: Effects
        private var readIndex = 0

        init(frames: [CGRect], effects: Effects) {
            self.frames = frames
            self.effects = effects
            super.init()
        }

        override var visibleFrame: CGRect {
            effects.events.append(.visibleFrame)
            let frame = frames[min(readIndex, frames.count - 1)]
            readIndex += 1
            return frame
        }
    }

    private final class RecordingWindow: NSWindow {
        var effects: Effects?

        override var alphaValue: CGFloat {
            get { super.alphaValue }
            set {
                effects?.events.append(.alpha(newValue))
                super.alphaValue = newValue
            }
        }

        override func setFrame(_ frameRect: NSRect, display flag: Bool) {
            guard let effects else {
                super.setFrame(frameRect, display: flag)
                return
            }
            effects.events.append(.frame(frameRect, display: flag))
        }
    }
}
