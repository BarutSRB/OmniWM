// SPDX-License-Identifier: GPL-2.0-only
import CoreGraphics

struct OverviewThumbnailCaptureRequest: Equatable {
    let windowId: Int
    let pixelWidth: Int
    let pixelHeight: Int
}

struct OverviewThumbnailProjection: Equatable {
    let windowId: Int
    let overviewFrame: CGRect
    let backingScaleFactor: CGFloat
}

enum OverviewThumbnailSizing {
    static func captureRequests(
        windowIds: [Int],
        projections: [OverviewThumbnailProjection]
    ) -> [OverviewThumbnailCaptureRequest] {
        let projectionsByWindowId = Dictionary(grouping: projections, by: \.windowId)
        var requests: [OverviewThumbnailCaptureRequest] = []
        requests.reserveCapacity(windowIds.count)

        for windowId in windowIds {
            guard let windowProjections = projectionsByWindowId[windowId], !windowProjections.isEmpty else {
                continue
            }

            var maxPixelWidth = 1
            var maxPixelHeight = 1

            for projection in windowProjections {
                let scaleFactor = max(projection.backingScaleFactor, 0)
                let pixelWidth = max(1, Int(ceil(max(projection.overviewFrame.width, 0) * scaleFactor)))
                let pixelHeight = max(1, Int(ceil(max(projection.overviewFrame.height, 0) * scaleFactor)))
                maxPixelWidth = max(maxPixelWidth, pixelWidth)
                maxPixelHeight = max(maxPixelHeight, pixelHeight)
            }

            requests.append(
                OverviewThumbnailCaptureRequest(
                    windowId: windowId,
                    pixelWidth: maxPixelWidth,
                    pixelHeight: maxPixelHeight
                )
            )
        }

        return requests
    }
}
