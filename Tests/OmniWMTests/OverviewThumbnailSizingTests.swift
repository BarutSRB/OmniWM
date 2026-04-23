// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing

@testable import OmniWM

@Suite struct OverviewThumbnailSizingTests {
    @Test func usesProjectedCardSizeForCaptureRequests() {
        let requests = OverviewThumbnailSizing.captureRequests(
            windowIds: [101],
            projections: [
                OverviewThumbnailProjection(
                    windowId: 101,
                    overviewFrame: CGRect(x: 40, y: 80, width: 220.25, height: 137.5),
                    backingScaleFactor: 2.0
                )
            ]
        )

        #expect(
            requests == [
                OverviewThumbnailCaptureRequest(
                    windowId: 101,
                    pixelWidth: 441,
                    pixelHeight: 275
                )
            ]
        )
    }

    @Test func usesLargestPixelDimensionsAcrossDuplicatedPanels() {
        let requests = OverviewThumbnailSizing.captureRequests(
            windowIds: [202],
            projections: [
                OverviewThumbnailProjection(
                    windowId: 202,
                    overviewFrame: CGRect(x: 0, y: 0, width: 220, height: 100),
                    backingScaleFactor: 1.0
                ),
                OverviewThumbnailProjection(
                    windowId: 202,
                    overviewFrame: CGRect(x: 0, y: 0, width: 150, height: 90),
                    backingScaleFactor: 2.0
                )
            ]
        )

        #expect(
            requests == [
                OverviewThumbnailCaptureRequest(
                    windowId: 202,
                    pixelWidth: 300,
                    pixelHeight: 180
                )
            ]
        )
    }

    @Test func skipsWindowsMissingFromProjectedLayouts() {
        let requests = OverviewThumbnailSizing.captureRequests(
            windowIds: [1, 2],
            projections: [
                OverviewThumbnailProjection(
                    windowId: 1,
                    overviewFrame: CGRect(x: 0, y: 0, width: 120, height: 80),
                    backingScaleFactor: 1.0
                ),
                OverviewThumbnailProjection(
                    windowId: 99,
                    overviewFrame: CGRect(x: 0, y: 0, width: 640, height: 480),
                    backingScaleFactor: 2.0
                )
            ]
        )

        #expect(
            requests == [
                OverviewThumbnailCaptureRequest(
                    windowId: 1,
                    pixelWidth: 120,
                    pixelHeight: 80
                )
            ]
        )
    }

    @Test func clampsDegenerateProjectedFramesToMinimumPixelSize() {
        let requests = OverviewThumbnailSizing.captureRequests(
            windowIds: [303],
            projections: [
                OverviewThumbnailProjection(
                    windowId: 303,
                    overviewFrame: CGRect(x: 10, y: 10, width: 0, height: 0),
                    backingScaleFactor: 2.0
                )
            ]
        )

        #expect(
            requests == [
                OverviewThumbnailCaptureRequest(
                    windowId: 303,
                    pixelWidth: 1,
                    pixelHeight: 1
                )
            ]
        )
    }
}
