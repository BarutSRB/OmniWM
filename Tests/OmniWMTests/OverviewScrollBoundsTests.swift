import Foundation
import Testing

@testable import OmniWM

@Suite struct OverviewScrollBoundsTests {
    @Test @MainActor func boundsAreZeroWhenContentFitsViewport() {
        var layout = OverviewLayout()
        layout.scale = 1.0
        layout.searchBarFrame = CGRect(x: 0, y: 900, width: 500, height: 44)
        layout.totalContentHeight = 200

        let bounds = OverviewLayoutCalculator.scrollOffsetBounds(
            layout: layout,
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        #expect(bounds.lowerBound == 0)
        #expect(bounds.upperBound == 0)
    }

    @Test @MainActor func boundsAllowNegativeOffsetWhenContentExtendsBelowViewport() {
        var layout = OverviewLayout()
        layout.scale = 1.0
        layout.searchBarFrame = CGRect(x: 0, y: 900, width: 500, height: 44)
        layout.totalContentHeight = 1300

        let bounds = OverviewLayoutCalculator.scrollOffsetBounds(
            layout: layout,
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )

        #expect(bounds.lowerBound == -420)
        #expect(bounds.upperBound == 0)
    }

    @Test @MainActor func clampedScrollOffsetRespectsNegativeAndTopBounds() {
        var layout = OverviewLayout()
        layout.scale = 1.0
        layout.searchBarFrame = CGRect(x: 0, y: 900, width: 500, height: 44)
        layout.totalContentHeight = 1300
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let aboveTop = OverviewLayoutCalculator.clampedScrollOffset(
            40,
            layout: layout,
            screenFrame: screenFrame
        )
        let belowBottom = OverviewLayoutCalculator.clampedScrollOffset(
            -500,
            layout: layout,
            screenFrame: screenFrame
        )
        let inBounds = OverviewLayoutCalculator.clampedScrollOffset(
            -300,
            layout: layout,
            screenFrame: screenFrame
        )

        #expect(aboveTop == 0)
        #expect(belowBottom == -420)
        #expect(inBounds == -300)
    }
}
