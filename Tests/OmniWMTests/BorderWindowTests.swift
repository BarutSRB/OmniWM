// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import CoreGraphics
import Testing

@testable import OmniWM

@MainActor
private func makeBorderTestContext() -> CGContext? {
    CGContext(
        data: nil,
        width: 16,
        height: 16,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
}

@Suite struct BorderWindowTests {
    @Test @MainActor func moveOnlyUpdateSkipsRedrawAndReorder() {
        var reshapeFrames: [CGRect] = []
        var flushCount = 0
        var moveOnlyOrigins: [CGPoint] = []
        var orderedTargets: [UInt32] = []
        var orderedLevels: [Int32] = []

        let operations = BorderWindow.Operations(
            createBorderWindow: { _ in 900 },
            releaseBorderWindow: { _ in },
            configureWindow: { _, _, _ in },
            setWindowTags: { _, _ in },
            createWindowContext: { _ in makeBorderTestContext() },
            setWindowShape: { _, frame in reshapeFrames.append(frame) },
            flushWindow: { _ in flushCount += 1 },
            transactionMove: { _, origin in moveOnlyOrigins.append(origin) },
            transactionMoveAndOrder: { _, _, level, targetWid, _ in
                orderedLevels.append(level)
                orderedTargets.append(targetWid)
            },
            transactionHide: { _ in },
            backingScaleForFrame: { _ in 2.0 }
        )
        let borderWindow = BorderWindow(
            config: BorderConfig(enabled: true, width: 4, color: .systemBlue),
            operations: operations
        )

        let initialFrame = CGRect(x: 120, y: 90, width: 800, height: 600)
        borderWindow.update(frame: initialFrame, targetWid: 101)

        #expect(reshapeFrames.count == 1)
        #expect(flushCount == 1)
        #expect(moveOnlyOrigins.isEmpty)
        #expect(orderedTargets == [101])

        borderWindow.update(frame: initialFrame.offsetBy(dx: 40, dy: 24), targetWid: 101)

        #expect(reshapeFrames.count == 1)
        #expect(flushCount == 1)
        #expect(moveOnlyOrigins.count == 1)
        #expect(orderedTargets == [101])

        borderWindow.update(
            frame: CGRect(x: 160, y: 114, width: 820, height: 600),
            targetWid: 101
        )

        #expect(reshapeFrames.count == 2)
        #expect(flushCount == 2)
        #expect(moveOnlyOrigins.count == 2)
        #expect(orderedTargets == [101])
        #expect(orderedLevels == [3])
    }

    @Test @MainActor func hiddenBorderReordersOnNextShow() {
        var moveOnlyCount = 0
        var orderedTargets: [UInt32] = []
        var hideCount = 0

        let operations = BorderWindow.Operations(
            createBorderWindow: { _ in 901 },
            releaseBorderWindow: { _ in },
            configureWindow: { _, _, _ in },
            setWindowTags: { _, _ in },
            createWindowContext: { _ in makeBorderTestContext() },
            setWindowShape: { _, _ in },
            flushWindow: { _ in },
            transactionMove: { _, _ in moveOnlyCount += 1 },
            transactionMoveAndOrder: { _, _, _, targetWid, _ in orderedTargets.append(targetWid) },
            transactionHide: { _ in hideCount += 1 },
            backingScaleForFrame: { _ in 2.0 }
        )
        let borderWindow = BorderWindow(
            config: BorderConfig(enabled: true, width: 4, color: .systemBlue),
            operations: operations
        )

        let frame = CGRect(x: 80, y: 80, width: 640, height: 420)
        borderWindow.update(frame: frame, targetWid: 111)
        borderWindow.hide()
        borderWindow.update(frame: frame.offsetBy(dx: 12, dy: 0), targetWid: 111)

        #expect(moveOnlyCount == 0)
        #expect(orderedTargets == [111, 111])
        #expect(hideCount == 1)
    }

    @Test @MainActor func hiddenConfigChangeDoesNotReplayStaleTargetState() {
        var flushCount = 0
        var moveOnlyCount = 0
        var orderedTargets: [UInt32] = []
        var hideCount = 0

        let operations = BorderWindow.Operations(
            createBorderWindow: { _ in 903 },
            releaseBorderWindow: { _ in },
            configureWindow: { _, _, _ in },
            setWindowTags: { _, _ in },
            createWindowContext: { _ in makeBorderTestContext() },
            setWindowShape: { _, _ in },
            flushWindow: { _ in flushCount += 1 },
            transactionMove: { _, _ in moveOnlyCount += 1 },
            transactionMoveAndOrder: { _, _, _, targetWid, _ in orderedTargets.append(targetWid) },
            transactionHide: { _ in hideCount += 1 },
            backingScaleForFrame: { _ in 2.0 }
        )
        let borderWindow = BorderWindow(
            config: BorderConfig(enabled: true, width: 4, color: .systemBlue),
            operations: operations
        )

        let frame = CGRect(x: 100, y: 70, width: 700, height: 480)
        borderWindow.update(frame: frame, targetWid: 121)
        borderWindow.hide()
        borderWindow.updateConfig(
            BorderConfig(enabled: true, width: 10, color: .systemRed)
        )

        #expect(flushCount == 1)
        #expect(moveOnlyCount == 0)
        #expect(orderedTargets == [121])
        #expect(hideCount == 1)
    }

    @Test @MainActor func hiddenConfigChangeAppliesNewWidthAndTriggersRedrawOnNextShow() {
        var reshapeFrames: [CGRect] = []
        var flushCount = 0
        var orderedTargets: [UInt32] = []

        let operations = BorderWindow.Operations(
            createBorderWindow: { _ in 904 },
            releaseBorderWindow: { _ in },
            configureWindow: { _, _, _ in },
            setWindowTags: { _, _ in },
            createWindowContext: { _ in makeBorderTestContext() },
            setWindowShape: { _, frame in reshapeFrames.append(frame) },
            flushWindow: { _ in flushCount += 1 },
            transactionMove: { _, _ in },
            transactionMoveAndOrder: { _, _, _, targetWid, _ in orderedTargets.append(targetWid) },
            transactionHide: { _ in },
            backingScaleForFrame: { _ in 2.0 }
        )
        let borderWindow = BorderWindow(
            config: BorderConfig(enabled: true, width: 4, color: .systemBlue),
            operations: operations
        )

        let initialFrame = CGRect(x: 150, y: 110, width: 640, height: 360)
        borderWindow.update(frame: initialFrame, targetWid: 131)
        borderWindow.hide()
        borderWindow.updateConfig(
            BorderConfig(enabled: true, width: 10, color: .systemRed)
        )

        let nextFrame = initialFrame.offsetBy(dx: 32, dy: 18)
        borderWindow.update(frame: nextFrame, targetWid: 132)

        let expectedInset = -10.0 - 8.0
        let expectedFrameSize = nextFrame.insetBy(dx: expectedInset, dy: expectedInset)
            .roundedToPhysicalPixels(scale: 2.0)
            .size
        #expect(reshapeFrames.last?.size == expectedFrameSize)
        #expect(flushCount == 2)
        #expect(orderedTargets == [131, 132])
    }

    @Test @MainActor func reconfiguresExistingWindowWhenBackingScaleChanges() {
        var configureCalls: [(wid: UInt32, scale: Float)] = []
        var createCount = 0

        let operations = BorderWindow.Operations(
            createBorderWindow: { _ in
                createCount += 1
                return 902
            },
            releaseBorderWindow: { _ in },
            configureWindow: { wid, scale, _ in configureCalls.append((wid, scale)) },
            setWindowTags: { _, _ in },
            createWindowContext: { _ in makeBorderTestContext() },
            setWindowShape: { _, _ in },
            flushWindow: { _ in },
            transactionMove: { _, _ in },
            transactionMoveAndOrder: { _, _, _, _, _ in },
            transactionHide: { _ in },
            backingScaleForFrame: { frame in
                frame.midX < 1_000 ? 1.0 : 2.0
            }
        )
        let borderWindow = BorderWindow(
            config: BorderConfig(enabled: true, width: 4, color: .systemBlue),
            operations: operations
        )

        borderWindow.update(
            frame: CGRect(x: 80, y: 80, width: 640, height: 420),
            targetWid: 120
        )
        borderWindow.update(
            frame: CGRect(x: 1_280, y: 80, width: 640, height: 420),
            targetWid: 120
        )

        #expect(createCount == 1)
        #expect(configureCalls.map(\.wid) == [902, 902])
        #expect(configureCalls.map(\.scale) == [1.0, 2.0])
    }
}
