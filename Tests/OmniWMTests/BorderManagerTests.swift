// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import CoreGraphics
import Testing

@testable import OmniWM

@MainActor
private func makeBorderManagerTestContext() -> CGContext? {
    CGContext(
        data: nil,
        width: 64,
        height: 64,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
}

@Suite(.serialized) struct BorderManagerTests {
    @Test @MainActor func hiddenConfigChangeDoesNotRegisterOrRevealBorderWithoutLiveOwner() {
        SurfaceCoordinator.shared.resetForTests()
        defer {
            SurfaceCoordinator.shared.resetForTests()
        }

        var orderedTargets: [UInt32] = []
        var hideCount = 0

        let operations = BorderWindow.Operations(
            createBorderWindow: { _ in 950 },
            releaseBorderWindow: { _ in },
            configureWindow: { _, _, _ in },
            setWindowTags: { _, _ in },
            createWindowContext: { _ in makeBorderManagerTestContext() },
            setWindowShape: { _, _ in },
            flushWindow: { _ in },
            transactionMove: { _, _ in },
            transactionMoveAndOrder: { _, _, _, targetWid, _ in orderedTargets.append(targetWid) },
            transactionHide: { _ in hideCount += 1 },
            backingScaleForFrame: { _ in 2.0 }
        )
        let manager = BorderManager(
            config: BorderConfig(enabled: true, width: 4, color: .systemBlue),
            borderWindowFactory: { BorderWindow(config: $0, operations: operations) }
        )

        manager.updateFocusedWindow(
            frame: CGRect(x: 80, y: 60, width: 700, height: 500),
            windowId: 241
        )
        #expect(
            SurfaceCoordinator.shared.visibleSurfaceIDs(kind: .border, capturePolicy: .excluded)
                == ["border-surface"]
        )

        manager.hideBorder()
        #expect(
            SurfaceCoordinator.shared.visibleSurfaceIDs(kind: .border, capturePolicy: .excluded)
                .isEmpty
        )

        manager.updateConfig(
            BorderConfig(enabled: true, width: 12, color: .systemRed)
        )

        #expect(
            SurfaceCoordinator.shared.visibleSurfaceIDs(kind: .border, capturePolicy: .excluded)
                .isEmpty
        )
        #expect(manager.lastAppliedFocusedWindowIdForTests == nil)
        #expect(manager.lastAppliedFocusedFrameForTests == nil)
        #expect(orderedTargets == [241])
        #expect(hideCount == 1)
    }
}
