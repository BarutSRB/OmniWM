import AppKit
import CoreGraphics
@testable import OmniWM
import Testing

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

        let operations = BorderWindow.Operations(
            createBorderWindow: { _ in 900 },
            releaseBorderWindow: { _ in },
            configureWindow: { _, _, _ in },
            setWindowTags: { _, _ in },
            createWindowContext: { _ in makeBorderTestContext() },
            setWindowShape: { _, frame in reshapeFrames.append(frame) },
            flushWindow: { _ in flushCount += 1 },
            transactionMove: { _, origin in moveOnlyOrigins.append(origin) },
            transactionMoveAndOrder: { _, _, _, targetWid, _ in orderedTargets.append(targetWid) },
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
    }

    @Test @MainActor func forceOrderingReordersWithoutRedraw() {
        var reshapeFrames: [CGRect] = []
        var flushCount = 0
        var moveOnlyCount = 0
        var orderedTargets: [UInt32] = []

        let operations = BorderWindow.Operations(
            createBorderWindow: { _ in 903 },
            releaseBorderWindow: { _ in },
            configureWindow: { _, _, _ in },
            setWindowTags: { _, _ in },
            createWindowContext: { _ in makeBorderTestContext() },
            setWindowShape: { _, frame in reshapeFrames.append(frame) },
            flushWindow: { _ in flushCount += 1 },
            transactionMove: { _, _ in moveOnlyCount += 1 },
            transactionMoveAndOrder: { _, _, _, targetWid, _ in orderedTargets.append(targetWid) },
            transactionHide: { _ in },
            backingScaleForFrame: { _ in 2.0 }
        )
        let borderWindow = BorderWindow(
            config: BorderConfig(enabled: true, width: 4, color: .systemBlue),
            operations: operations
        )

        let frame = CGRect(x: 120, y: 90, width: 800, height: 600)
        borderWindow.update(frame: frame, targetWid: 101)
        borderWindow.update(frame: frame, targetWid: 101, forceOrdering: true)

        #expect(reshapeFrames.count == 1)
        #expect(flushCount == 1)
        #expect(moveOnlyCount == 0)
        #expect(orderedTargets == [101, 101])
    }

    @Test @MainActor func radiusChangeRedrawsWithoutReshape() {
        var reshapeFrames: [CGRect] = []
        var flushCount = 0
        var moveOnlyCount = 0
        var orderedTargets: [UInt32] = []

        let operations = BorderWindow.Operations(
            createBorderWindow: { _ in 907 },
            releaseBorderWindow: { _ in },
            configureWindow: { _, _, _ in },
            setWindowTags: { _, _ in },
            createWindowContext: { _ in makeBorderTestContext() },
            setWindowShape: { _, frame in reshapeFrames.append(frame) },
            flushWindow: { _ in flushCount += 1 },
            transactionMove: { _, _ in moveOnlyCount += 1 },
            transactionMoveAndOrder: { _, _, _, targetWid, _ in orderedTargets.append(targetWid) },
            transactionHide: { _ in },
            backingScaleForFrame: { _ in 2.0 }
        )
        let borderWindow = BorderWindow(
            config: BorderConfig(enabled: true, width: 4, color: .systemBlue),
            operations: operations
        )

        let frame = CGRect(x: 120, y: 90, width: 800, height: 600)
        borderWindow.update(frame: frame, targetWid: 101, cornerRadius: 9)
        borderWindow.update(frame: frame, targetWid: 101, cornerRadius: 12)

        #expect(reshapeFrames.count == 1)
        #expect(flushCount == 2)
        #expect(moveOnlyCount == 1)
        #expect(orderedTargets == [101])
    }

    @Test @MainActor func forceOrderingBypassesManagerFrameDedupe() {
        var flushCount = 0
        var moveOnlyCount = 0
        var orderedTargets: [UInt32] = []
        var backingScaleLookups = 0

        let operations = BorderWindow.Operations(
            createBorderWindow: { _ in 904 },
            releaseBorderWindow: { _ in },
            configureWindow: { _, _, _ in },
            setWindowTags: { _, _ in },
            createWindowContext: { _ in makeBorderTestContext() },
            setWindowShape: { _, _ in },
            flushWindow: { _ in flushCount += 1 },
            transactionMove: { _, _ in moveOnlyCount += 1 },
            transactionMoveAndOrder: { _, _, _, targetWid, _ in orderedTargets.append(targetWid) },
            transactionHide: { _ in },
            backingScaleForFrame: { _ in
                backingScaleLookups += 1
                return 2.0
            }
        )
        let manager = BorderManager(
            config: BorderConfig(enabled: true, width: 4, color: .systemBlue),
            borderWindowOperations: operations,
            cornerRadiusProvider: { _ in nil }
        )
        defer { manager.cleanup() }

        let frame = CGRect(x: 120, y: 90, width: 800, height: 600)
        manager.updateFocusedWindow(frame: frame, windowId: 101)
        manager.updateFocusedWindow(frame: frame, windowId: 101)
        manager.updateFocusedWindow(frame: frame, windowId: 101, forceOrdering: true)

        #expect(flushCount == 1)
        #expect(moveOnlyCount == 0)
        #expect(backingScaleLookups == 1)
        #expect(orderedTargets == [101, 101])
    }

    @Test @MainActor func sameFrameDifferentTargetReordersWithoutRedraw() {
        var flushCount = 0
        var moveOnlyCount = 0
        var orderedTargets: [UInt32] = []
        var backingScaleLookups = 0
        var radiusQueries: [Int] = []

        let operations = BorderWindow.Operations(
            createBorderWindow: { _ in 905 },
            releaseBorderWindow: { _ in },
            configureWindow: { _, _, _ in },
            setWindowTags: { _, _ in },
            createWindowContext: { _ in makeBorderTestContext() },
            setWindowShape: { _, _ in },
            flushWindow: { _ in flushCount += 1 },
            transactionMove: { _, _ in moveOnlyCount += 1 },
            transactionMoveAndOrder: { _, _, _, targetWid, _ in orderedTargets.append(targetWid) },
            transactionHide: { _ in },
            backingScaleForFrame: { _ in
                backingScaleLookups += 1
                return 2.0
            }
        )
        let manager = BorderManager(
            config: BorderConfig(enabled: true, width: 4, color: .systemBlue),
            borderWindowOperations: operations,
            cornerRadiusProvider: { windowId in
                radiusQueries.append(windowId)
                return windowId == 102 ? 9 : nil
            }
        )
        defer { manager.cleanup() }

        let frame = CGRect(x: 120, y: 90, width: 800, height: 600)
        manager.updateFocusedWindow(frame: frame, windowId: 101)
        manager.updateFocusedWindow(frame: frame, windowId: 102)

        #expect(flushCount == 1)
        #expect(moveOnlyCount == 0)
        #expect(backingScaleLookups == 1)
        #expect(radiusQueries == [101, 102])
        #expect(orderedTargets == [101, 102])
        #expect(manager.lastAppliedFocusedWindowIdForTests == 102)
        #expect(manager.lastAppliedFocusedFrameForTests == frame)
    }

    @Test @MainActor func sameFrameDifferentTargetWithDifferentRadiusRedraws() {
        var reshapeFrames: [CGRect] = []
        var flushCount = 0
        var moveOnlyCount = 0
        var orderedTargets: [UInt32] = []
        var backingScaleLookups = 0
        var radiusQueries: [Int] = []

        let operations = BorderWindow.Operations(
            createBorderWindow: { _ in 908 },
            releaseBorderWindow: { _ in },
            configureWindow: { _, _, _ in },
            setWindowTags: { _, _ in },
            createWindowContext: { _ in makeBorderTestContext() },
            setWindowShape: { _, frame in reshapeFrames.append(frame) },
            flushWindow: { _ in flushCount += 1 },
            transactionMove: { _, _ in moveOnlyCount += 1 },
            transactionMoveAndOrder: { _, _, _, targetWid, _ in orderedTargets.append(targetWid) },
            transactionHide: { _ in },
            backingScaleForFrame: { _ in
                backingScaleLookups += 1
                return 2.0
            }
        )
        let manager = BorderManager(
            config: BorderConfig(enabled: true, width: 4, color: .systemBlue),
            borderWindowOperations: operations,
            cornerRadiusProvider: { windowId in
                radiusQueries.append(windowId)
                return windowId == 102 ? 13 : 9
            }
        )
        defer { manager.cleanup() }

        let frame = CGRect(x: 120, y: 90, width: 800, height: 600)
        manager.updateFocusedWindow(frame: frame, windowId: 101)
        manager.updateFocusedWindow(frame: frame, windowId: 102)

        #expect(reshapeFrames.count == 1)
        #expect(flushCount == 2)
        #expect(moveOnlyCount == 0)
        #expect(backingScaleLookups == 2)
        #expect(radiusQueries == [101, 102])
        #expect(orderedTargets == [101, 102])
        #expect(manager.lastAppliedFocusedWindowIdForTests == 102)
        #expect(manager.lastAppliedFocusedFrameForTests == frame)
    }

    @Test @MainActor func sameWindowMoveAndResizeReuseCachedRadius() {
        var reshapeFrames: [CGRect] = []
        var flushCount = 0
        var moveOnlyCount = 0
        var orderedTargets: [UInt32] = []
        var backingScaleLookups = 0
        var radiusQueries: [Int] = []

        let operations = BorderWindow.Operations(
            createBorderWindow: { _ in 909 },
            releaseBorderWindow: { _ in },
            configureWindow: { _, _, _ in },
            setWindowTags: { _, _ in },
            createWindowContext: { _ in makeBorderTestContext() },
            setWindowShape: { _, frame in reshapeFrames.append(frame) },
            flushWindow: { _ in flushCount += 1 },
            transactionMove: { _, _ in moveOnlyCount += 1 },
            transactionMoveAndOrder: { _, _, _, targetWid, _ in orderedTargets.append(targetWid) },
            transactionHide: { _ in },
            backingScaleForFrame: { _ in
                backingScaleLookups += 1
                return 2.0
            }
        )
        let manager = BorderManager(
            config: BorderConfig(enabled: true, width: 4, color: .systemBlue),
            borderWindowOperations: operations,
            cornerRadiusProvider: { windowId in
                radiusQueries.append(windowId)
                return 11
            }
        )
        defer { manager.cleanup() }

        let frame = CGRect(x: 120, y: 90, width: 800, height: 600)
        manager.updateFocusedWindow(frame: frame, windowId: 101)
        manager.updateFocusedWindow(frame: frame.offsetBy(dx: 20, dy: 10), windowId: 101)
        manager.updateFocusedWindow(
            frame: CGRect(x: 140, y: 100, width: 820, height: 600),
            windowId: 101
        )

        #expect(reshapeFrames.count == 2)
        #expect(flushCount == 2)
        #expect(moveOnlyCount == 2)
        #expect(backingScaleLookups == 3)
        #expect(radiusQueries == [101])
        #expect(orderedTargets == [101])
        #expect(manager.lastAppliedFocusedWindowIdForTests == 101)
    }

    @Test @MainActor func nilFocusedWindowClearsCachedRadius() {
        var flushCount = 0
        var orderedTargets: [UInt32] = []
        var hideCount = 0
        var radiusQueries: [Int] = []

        let operations = BorderWindow.Operations(
            createBorderWindow: { _ in 910 },
            releaseBorderWindow: { _ in },
            configureWindow: { _, _, _ in },
            setWindowTags: { _, _ in },
            createWindowContext: { _ in makeBorderTestContext() },
            setWindowShape: { _, _ in },
            flushWindow: { _ in flushCount += 1 },
            transactionMove: { _, _ in },
            transactionMoveAndOrder: { _, _, _, targetWid, _ in orderedTargets.append(targetWid) },
            transactionHide: { _ in hideCount += 1 },
            backingScaleForFrame: { _ in 2.0 }
        )
        let manager = BorderManager(
            config: BorderConfig(enabled: true, width: 4, color: .systemBlue),
            borderWindowOperations: operations,
            cornerRadiusProvider: { windowId in
                radiusQueries.append(windowId)
                return 12
            }
        )
        defer { manager.cleanup() }

        let frame = CGRect(x: 120, y: 90, width: 800, height: 600)
        manager.updateFocusedWindow(frame: frame, windowId: 101)
        manager.updateFocusedWindow(frame: frame, windowId: nil)
        manager.updateFocusedWindow(frame: frame, windowId: 101)

        #expect(flushCount == 1)
        #expect(hideCount == 1)
        #expect(radiusQueries == [101, 101])
        #expect(orderedTargets == [101, 101])
        #expect(manager.lastAppliedFocusedWindowIdForTests == 101)
        #expect(manager.lastAppliedFocusedFrameForTests == frame)
    }

    @Test @MainActor func createFailureDoesNotPoisonManagerFrameDedupe() {
        var createCount = 0
        var flushCount = 0
        var moveOnlyCount = 0
        var orderedTargets: [UInt32] = []
        var backingScaleLookups = 0

        let operations = BorderWindow.Operations(
            createBorderWindow: { _ in
                createCount += 1
                return createCount == 1 ? 0 : 906
            },
            releaseBorderWindow: { _ in },
            configureWindow: { _, _, _ in },
            setWindowTags: { _, _ in },
            createWindowContext: { _ in makeBorderTestContext() },
            setWindowShape: { _, _ in },
            flushWindow: { _ in flushCount += 1 },
            transactionMove: { _, _ in moveOnlyCount += 1 },
            transactionMoveAndOrder: { _, _, _, targetWid, _ in orderedTargets.append(targetWid) },
            transactionHide: { _ in },
            backingScaleForFrame: { _ in
                backingScaleLookups += 1
                return 2.0
            }
        )
        let manager = BorderManager(
            config: BorderConfig(enabled: true, width: 4, color: .systemBlue),
            borderWindowOperations: operations,
            cornerRadiusProvider: { _ in nil }
        )
        defer { manager.cleanup() }

        let frame = CGRect(x: 120, y: 90, width: 800, height: 600)
        manager.updateFocusedWindow(frame: frame, windowId: 101)

        #expect(createCount == 1)
        #expect(flushCount == 0)
        #expect(moveOnlyCount == 0)
        #expect(backingScaleLookups == 1)
        #expect(orderedTargets.isEmpty)
        #expect(manager.lastAppliedFocusedWindowIdForTests == nil)
        #expect(manager.lastAppliedFocusedFrameForTests == nil)

        manager.updateFocusedWindow(frame: frame, windowId: 101)

        #expect(createCount == 2)
        #expect(flushCount == 1)
        #expect(moveOnlyCount == 0)
        #expect(backingScaleLookups == 2)
        #expect(orderedTargets == [101])
        #expect(manager.lastAppliedFocusedWindowIdForTests == 101)
        #expect(manager.lastAppliedFocusedFrameForTests == frame)
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
