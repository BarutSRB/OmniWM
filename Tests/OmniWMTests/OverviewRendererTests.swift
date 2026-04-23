// SPDX-License-Identifier: GPL-2.0-only
import CoreGraphics
import Testing

@testable import OmniWM

@Suite struct OverviewRendererTests {
    @Test func aspectFitRectCentersContentWithoutStretching() {
        let rect = OverviewRenderer.aspectFitRect(
            contentSize: CGSize(width: 800, height: 400),
            in: CGRect(x: 10, y: 20, width: 100, height: 100)
        )

        #expect(rect.origin.x == 10)
        #expect(rect.origin.y == 45)
        #expect(rect.width == 100)
        #expect(rect.height == 50)
    }
}
