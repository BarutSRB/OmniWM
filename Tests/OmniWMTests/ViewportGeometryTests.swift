import Foundation
import Testing

@testable import OmniWM

private func makeViewportGestureContainers(widths: [CGFloat]) -> [NiriContainer] {
    widths.map { width in
        let container = NiriContainer()
        container.cachedWidth = width
        container.cachedHeight = width
        return container
    }
}

@Suite struct ViewportGeometryTests {
    @Test func updateGestureDoesNotClampOrAdvanceSelectionDuringSwipe() {
        var state = ViewportState()
        state.activeColumnIndex = 1
        let columns = makeViewportGestureContainers(widths: [300, 300])
        _ = state.beginGesture(isTrackpad: true, columns: columns)

        let steps = state.updateGesture(
            deltaPixels: 10_000,
            timestamp: 1.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 1200
        )

        #expect(steps == nil)
        #expect(state.selectionProgress == 0)

        guard let gesture = state.viewOffsetPixels.gestureRef else {
            Issue.record("Expected active gesture state")
            return
        }

        #expect(abs(gesture.currentViewOffset - 10_000) < 0.001)
    }

    @Test func updateGestureDoesNotClampGenericNonTrackpadGesture() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [300, 300])
        _ = state.beginGesture(isTrackpad: false, columns: columns)

        _ = state.updateGesture(
            deltaPixels: 10_000,
            timestamp: 1.0,
            isTrackpad: false,
            columns: columns,
            gap: 10,
            viewportWidth: 200
        )

        guard let gesture = state.viewOffsetPixels.gestureRef else {
            Issue.record("Expected active gesture state")
            return
        }

        #expect(abs(gesture.currentViewOffset - 10_000) < 0.001)
    }

    @Test func endGestureUsesNiriLargeColumnCorrection() {
        var state = ViewportState()
        state.viewOffsetToRestore = 99

        let columns = makeViewportGestureContainers(widths: [300, 300])
        _ = state.beginGesture(isTrackpad: false, columns: columns)

        _ = state.updateGesture(
            deltaPixels: 1_000,
            timestamp: 1.0,
            isTrackpad: false,
            columns: columns,
            gap: 10,
            viewportWidth: 200
        )

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 200,
            motion: .disabled,
            centerMode: .never
        )

        #expect(state.activeColumnIndex == 1)
        #expect(abs(Double(state.viewOffsetPixels.target())) < 0.001)
        #expect(state.viewOffsetToRestore == nil)
    }

    @Test func endGesturePreservesRestoreOffsetWhenColumnDoesNotChange() {
        var state = ViewportState()
        state.viewOffsetToRestore = 99
        let columns = makeViewportGestureContainers(widths: [300, 300])
        _ = state.beginGesture(isTrackpad: false, columns: columns)

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 200,
            motion: .disabled,
            isTrackpad: false,
            centerMode: .never
        )

        #expect(state.activeColumnIndex == 0)
        #expect(state.viewOffsetToRestore == 99)
    }

    @Test func endGestureCanPreserveTrackpadOffsetWithoutSnapping() {
        var state = ViewportState()
        state.viewOffsetToRestore = 99
        let columns = makeViewportGestureContainers(widths: [300, 300, 300])
        _ = state.beginGesture(isTrackpad: true, columns: columns)

        _ = state.updateGesture(
            deltaPixels: 240,
            timestamp: 1.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 500
        )

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .enabled,
            isTrackpad: true,
            snapToColumn: false,
            centerMode: .never
        )

        #expect(state.activeColumnIndex == 0)
        #expect(state.viewOffsetPixels.isGesture == false)
        #expect(state.viewOffsetPixels.isAnimating == false)
        #expect(abs(Double(state.viewOffsetPixels.target()) - 100) < 0.001)
        #expect(state.viewOffsetToRestore == 99)

        _ = state.beginGesture(isTrackpad: true, columns: columns)
        _ = state.updateGesture(
            deltaPixels: 120,
            timestamp: 2.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 500
        )

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .enabled,
            isTrackpad: true,
            snapToColumn: false,
            centerMode: .never
        )

        #expect(abs(Double(state.viewOffsetPixels.target()) - 150) < 0.001)
    }

    @Test func slowTrackpadGestureSnapsBackToCurrentColumn() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [300, 300, 300])

        _ = state.beginGesture(isTrackpad: true, columns: columns)
        _ = state.updateGesture(
            deltaPixels: 20,
            timestamp: 1.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 500
        )
        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .disabled,
            isTrackpad: true,
            centerMode: .never,
            timestamp: 1.5
        )

        #expect(state.activeColumnIndex == 0)
        #expect(abs(Double(state.targetViewPosPixels(columns: columns, gap: 10)) + 10) < 0.001)
        #expect(abs(Double(state.viewOffsetPixels.target()) + 10) < 0.001)
    }

    @Test func fastTrackpadGestureUsesProjectedMomentumForSnapTarget() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [300, 300, 300])

        _ = state.beginGesture(isTrackpad: true, columns: columns)
        _ = state.updateGesture(
            deltaPixels: 200,
            timestamp: 1.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 500
        )
        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .disabled,
            isTrackpad: true,
            centerMode: .never,
            timestamp: 1.016
        )

        #expect(state.activeColumnIndex == 2)
        #expect(abs(Double(state.targetViewPosPixels(columns: columns, gap: 10)) - 430) < 0.001)
        #expect(abs(Double(state.viewOffsetPixels.target()) + 190) < 0.001)
    }

    @Test func trackpadMomentumSnapAtStripEndNeverWrapsToFront() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [300, 300, 300, 300, 300])

        _ = state.beginGesture(isTrackpad: true, columns: columns)
        _ = state.updateGesture(
            deltaPixels: 2_000,
            timestamp: 1.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 500
        )
        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .disabled,
            isTrackpad: true,
            centerMode: .never,
            timestamp: 1.016
        )

        #expect(state.activeColumnIndex == 4)
        #expect(abs(Double(state.targetViewPosPixels(columns: columns, gap: 10)) - 1_050) < 0.001)
        #expect(abs(Double(state.viewOffsetPixels.target()) + 190) < 0.001)
    }

    @Test func preservedTrackpadOffsetKeepsHalfVisibleActiveColumn() {
        var state = ViewportState()
        state.viewOffsetToRestore = 99
        let columns = makeViewportGestureContainers(widths: [300, 300, 300])
        _ = state.beginGesture(isTrackpad: true, columns: columns)
        state.viewOffsetPixels.gestureRef?.applyDelta(120)

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .enabled,
            isTrackpad: true,
            snapToColumn: false,
            centerMode: .never
        )

        #expect(state.activeColumnIndex == 0)
        #expect(abs(Double(state.targetViewPosPixels(columns: columns, gap: 10)) - 120) < 0.001)
        #expect(abs(Double(state.viewOffsetPixels.target()) - 120) < 0.001)
        #expect(state.viewOffsetToRestore == 99)
    }

    @Test func preservedTrackpadOffsetRebasesToMostVisibleColumnWithoutMovingView() {
        var state = ViewportState()
        state.viewOffsetToRestore = 99
        let columns = makeViewportGestureContainers(widths: [300, 300, 300])
        _ = state.beginGesture(isTrackpad: true, columns: columns)
        state.viewOffsetPixels.gestureRef?.applyDelta(220)

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .enabled,
            isTrackpad: true,
            snapToColumn: false,
            centerMode: .never
        )

        #expect(state.activeColumnIndex == 1)
        #expect(abs(Double(state.targetViewPosPixels(columns: columns, gap: 10)) - 220) < 0.001)
        #expect(abs(Double(state.viewOffsetPixels.target()) + 90) < 0.001)
        #expect(state.viewOffsetToRestore == nil)
    }

    @Test func preservedTrackpadOffsetClampsAtStripEndWithoutWrappingToFront() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [300, 300, 300, 300, 300])
        _ = state.beginGesture(isTrackpad: true, columns: columns)
        state.viewOffsetPixels.gestureRef?.applyDelta(10_000)

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 500,
            motion: .enabled,
            isTrackpad: true,
            snapToColumn: false,
            centerMode: .never
        )

        #expect(state.activeColumnIndex == 4)
        #expect(abs(Double(state.targetViewPosPixels(columns: columns, gap: 10)) - 1_040) < 0.001)
        #expect(abs(Double(state.viewOffsetPixels.target()) + 200) < 0.001)
    }

    @Test func endGesturePreservingTrackpadOffsetClampsPastContentBounds() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [300, 300])
        _ = state.beginGesture(isTrackpad: true, columns: columns)

        _ = state.updateGesture(
            deltaPixels: 10_000,
            timestamp: 1.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 200
        )

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 200,
            motion: .disabled,
            isTrackpad: true,
            snapToColumn: false,
            centerMode: .never
        )

        #expect(state.activeColumnIndex == 1)
        #expect(abs(Double(state.targetViewPosPixels(columns: columns, gap: 10)) - 410) < 0.001)
        #expect(abs(Double(state.viewOffsetPixels.target()) - 100) < 0.001)
    }

    @Test func gestureIgnoresMismatchedInputSource() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [300, 300])
        _ = state.beginGesture(isTrackpad: false, columns: columns)

        _ = state.updateGesture(
            deltaPixels: 500,
            timestamp: 1.0,
            isTrackpad: true,
            columns: columns,
            gap: 10,
            viewportWidth: 200
        )

        guard let gesture = state.viewOffsetPixels.gestureRef else {
            Issue.record("Expected gesture to remain active after mismatched update")
            return
        }
        #expect(gesture.currentViewOffset == 0)

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 200,
            motion: .disabled,
            isTrackpad: true,
            centerMode: .never
        )

        #expect(state.viewOffsetPixels.isGesture)
    }

    @Test func endGestureUsesParentFrameRightStrutForSnapTarget() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [900, 900])
        _ = state.beginGesture(isTrackpad: false, columns: columns)

        _ = state.updateGesture(
            deltaPixels: 2_000,
            timestamp: 1.0,
            isTrackpad: false,
            columns: columns,
            gap: 10,
            viewportWidth: 1_000
        )

        state.endGesture(
            columns: columns,
            gap: 10,
            viewportWidth: 1_000,
            motion: .disabled,
            isTrackpad: false,
            centerMode: .never,
            workingArea: CGRect(x: 100, y: 0, width: 1_000, height: 800),
            viewFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )

        #expect(state.activeColumnIndex == 1)
        #expect(abs(Double(state.viewOffsetPixels.target()) + 190) < 0.001)
    }

    @Test func updateGestureReturnsNilForZeroWidthSingleColumn() {
        var state = ViewportState()
        let columns = makeViewportGestureContainers(widths: [0])
        _ = state.beginGesture(isTrackpad: true, columns: columns)

        let steps = state.updateGesture(
            deltaPixels: 120,
            timestamp: 1.0,
            columns: columns,
            gap: 8,
            viewportWidth: 1_200
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
            .init(label: "zero-width column", columns: makeViewportGestureContainers(widths: [0])),
        ]

        for scenario in scenarios {
            var state = ViewportState()
            state.activeColumnIndex = 2
            state.viewOffsetPixels = .static(-32)
            state.selectionProgress = 17
            state.viewOffsetToRestore = 99
            state.activatePrevColumnOnRemoval = 42

            guard state.beginGesture(isTrackpad: false, columns: scenario.columns) else {
                #expect(scenario.columns.isEmpty, Comment(rawValue: scenario.label))
                #expect(state.viewOffsetPixels.isGesture == false, Comment(rawValue: scenario.label))
                continue
            }

            guard let gesture = state.viewOffsetPixels.gestureRef else {
                Issue.record("Expected gesture state for \(scenario.label)")
                continue
            }

            gesture.currentViewOffset = -123.5

            state.endGesture(
                columns: scenario.columns,
                gap: 8,
                viewportWidth: 1_200,
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
}
