// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class DwindleResizeFocusedTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func makeTwoWindowEngine() -> (DwindleLayoutEngine, WorkspaceDescriptor.ID, WindowToken, WindowToken) {
        let engine = DwindleLayoutEngine()
        let ws = WorkspaceDescriptor.ID()
        let first = WindowToken(pid: 1, windowId: 1)
        let second = WindowToken(pid: 2, windowId: 2)
        _ = engine.addWindow(token: first, to: ws, activeWindowFrame: nil)
        _ = engine.addWindow(token: second, to: ws, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: ws, screen: screen)
        return (engine, ws, first, second)
    }

    func testGrowFirstChildIncreasesRatio() {
        let (engine, ws, first, _) = makeTwoWindowEngine()
        engine.setSelectedNode(engine.findNode(for: first, in: ws), in: ws)
        XCTAssertTrue(engine.resizeFocusedWindow(by: 0.1, in: ws))
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.1, accuracy: 1e-6)
    }

    func testShrinkFirstChildDecreasesRatio() {
        let (engine, ws, first, _) = makeTwoWindowEngine()
        engine.setSelectedNode(engine.findNode(for: first, in: ws), in: ws)
        XCTAssertTrue(engine.resizeFocusedWindow(by: -0.1, in: ws))
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 0.9, accuracy: 1e-6)
    }

    func testGrowSecondChildDecreasesRatio() {
        let (engine, ws, _, second) = makeTwoWindowEngine()
        engine.setSelectedNode(engine.findNode(for: second, in: ws), in: ws)
        XCTAssertTrue(engine.resizeFocusedWindow(by: 0.1, in: ws))
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 0.9, accuracy: 1e-6)
    }

    func testRatioClampsAtMaxAndStops() {
        let (engine, ws, first, _) = makeTwoWindowEngine()
        engine.setSelectedNode(engine.findNode(for: first, in: ws), in: ws)
        var changed = true
        for _ in 0 ..< 100 where changed {
            changed = engine.resizeFocusedWindow(by: 0.1, in: ws)
        }
        XCTAssertEqual(engine.root(for: ws)?.splitRatio ?? 0, 1.9, accuracy: 1e-6)
        XCTAssertFalse(engine.resizeFocusedWindow(by: 0.1, in: ws))
    }

    func testSingleWindowHasNoSplitToResize() {
        let engine = DwindleLayoutEngine()
        let ws = WorkspaceDescriptor.ID()
        let only = WindowToken(pid: 1, windowId: 1)
        _ = engine.addWindow(token: only, to: ws, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: ws, screen: screen)
        engine.setSelectedNode(engine.findNode(for: only, in: ws), in: ws)
        XCTAssertFalse(engine.resizeFocusedWindow(by: 0.1, in: ws))
    }
}
