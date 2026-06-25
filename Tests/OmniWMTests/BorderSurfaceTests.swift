// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics
@testable import OmniWM
import XCTest

final class BorderSurfaceTests: XCTestCase {
    @MainActor
    private final class BorderOperationsRecorder {
        var createdWindowCount = 0
        var releasedCount = 0
        var shapeCount = 0
        var flushCount = 0
        var moveCount = 0
        var moveAndOrderCount = 0
        var hideCount = 0
        var nextWindowId: UInt32 = 1001
        var contextProvider: @MainActor () -> CGContext? = { BorderOperationsRecorder.makeContext() }

        var orderingCount: Int {
            moveCount + moveAndOrderCount
        }

        func operations() -> BorderWindow.Operations {
            BorderWindow.Operations(
                createBorderWindow: { [weak self] _ in
                    guard let self else { return 0 }
                    createdWindowCount += 1
                    return nextWindowId
                },
                releaseBorderWindow: { [weak self] _ in self?.releasedCount += 1 },
                configureWindow: { _, _, _ in },
                setWindowTags: { _, _ in },
                createWindowContext: { [weak self] _ in self?.contextProvider() },
                setWindowShape: { [weak self] _, _ in self?.shapeCount += 1 },
                flushWindow: { [weak self] _ in self?.flushCount += 1 },
                transactionMove: { [weak self] _, _ in self?.moveCount += 1 },
                transactionMoveAndOrder: { [weak self] _, _, _, _, _ in self?.moveAndOrderCount += 1 },
                transactionHide: { [weak self] _ in self?.hideCount += 1 },
                backingScaleForFrame: { _ in 2.0 }
            )
        }

        static func makeContext() -> CGContext? {
            CGContext(
                data: nil,
                width: 8,
                height: 8,
                bitsPerComponent: 8,
                bytesPerRow: 32,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }
    }

    @MainActor
    private func makeApplier(_ recorder: BorderOperationsRecorder) -> BorderSurfaceApplier {
        BorderSurfaceApplier(borderWindowOperations: recorder.operations(), cornerRadiusProvider: { _ in nil })
    }

    private let frame = CGRect(x: 10, y: 10, width: 200, height: 150)
    private let configRed = BorderConfig(enabled: true, width: 4, color: .systemRed)
    private let configBlue = BorderConfig(enabled: true, width: 4, color: .systemBlue)

    private func desired(_ config: BorderConfig, windowId: Int = 77) -> DesiredBorderSurface {
        DesiredBorderSurface(windowId: windowId, frame: frame, config: config)
    }

    @MainActor
    func testApplyCreatesAndRegistersBorder() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        let applied = applier.apply(desired(configRed), forceOrdering: false)

        XCTAssertTrue(applied)
        XCTAssertEqual(recorder.createdWindowCount, 1)
        XCTAssertTrue(SurfaceCoordinator.shared.contains(windowNumber: Int(recorder.nextWindowId)))
    }

    @MainActor
    func testApplyNilHidesAndUnregisters() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        let hidden = applier.apply(nil, forceOrdering: false)

        XCTAssertTrue(hidden)
        XCTAssertEqual(recorder.hideCount, 1)
        XCTAssertFalse(SurfaceCoordinator.shared.contains(windowNumber: Int(recorder.nextWindowId)))
    }

    @MainActor
    func testRepeatedIdenticalApplyIsNoOp() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        let flushesAfterFirst = recorder.flushCount
        let orderingAfterFirst = recorder.orderingCount

        _ = applier.apply(desired(configRed), forceOrdering: false)

        XCTAssertEqual(recorder.flushCount, flushesAfterFirst)
        XCTAssertEqual(recorder.orderingCount, orderingAfterFirst)
    }

    @MainActor
    func testForceOrderingReordersWithoutRedraw() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        let flushesAfterFirst = recorder.flushCount
        let moveAndOrdersAfterFirst = recorder.moveAndOrderCount

        _ = applier.apply(desired(configRed), forceOrdering: true)

        XCTAssertEqual(recorder.flushCount, flushesAfterFirst)
        XCTAssertGreaterThan(recorder.moveAndOrderCount, moveAndOrdersAfterFirst)
    }

    @MainActor
    func testFailedCreateReturnsFalseThenRetries() {
        let recorder = BorderOperationsRecorder()
        recorder.nextWindowId = 0
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        let firstApplied = applier.apply(desired(configRed), forceOrdering: false)
        XCTAssertFalse(firstApplied)
        XCTAssertFalse(SurfaceCoordinator.shared.contains(windowNumber: 1001))

        recorder.nextWindowId = 1001
        let secondApplied = applier.apply(desired(configRed), forceOrdering: false)
        XCTAssertTrue(secondApplied)
        XCTAssertTrue(SurfaceCoordinator.shared.contains(windowNumber: 1001))
    }

    @MainActor
    func testConfigResyncedAfterHide() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        _ = applier.apply(nil, forceOrdering: false)
        let flushesBeforeReshow = recorder.flushCount

        _ = applier.apply(desired(configBlue), forceOrdering: false)

        XCTAssertGreaterThan(recorder.flushCount, flushesBeforeReshow)
    }

    @MainActor
    func testNilContextFailsCreation() {
        let recorder = BorderOperationsRecorder()
        recorder.contextProvider = { nil }
        let window = BorderWindow(config: configRed, operations: recorder.operations())

        let applied = window.update(frame: CGRect(x: 0, y: 0, width: 100, height: 80), targetWid: 55)

        XCTAssertFalse(applied)
        XCTAssertNil(window.windowId)
        XCTAssertEqual(recorder.releasedCount, 1)
    }

    @MainActor
    func testUpdateConfigDoesNotRedrawUntilNextUpdate() {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())
        let target = CGRect(x: 0, y: 0, width: 100, height: 80)

        _ = window.update(frame: target, targetWid: 55)
        let flushesAfterFirst = recorder.flushCount

        window.updateConfig(configBlue)
        XCTAssertEqual(recorder.flushCount, flushesAfterFirst)

        _ = window.update(frame: target, targetWid: 55)
        XCTAssertGreaterThan(recorder.flushCount, flushesAfterFirst)
    }

    @MainActor
    func testReshapeOnSizeChange() {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())

        _ = window.update(frame: CGRect(x: 0, y: 0, width: 100, height: 80), targetWid: 55)
        let shapesAfterFirst = recorder.shapeCount

        _ = window.update(frame: CGRect(x: 0, y: 0, width: 140, height: 80), targetWid: 55)
        XCTAssertGreaterThan(recorder.shapeCount, shapesAfterFirst)
    }

    @MainActor
    func testDestroyReleasesWindow() {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())

        _ = window.update(frame: CGRect(x: 0, y: 0, width: 100, height: 80), targetWid: 55)
        XCTAssertNotNil(window.windowId)

        window.destroy()
        XCTAssertNil(window.windowId)
        XCTAssertEqual(recorder.releasedCount, 1)
    }
}
