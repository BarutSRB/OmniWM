// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing

@testable import OmniWM

private func makeContainers(
    widths: [CGFloat],
    heights: [CGFloat]? = nil,
    windowSizingModes: [[SizingMode]]? = nil,
    tabbedIndices: Set<Int> = []
) -> [NiriContainer] {
    zip(widths, heights ?? widths).enumerated().map { index, pair in
        let (width, height) = pair
        let container = NiriContainer()
        container.cachedWidth = width
        container.cachedHeight = height
        if tabbedIndices.contains(index) {
            container.displayMode = .tabbed
        }

        let sizingModes: [SizingMode]
        if let windowSizingModes, index < windowSizingModes.count {
            sizingModes = windowSizingModes[index]
        } else {
            sizingModes = [.normal]
        }

        for (windowIndex, mode) in sizingModes.enumerated() {
            let window = NiriWindow(
                token: WindowToken(
                    pid: pid_t(1_000 + index),
                    windowId: windowIndex + 1
                )
            )
            window.sizingMode = mode
            container.appendChild(window)
        }
        return container
    }
}

@Suite struct ViewportGeometryTests {
    @Test func emptyContainersReturnZeroGeometry() {
        let state = ViewportState()

        #expect(state.totalWidth(columns: [], gap: 8) == 0)
        #expect(state.computeCenteredOffset(columnIndex: 0, columns: [], gap: 8, viewportWidth: 300) == 0)
        #expect(
            state.computeVisibleOffset(
                columnIndex: 0,
                columns: [],
                gap: 8,
                viewportWidth: 300,
                currentOffset: 0,
                centerMode: .never
            ) == 0
        )
    }

    @Test func genericSpanHelpersUseRequestedDimensionAndPreserveOutOfRangeSemantics() {
        let state = ViewportState()
        let containers = makeContainers(widths: [10, 20, 30], heights: [50, 70, 90])

        #expect(
            state.containerPosition(
                at: 2,
                containers: containers,
                gap: 5,
                sizeKeyPath: \.cachedHeight
            ) == 130
        )
        #expect(
            state.totalSpan(
                containers: containers,
                gap: 5,
                sizeKeyPath: \.cachedHeight
            ) == 220
        )
        #expect(state.columnX(at: 10, columns: containers, gap: 5) == 75)
        #expect(
            state.computeVisibleOffset(
                containerIndex: -1,
                containers: containers,
                gap: 5,
                viewportSpan: 100,
                sizeKeyPath: \.cachedHeight,
                currentViewStart: 0,
                centerMode: .never
            ) == 0
        )
        #expect(
            state.computeCenteredOffset(
                containerIndex: 10,
                containers: containers,
                gap: 5,
                viewportSpan: 100,
                sizeKeyPath: \.cachedHeight
            ) == 0
        )
    }

    @Test func centeredOffsetCentersTargetColumnWhenViewportExceedsTotalSpan() {
        let state = ViewportState()
        let columns = makeContainers(widths: [100, 100])

        let offset = state.computeCenteredOffset(
            columnIndex: 1,
            columns: columns,
            gap: 10,
            viewportWidth: 300
        )

        #expect(abs(offset + 100) < 0.001)
    }

    @Test func centeredOffsetIgnoresFullStripBoundsWhenCenteringTargetColumn() {
        let state = ViewportState()
        let columns = makeContainers(widths: [100, 100, 100])

        let offset = state.computeCenteredOffset(
            columnIndex: 2,
            columns: columns,
            gap: 10,
            viewportWidth: 150
        )

        #expect(abs(offset + 25) < 0.001)
    }

    @Test func centeredOffsetPreservesBestEffortCenteringForOversizedColumns() {
        let state = ViewportState()
        let columns = makeContainers(widths: [200])

        let offset = state.computeCenteredOffset(
            columnIndex: 0,
            columns: columns,
            gap: 0,
            viewportWidth: 150
        )

        #expect(abs(offset - 25) < 0.001)
    }

    @Test func visibleOffsetKeepsFullyVisibleTargetPinnedInNeverMode() {
        let state = ViewportState()
        let columns = makeContainers(widths: [100, 100, 100])

        let offset = state.computeVisibleOffset(
            containerIndex: 1,
            containers: columns,
            gap: 10,
            viewportSpan: 220,
            sizeKeyPath: \.cachedWidth,
            currentViewStart: 0,
            centerMode: .never
        )

        #expect(abs(offset + 110) < 0.001)
    }

    @Test func visibleOffsetFitsTargetWhenOnOverflowWithoutSourceContainer() {
        let state = ViewportState()
        let columns = makeContainers(widths: [100, 100, 100])

        let offset = state.computeVisibleOffset(
            containerIndex: 1,
            containers: columns,
            gap: 10,
            viewportSpan: 150,
            sizeKeyPath: \.cachedWidth,
            currentViewStart: 0,
            centerMode: .onOverflow
        )

        #expect(abs(offset + 40) < 0.001)
    }

    @Test func visibleOffsetAlwaysModeMatchesCenteredOffset() {
        let state = ViewportState()
        let columns = makeContainers(widths: [100, 100, 100])

        let offset = state.computeVisibleOffset(
            containerIndex: 1,
            containers: columns,
            gap: 10,
            viewportSpan: 150,
            sizeKeyPath: \.cachedWidth,
            currentViewStart: 0,
            centerMode: .always
        )

        #expect(abs(offset + 25) < 0.001)
    }

    @Test func visibleOffsetOnOverflowCentersOversizedColumn() {
        let state = ViewportState()
        let columns = makeContainers(widths: [100, 200, 100])

        let offset = state.computeVisibleOffset(
            containerIndex: 1,
            containers: columns,
            gap: 10,
            viewportSpan: 150,
            sizeKeyPath: \.cachedWidth,
            currentViewStart: 0,
            centerMode: .onOverflow,
            fromContainerIndex: 0
        )

        #expect(abs(offset - 25) < 0.001)
    }

    @Test func visibleOffsetOnOverflowFitsWhenNeighborPairFitsWithinViewport() {
        let state = ViewportState()
        let columns = makeContainers(widths: [100, 100, 100])

        let offset = state.computeVisibleOffset(
            containerIndex: 1,
            containers: columns,
            gap: 10,
            viewportSpan: 230,
            sizeKeyPath: \.cachedWidth,
            currentViewStart: 0,
            centerMode: .onOverflow,
            fromContainerIndex: 0
        )

        #expect(abs(offset + 110) < 0.001)
    }

    @Test func visibleOffsetOnOverflowCentersWhenNeighborPairExceedsViewport() {
        let state = ViewportState()
        let columns = makeContainers(widths: [100, 100, 100])

        let offset = state.computeVisibleOffset(
            containerIndex: 1,
            containers: columns,
            gap: 10,
            viewportSpan: 220,
            sizeKeyPath: \.cachedWidth,
            currentViewStart: 0,
            centerMode: .onOverflow,
            fromContainerIndex: 0
        )

        #expect(abs(offset + 60) < 0.001)
    }

    @Test func visibleOffsetCentersWhenOverflowingPairCannotStayVisibleTogether() {
        let state = ViewportState()
        let columns = makeContainers(widths: [100, 100, 100, 100])

        let offset = state.computeVisibleOffset(
            containerIndex: 2,
            containers: columns,
            gap: 10,
            viewportSpan: 150,
            sizeKeyPath: \.cachedWidth,
            currentViewStart: 0,
            centerMode: .onOverflow,
            fromContainerIndex: 0
        )

        #expect(abs(offset + 25) < 0.001)
    }

    @Test func visibleOffsetAlwaysModeUsesCenteredOffset() {
        let state = ViewportState()
        let columns = makeContainers(widths: [100, 100, 100, 100])

        let offset = state.computeVisibleOffset(
            containerIndex: 2,
            containers: columns,
            gap: 10,
            viewportSpan: 150,
            sizeKeyPath: \.cachedWidth,
            currentViewStart: 0,
            centerMode: .always
        )

        #expect(abs(offset + 25) < 0.001)
    }

    @Test func alwaysCenterSingleColumnOverridesNeverCenterMode() {
        let state = ViewportState()
        let columns = makeContainers(widths: [100])

        let offset = state.computeVisibleOffset(
            containerIndex: 0,
            containers: columns,
            gap: 8,
            viewportSpan: 200,
            sizeKeyPath: \.cachedWidth,
            currentViewStart: 0,
            centerMode: .never,
            alwaysCenterSingleColumn: true
        )

        #expect(abs(offset + 50) < 0.001)
    }

    @Test func visibleOffsetAlwaysModeCentersEdgeColumnsEvenWhenFullStripFits() {
        let state = ViewportState()
        let columns = makeContainers(widths: [400, 400])

        let first = state.computeVisibleOffset(
            containerIndex: 0,
            containers: columns,
            gap: 8,
            viewportSpan: 1200,
            sizeKeyPath: \.cachedWidth,
            currentViewStart: 0,
            centerMode: .always
        )
        let last = state.computeVisibleOffset(
            containerIndex: 1,
            containers: columns,
            gap: 8,
            viewportSpan: 1200,
            sizeKeyPath: \.cachedWidth,
            currentViewStart: 0,
            centerMode: .always
        )

        #expect(abs(first + 400) < 0.001)
        #expect(abs(last + 400) < 0.001)
    }

    @Test func fullscreenColumnsUseMonitorAnchoredCenteredAndFitOffsets() {
        let state = ViewportState()
        let normalColumns = makeContainers(widths: [400, 400])
        let fullscreenColumns = makeContainers(
            widths: [400, 400],
            windowSizingModes: [[.normal], [.normal, .fullscreen]],
            tabbedIndices: [1]
        )

        let normalCenteredOffset = state.computeCenteredOffset(
            columnIndex: 1,
            columns: normalColumns,
            gap: 8,
            viewportWidth: 500
        )
        let fullscreenCenteredOffset = state.computeCenteredOffset(
            columnIndex: 1,
            columns: fullscreenColumns,
            gap: 8,
            viewportWidth: 500
        )

        let normalFitOffset = state.computeVisibleOffset(
            containerIndex: 1,
            containers: normalColumns,
            gap: 8,
            viewportSpan: 500,
            sizeKeyPath: \.cachedWidth,
            currentViewStart: 0,
            centerMode: .never
        )
        let fullscreenFitOffset = state.computeVisibleOffset(
            containerIndex: 1,
            containers: fullscreenColumns,
            gap: 8,
            viewportSpan: 500,
            sizeKeyPath: \.cachedWidth,
            currentViewStart: 0,
            centerMode: .never
        )

        #expect(abs(normalCenteredOffset + 50) < 0.001)
        #expect(abs(fullscreenCenteredOffset) < 0.001)
        #expect(
            abs(
                state.columnX(at: 1, columns: normalColumns, gap: 8)
                    + normalFitOffset
                    - 308
            ) < 0.001
        )
        #expect(
            abs(
                state.columnX(at: 1, columns: fullscreenColumns, gap: 8)
                    + fullscreenFitOffset
                    - 408
            ) < 0.001
        )
    }

    @Test func snapTargetAlwaysModeAnchorsFullscreenEdgeColumns() {
        let state = ViewportState()
        let lastFullscreen = makeContainers(
            widths: [400, 400],
            windowSizingModes: [[.normal], [.fullscreen]]
        )
        let firstFullscreen = makeContainers(
            widths: [400, 400],
            windowSizingModes: [[.fullscreen], [.normal]]
        )

        let snapToLast = state.snapTarget(
            projectedViewPos: 900,
            currentViewPos: -400,
            columns: lastFullscreen,
            gap: 8,
            viewportWidth: 1_200,
            centerMode: .always
        )
        let snapToFirst = state.snapTarget(
            projectedViewPos: -200,
            currentViewPos: 408,
            columns: firstFullscreen,
            gap: 8,
            viewportWidth: 1_200,
            centerMode: .always
        )

        #expect(snapToLast.columnIndex == 1)
        #expect(abs(snapToLast.viewPos - 408) < 0.001)
        #expect(snapToFirst.columnIndex == 0)
        #expect(abs(snapToFirst.viewPos) < 0.001)
    }

    @Test func snapTargetOnOverflowAnchorsFullscreenEdgeColumns() {
        let state = ViewportState()
        let lastFullscreen = makeContainers(
            widths: [400, 400],
            windowSizingModes: [[.normal], [.fullscreen]]
        )
        let firstFullscreen = makeContainers(
            widths: [400, 400],
            windowSizingModes: [[.fullscreen], [.normal]]
        )

        let snapToLast = state.snapTarget(
            projectedViewPos: 900,
            currentViewPos: 0,
            columns: lastFullscreen,
            gap: 8,
            viewportWidth: 1_200,
            centerMode: .onOverflow
        )
        let snapToFirst = state.snapTarget(
            projectedViewPos: -200,
            currentViewPos: 0,
            columns: firstFullscreen,
            gap: 8,
            viewportWidth: 1_200,
            centerMode: .onOverflow
        )

        #expect(snapToLast.columnIndex == 1)
        #expect(abs(snapToLast.viewPos - 408) < 0.001)
        #expect(snapToFirst.columnIndex == 0)
        #expect(abs(snapToFirst.viewPos) < 0.001)
    }

    @Test func endGestureAlwaysModeCentersEdgeColumnsOnSnap() {
        let columns = makeContainers(widths: [400, 400])

        var toLast = ViewportState()
        toLast.activeColumnIndex = 0
        toLast.viewOffsetPixels = .static(-400)
        toLast.beginGesture(isTrackpad: false)
        _ = toLast.updateGesture(
            deltaPixels: 500,
            timestamp: 1.0,
            columns: columns,
            gap: 8,
            viewportWidth: 1200
        )
        toLast.endGesture(
            columns: columns,
            gap: 8,
            viewportWidth: 1200,
            motion: .disabled,
            centerMode: .always
        )

        #expect(toLast.activeColumnIndex == 1)
        #expect(abs(toLast.viewOffsetPixels.target() + 400) < 0.001)

        var toFirst = ViewportState()
        toFirst.activeColumnIndex = 1
        toFirst.viewOffsetPixels = .static(-400)
        toFirst.beginGesture(isTrackpad: false)
        _ = toFirst.updateGesture(
            deltaPixels: -500,
            timestamp: 1.0,
            columns: columns,
            gap: 8,
            viewportWidth: 1200
        )
        toFirst.endGesture(
            columns: columns,
            gap: 8,
            viewportWidth: 1200,
            motion: .disabled,
            centerMode: .always
        )

        #expect(toFirst.activeColumnIndex == 0)
        #expect(abs(toFirst.viewOffsetPixels.target() + 400) < 0.001)
    }

    @Test func endGestureOnOverflowUsesEdgeSnapBoundsWithoutStripClamp() {
        let columns = makeContainers(widths: [100, 100, 100])

        var toLast = ViewportState()
        toLast.activeColumnIndex = 1
        toLast.viewOffsetPixels = .static(-60)
        toLast.beginGesture(isTrackpad: false)
        _ = toLast.updateGesture(
            deltaPixels: 500,
            timestamp: 1.0,
            columns: columns,
            gap: 10,
            viewportWidth: 220
        )
        toLast.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 220,
            motion: .disabled,
            centerMode: .onOverflow
        )

        #expect(toLast.activeColumnIndex == 2)
        #expect(abs(toLast.viewOffsetPixels.target() + 60) < 0.001)

        var toFirst = ViewportState()
        toFirst.activeColumnIndex = 1
        toFirst.viewOffsetPixels = .static(-60)
        toFirst.beginGesture(isTrackpad: false)
        _ = toFirst.updateGesture(
            deltaPixels: -500,
            timestamp: 1.0,
            columns: columns,
            gap: 10,
            viewportWidth: 220
        )
        toFirst.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 220,
            motion: .disabled,
            centerMode: .onOverflow
        )

        #expect(toFirst.activeColumnIndex == 0)
        #expect(abs(toFirst.viewOffsetPixels.target() + 60) < 0.001)
    }

    @Test func scrollReanchorPreservesPlanningViewportAndClearsRestoreBookkeeping() {
        let columns = makeContainers(widths: [100, 200])
        columns[0].targetWidth = 300
        columns[1].targetWidth = 400

        var state = ViewportState()
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(25)
        state.viewOffsetToRestore = 77
        state.activatePrevColumnOnRemoval = 88

        state.reanchorActiveColumnPreservingViewport(
            1,
            columns: columns,
            gap: 10
        )

        #expect(state.activeColumnIndex == 1)
        #expect(abs(state.viewOffsetPixels.target() + 285) < 0.001)
        #expect(state.viewOffsetToRestore == nil)
        #expect(state.activatePrevColumnOnRemoval == nil)
    }

    @Test func updateGestureReturnsNilForZeroWidthSingleColumn() {
        var state = ViewportState()
        state.beginGesture(isTrackpad: true)

        let columns = makeContainers(widths: [0])
        let steps = state.updateGesture(
            deltaPixels: 120,
            timestamp: 1.0,
            columns: columns,
            gap: 8,
            viewportWidth: 1200
        )

        #expect(steps == nil)
        #expect(state.selectionProgress == 0)

        guard let gesture = state.viewOffsetPixels.gestureRef else {
            Issue.record("Expected gesture state to remain active for zero-width regression test")
            return
        }

        #expect(gesture.currentViewOffset.isFinite)
    }

    @Test func endGestureRetainsStableOffsetForInvalidGeometry() {
        struct Scenario {
            let label: String
            let columns: [NiriContainer]
        }

        let scenarios: [Scenario] = [
            .init(label: "empty columns", columns: []),
            .init(label: "zero-width column", columns: makeContainers(widths: [0])),
        ]

        for scenario in scenarios {
            var state = ViewportState()
            state.activeColumnIndex = 2
            state.viewOffsetPixels = .static(-32)
            state.beginGesture(isTrackpad: false)
            state.selectionProgress = 17
            state.viewOffsetToRestore = 99
            state.activatePrevColumnOnRemoval = 42

            guard let gesture = state.viewOffsetPixels.gestureRef else {
                Issue.record("Expected gesture state for \(scenario.label)")
                continue
            }

            gesture.currentViewOffset = -123.5

            state.endGesture(
                columns: scenario.columns,
                gap: 8,
                viewportWidth: 1200,
                motion: .enabled,
                centerMode: .onOverflow
            )

            #expect(state.activeColumnIndex == 2, Comment(rawValue: scenario.label))
            #expect(state.viewOffsetPixels.isGesture == false, Comment(rawValue: scenario.label))
            #expect(state.viewOffsetPixels.isAnimating == false, Comment(rawValue: scenario.label))
            #expect(abs(Double(state.viewOffsetPixels.target()) + 123.5) < 0.001, Comment(rawValue: scenario.label))
            #expect(state.selectionProgress == 0, Comment(rawValue: scenario.label))
            #expect(state.viewOffsetToRestore == nil, Comment(rawValue: scenario.label))
            #expect(state.activatePrevColumnOnRemoval == nil, Comment(rawValue: scenario.label))
        }
    }

    @Test func endGestureWithEnabledMotionCreatesSettleSpring() {
        let columns = makeContainers(widths: [400, 400])

        var state = ViewportState()
        state.animationClock = AnimationClock(time: 1.0)
        state.activeColumnIndex = 0
        state.viewOffsetPixels = .static(-400)
        state.beginGesture(isTrackpad: false)
        _ = state.updateGesture(
            deltaPixels: 500,
            timestamp: 1.0,
            columns: columns,
            gap: 8,
            viewportWidth: 1200
        )

        state.endGesture(
            columns: columns,
            gap: 8,
            viewportWidth: 1200,
            motion: .enabled,
            centerMode: .always
        )

        #expect(state.activeColumnIndex == 1)
        #expect(state.viewOffsetPixels.isAnimating)
        #expect(abs(state.viewOffsetPixels.target() + 400) < 0.001)
        #expect(state.selectionProgress == 0)
        #expect(state.viewOffsetToRestore == nil)
        #expect(state.activatePrevColumnOnRemoval == nil)
    }

    @Test func endGestureMatchesSharedSnapTargetAcrossNormalAndFullscreenScenarios() {
        struct Scenario {
            let label: String
            let widths: [CGFloat]
            let windowSizingModes: [[SizingMode]]
            let gap: CGFloat
            let viewportWidth: CGFloat
            let centerMode: CenterFocusedColumn
            let initialActiveIndex: Int
            let initialOffset: CGFloat
            let deltaPixels: CGFloat
        }

        let scenarios: [Scenario] = [
            .init(
                label: "always normal -> edge center",
                widths: [400, 400],
                windowSizingModes: [[.normal], [.normal]],
                gap: 8,
                viewportWidth: 1_200,
                centerMode: .always,
                initialActiveIndex: 0,
                initialOffset: -400,
                deltaPixels: 500
            ),
            .init(
                label: "always fullscreen target -> monitor anchor",
                widths: [400, 400],
                windowSizingModes: [[.normal], [.fullscreen]],
                gap: 8,
                viewportWidth: 1_200,
                centerMode: .always,
                initialActiveIndex: 0,
                initialOffset: -400,
                deltaPixels: 700
            ),
            .init(
                label: "overflow fullscreen target -> monitor anchor",
                widths: [400, 400],
                windowSizingModes: [[.normal], [.fullscreen]],
                gap: 8,
                viewportWidth: 1_200,
                centerMode: .onOverflow,
                initialActiveIndex: 0,
                initialOffset: 0,
                deltaPixels: 700
            ),
            .init(
                label: "overflow fullscreen source -> pair fit",
                widths: [400, 400],
                windowSizingModes: [[.fullscreen], [.normal]],
                gap: 8,
                viewportWidth: 1_200,
                centerMode: .onOverflow,
                initialActiveIndex: 1,
                initialOffset: -408,
                deltaPixels: -700
            ),
        ]

        for scenario in scenarios {
            let columns = makeContainers(
                widths: scenario.widths,
                windowSizingModes: scenario.windowSizingModes
            )

            var state = ViewportState()
            state.activeColumnIndex = scenario.initialActiveIndex
            state.viewOffsetPixels = .static(scenario.initialOffset)
            state.beginGesture(isTrackpad: false)
            _ = state.updateGesture(
                deltaPixels: scenario.deltaPixels,
                timestamp: 1.0,
                columns: columns,
                gap: scenario.gap,
                viewportWidth: scenario.viewportWidth
            )

            guard let gesture = state.viewOffsetPixels.gestureRef else {
                Issue.record("Expected gesture state for \(scenario.label)")
                continue
            }

            let activeColumnX = state.columnPlanningX(
                at: state.activeColumnIndex,
                columns: columns,
                gap: scenario.gap
            )
            let currentViewPos = Double(activeColumnX) + gesture.current()
            let projectedViewPos = Double(activeColumnX)
                + gesture.tracker.projectedEndPosition()
                + gesture.deltaFromTracker
            let expectedTarget = state.planningSnapTarget(
                projectedViewPos: projectedViewPos,
                currentViewPos: currentViewPos,
                columns: columns,
                gap: scenario.gap,
                viewportWidth: scenario.viewportWidth,
                centerMode: scenario.centerMode
            )

            state.endGesture(
                columns: columns,
                gap: scenario.gap,
                viewportWidth: scenario.viewportWidth,
                motion: .disabled,
                centerMode: scenario.centerMode
            )

            let expectedOffset = expectedTarget.viewPos
                - Double(
                    state.columnPlanningX(
                        at: expectedTarget.columnIndex,
                        columns: columns,
                        gap: scenario.gap
                    )
                )

            #expect(
                state.activeColumnIndex == expectedTarget.columnIndex,
                Comment(rawValue: scenario.label)
            )
            #expect(
                abs(Double(state.viewOffsetPixels.target()) - expectedOffset) < 0.001,
                Comment(rawValue: scenario.label)
            )
        }
    }

    @Test func pixelEpsilonTreatsNearlyVisibleTargetAsVisible() {
        let state = ViewportState()
        let columns = makeContainers(widths: [100])

        let offset = state.computeVisibleOffset(
            containerIndex: 0,
            containers: columns,
            gap: 0,
            viewportSpan: 101,
            sizeKeyPath: \.cachedWidth,
            currentViewStart: 0.4,
            centerMode: .never,
            scale: 2.0
        )

        let strictOffset = state.computeVisibleOffset(
            containerIndex: 0,
            containers: columns,
            gap: 0,
            viewportSpan: 101,
            sizeKeyPath: \.cachedWidth,
            currentViewStart: 0.4,
            centerMode: .never,
            scale: 10.0
        )

        #expect(abs(offset - 0.4) < 0.001)
        #expect(abs(strictOffset) < 0.001)
    }
}
