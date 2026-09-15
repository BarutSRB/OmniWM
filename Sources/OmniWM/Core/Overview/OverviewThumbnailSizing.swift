// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

struct OverviewPreviewProjection {
    let layout: OverviewLayout
    let viewportFrame: CGRect
    let backingScaleFactor: CGFloat
}

enum OverviewThumbnailSizing {
    static func captureRequests(projections: [OverviewPreviewProjection]) -> [OverviewPreviewRequest] {
        var requests: [OverviewPreviewRequest] = []
        var positions: [WindowHandle: Int] = [:]

        for projection in projections {
            let visibleContent = OverviewRenderGeometry.visibleContentRect(
                bounds: projection.viewportFrame,
                scrollOffset: projection.layout.scrollOffset
            )
            let scale = max(projection.backingScaleFactor, 1)
            for section in projection.layout.workspaceSections {
                for window in section.windows {
                    guard window.overviewFrame.size.hasFinitePositiveDimensions(),
                          OverviewRenderGeometry.shouldRender(
                              frame: window.overviewFrame,
                              visibleContentRect: visibleContent
                          )
                    else { continue }
                    let width = max(1, Int(ceil(window.overviewFrame.width * scale)))
                    let height = max(1, Int(ceil(window.overviewFrame.height * scale)))
                    if let position = positions[window.handle] {
                        let previous = requests[position]
                        requests[position] = OverviewPreviewRequest(
                            handle: window.handle,
                            pixelWidth: max(previous.pixelWidth, width),
                            pixelHeight: max(previous.pixelHeight, height)
                        )
                    } else {
                        positions[window.handle] = requests.count
                        requests.append(OverviewPreviewRequest(
                            handle: window.handle,
                            pixelWidth: width,
                            pixelHeight: height
                        ))
                    }
                }
            }
        }
        return requests
    }
}
