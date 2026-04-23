// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation

private let viewGestureWorkingAreaMovement: Double = 1200.0

extension ViewportState {
    mutating func beginGesture(isTrackpad: Bool) {
        let currentOffset = viewOffsetPixels.current()
        viewOffsetPixels = .gesture(ViewGesture(currentViewOffset: Double(currentOffset), isTrackpad: isTrackpad))
        selectionProgress = 0.0
    }

    mutating func updateGesture(
        deltaPixels: CGFloat,
        timestamp: TimeInterval,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat
    ) -> Int? {
        guard case let .gesture(gesture) = viewOffsetPixels else {
            return nil
        }

        gesture.tracker.push(delta: Double(deltaPixels), timestamp: timestamp)

        let normFactor = gesture.isTrackpad
            ? Double(viewportWidth) / viewGestureWorkingAreaMovement
            : 1.0
        let pos = gesture.tracker.position * normFactor
        let viewOffset = pos + gesture.deltaFromTracker

        guard !columns.isEmpty else {
            gesture.currentViewOffset = viewOffset
            return nil
        }

        gesture.currentViewOffset = viewOffset

        let totalColumnWidth = Double(totalPlanningWidth(columns: columns, gap: gap))
        guard totalColumnWidth.isFinite, totalColumnWidth > 0 else {
            return nil
        }

        let avgColumnWidth = totalColumnWidth / Double(columns.count)
        guard avgColumnWidth.isFinite, avgColumnWidth > 0 else {
            return nil
        }
        selectionProgress += deltaPixels * CGFloat(normFactor)
        let steps = Int((selectionProgress / CGFloat(avgColumnWidth)).rounded(.towardZero))
        if steps != 0 {
            selectionProgress -= CGFloat(steps) * CGFloat(avgColumnWidth)
            return steps
        }
        return nil
    }

    mutating func endGesture(
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        motion: MotionSnapshot,
        centerMode: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false
    ) {
        guard case let .gesture(gesture) = viewOffsetPixels else {
            return
        }

        let currentOffset = gesture.current()

        guard !columns.isEmpty else {
            endGestureWithoutSnap(currentOffset: currentOffset)
            return
        }

        let totalColumnWidth = Double(totalPlanningWidth(columns: columns, gap: gap))
        guard totalColumnWidth.isFinite, totalColumnWidth > 0 else {
            endGestureWithoutSnap(currentOffset: currentOffset)
            return
        }

        let normFactor = gesture.isTrackpad
            ? Double(viewportWidth) / viewGestureWorkingAreaMovement
            : 1.0
        let velocity = gesture.currentVelocity() * normFactor
        let projectedTrackerPos = gesture.tracker.projectedEndPosition() * normFactor
        let projectedOffset = projectedTrackerPos + gesture.deltaFromTracker

        let activeColX = columnPlanningX(at: activeColumnIndex, columns: columns, gap: gap)
        let currentViewPos = Double(activeColX) + currentOffset
        let projectedViewPos = Double(activeColX) + projectedOffset

        let result = planningSnapTarget(
            projectedViewPos: projectedViewPos,
            currentViewPos: currentViewPos,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        let newColX = columnPlanningX(at: result.columnIndex, columns: columns, gap: gap)
        let offsetDelta = activeColX - newColX

        activeColumnIndex = result.columnIndex

        let targetOffset = result.viewPos - Double(newColX)

        guard motion.animationsEnabled else {
            viewOffsetPixels = .static(CGFloat(targetOffset))
            activatePrevColumnOnRemoval = nil
            viewOffsetToRestore = nil
            selectionProgress = 0.0
            preserveViewportDuringTopologySync = false
            return
        }

        let now = animationClock?.now() ?? CACurrentMediaTime()
        let animation = SpringAnimation(
            from: currentOffset + Double(offsetDelta),
            to: targetOffset,
            initialVelocity: velocity,
            startTime: now,
            config: springConfig,
            displayRefreshRate: displayRefreshRate
        )
        viewOffsetPixels = .spring(animation)

        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
        selectionProgress = 0.0
        preserveViewportDuringTopologySync = false
    }

    private mutating func endGestureWithoutSnap(currentOffset: Double) {
        viewOffsetPixels = .static(CGFloat(currentOffset))
        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
        selectionProgress = 0.0
        preserveViewportDuringTopologySync = false
    }

}
