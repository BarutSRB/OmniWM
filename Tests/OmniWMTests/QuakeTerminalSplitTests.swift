// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Testing

@testable import OmniWM

@Suite @MainActor struct QuakeTerminalSplitTests {
    private let containerBounds = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let horizontalPaneBounds = CGRect(x: 0, y: 0, width: 200, height: 300)
    private let verticalPaneBounds = CGRect(x: 0, y: 0, width: 400, height: 150)
    private let edgeThreshold: CGFloat = 8

    @Test func singlePaneStillReportsOuterWindowResizeEdges() {
        let edges = GhosttySurfaceResizeEdgeClassifier.classifyEdges(
            at: CGPoint(x: 399, y: 299),
            localBounds: containerBounds,
            paneFrame: containerBounds,
            containerBounds: containerBounds,
            threshold: edgeThreshold
        )

        #expect(edges == [.top, .right])
    }

    @Test func leftPaneSuppressesInternalRightEdgeButKeepsOuterLeftEdge() {
        let internalEdge = GhosttySurfaceResizeEdgeClassifier.classifyEdges(
            at: CGPoint(x: 199, y: 150),
            localBounds: horizontalPaneBounds,
            paneFrame: CGRect(x: 0, y: 0, width: 200, height: 300),
            containerBounds: containerBounds,
            threshold: edgeThreshold
        )
        let outerEdge = GhosttySurfaceResizeEdgeClassifier.classifyEdges(
            at: CGPoint(x: 1, y: 150),
            localBounds: horizontalPaneBounds,
            paneFrame: CGRect(x: 0, y: 0, width: 200, height: 300),
            containerBounds: containerBounds,
            threshold: edgeThreshold
        )

        #expect(internalEdge.isEmpty)
        #expect(outerEdge == [.left])
    }

    @Test func rightPaneSuppressesInternalLeftEdgeButKeepsOuterRightEdge() {
        let internalEdge = GhosttySurfaceResizeEdgeClassifier.classifyEdges(
            at: CGPoint(x: 1, y: 150),
            localBounds: horizontalPaneBounds,
            paneFrame: CGRect(x: 200, y: 0, width: 200, height: 300),
            containerBounds: containerBounds,
            threshold: edgeThreshold
        )
        let outerEdge = GhosttySurfaceResizeEdgeClassifier.classifyEdges(
            at: CGPoint(x: 199, y: 150),
            localBounds: horizontalPaneBounds,
            paneFrame: CGRect(x: 200, y: 0, width: 200, height: 300),
            containerBounds: containerBounds,
            threshold: edgeThreshold
        )

        #expect(internalEdge.isEmpty)
        #expect(outerEdge == [.right])
    }

    @Test func verticalPanesSuppressInternalBoundaryButKeepOuterPerimeterEdges() {
        let topInternalEdge = GhosttySurfaceResizeEdgeClassifier.classifyEdges(
            at: CGPoint(x: 200, y: 1),
            localBounds: verticalPaneBounds,
            paneFrame: CGRect(x: 0, y: 150, width: 400, height: 150),
            containerBounds: containerBounds,
            threshold: edgeThreshold
        )
        let topOuterEdge = GhosttySurfaceResizeEdgeClassifier.classifyEdges(
            at: CGPoint(x: 200, y: 149),
            localBounds: verticalPaneBounds,
            paneFrame: CGRect(x: 0, y: 150, width: 400, height: 150),
            containerBounds: containerBounds,
            threshold: edgeThreshold
        )
        let bottomInternalEdge = GhosttySurfaceResizeEdgeClassifier.classifyEdges(
            at: CGPoint(x: 200, y: 149),
            localBounds: verticalPaneBounds,
            paneFrame: CGRect(x: 0, y: 0, width: 400, height: 150),
            containerBounds: containerBounds,
            threshold: edgeThreshold
        )
        let bottomOuterEdge = GhosttySurfaceResizeEdgeClassifier.classifyEdges(
            at: CGPoint(x: 200, y: 1),
            localBounds: verticalPaneBounds,
            paneFrame: CGRect(x: 0, y: 0, width: 400, height: 150),
            containerBounds: containerBounds,
            threshold: edgeThreshold
        )

        #expect(topInternalEdge.isEmpty)
        #expect(topOuterEdge == [.top])
        #expect(bottomInternalEdge.isEmpty)
        #expect(bottomOuterEdge == [.bottom])
    }

    @Test func dividerHitRectIsLargerThanVisibleDividerAndStaysCentered() {
        let root = SplitNode.split(
            .horizontal,
            0.5,
            .leaf(makeSurfaceView()),
            .leaf(makeSurfaceView())
        )

        let dividerInfos = root.calculateDividers(
            in: containerBounds,
            visibleThickness: QuakeSplitDividerMetrics.visibleThickness,
            hitThickness: QuakeSplitDividerMetrics.hitThickness
        )

        #expect(dividerInfos.count == 1)

        guard let info = dividerInfos.first else {
            Issue.record("Expected exactly one divider for a two-pane split")
            return
        }

        #expect(info.hitRect.width > info.visibleRect.width)
        #expect(info.hitRect.height == info.visibleRect.height)
        #expect(abs(info.hitRect.midX - info.visibleRect.midX) < 0.001)
        #expect(abs(info.hitRect.midX - 200) < 0.001)
    }

    @Test func nestedDividerDragUpdatesOnlyAddressedSplitAcrossIncrementalEvents() {
        let left = makeSurfaceView()
        let topRight = makeSurfaceView()
        let bottomRight = makeSurfaceView()
        let container = QuakeSplitContainer(initialView: left)
        container.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)

        container.split(view: left, direction: .horizontal, newView: topRight)
        container.split(view: topRight, direction: .vertical, newView: bottomRight)

        let dividerInfos = container.root.calculateDividers(
            in: container.bounds,
            visibleThickness: QuakeSplitDividerMetrics.visibleThickness,
            hitThickness: QuakeSplitDividerMetrics.hitThickness
        )

        guard let nestedDivider = dividerInfos.first(where: {
            $0.address == [.right] && $0.direction == .vertical
        }) else {
            Issue.record("Expected a nested divider for the right-side vertical split")
            return
        }

        container.handleDividerDrag(info: nestedDivider, delta: 60)
        container.handleDividerDrag(info: nestedDivider, delta: 60)

        #expect(abs((container.root.ratio(at: []) ?? 0) - 0.5) < 0.001)
        #expect(abs((container.root.ratio(at: [.right]) ?? 0) - 0.7) < 0.001)
    }

    @Test func activeDividerViewSurvivesRepeatedDragUpdates() {
        let left = makeSurfaceView()
        let topRight = makeSurfaceView()
        let bottomRight = makeSurfaceView()
        let container = QuakeSplitContainer(initialView: left)
        container.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)

        container.split(view: left, direction: .horizontal, newView: topRight)
        container.split(view: topRight, direction: .vertical, newView: bottomRight)

        let address: SplitNode.SplitAddress = [.right]

        guard let dividerInfo = container.root.calculateDividers(
            in: container.bounds,
            visibleThickness: QuakeSplitDividerMetrics.visibleThickness,
            hitThickness: QuakeSplitDividerMetrics.hitThickness
        ).first(where: { $0.address == address && $0.direction == .vertical }) else {
            Issue.record("Expected a nested divider for the right-side vertical split")
            return
        }

        guard let activeDividerView = container.dividerViewForTesting(at: address) else {
            Issue.record("Expected divider view to exist before drag")
            return
        }

        container.handleDividerDrag(info: dividerInfo, delta: 60)
        container.handleDividerDrag(info: dividerInfo, delta: 60)

        #expect(activeDividerView.superview === container)
        #expect(container.dividerViewForTesting(at: address) === activeDividerView)
        #expect(abs((container.root.ratio(at: []) ?? 0) - 0.5) < 0.001)
        #expect(abs((container.root.ratio(at: address) ?? 0) - 0.7) < 0.001)
    }

    private func makeSurfaceView() -> GhosttySurfaceView {
        GhosttySurfaceView(testFrame: CGRect(x: 0, y: 0, width: 200, height: 150))
    }
}
