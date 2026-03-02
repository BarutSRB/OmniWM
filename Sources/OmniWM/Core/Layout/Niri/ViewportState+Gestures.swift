import AppKit
import Foundation

private let VIEW_GESTURE_WORKING_AREA_MOVEMENT: Double = 1200.0

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
            ? Double(viewportWidth) / VIEW_GESTURE_WORKING_AREA_MOVEMENT
            : 1.0
        let pos = gesture.tracker.position * normFactor
        let viewOffset = pos + gesture.deltaFromTracker

        guard !columns.isEmpty else {
            gesture.currentViewOffset = viewOffset
            return nil
        }

        let activeColX = Double(columnX(at: activeColumnIndex, columns: columns, gap: gap))
        let totalW = Double(totalWidth(columns: columns, gap: gap))
        var leftmost = 0.0
        var rightmost = max(0, totalW - Double(viewportWidth))
        leftmost -= activeColX
        rightmost -= activeColX

        let minOffset = min(leftmost, rightmost)
        let maxOffset = max(leftmost, rightmost)
        let clampedOffset = Swift.min(Swift.max(viewOffset, minOffset), maxOffset)

        gesture.deltaFromTracker += clampedOffset - viewOffset
        gesture.currentViewOffset = clampedOffset

        let avgColumnWidth = Double(totalWidth(columns: columns, gap: gap)) / Double(columns.count)
        selectionProgress += deltaPixels
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
        centerMode: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false
    ) {
        guard case let .gesture(gesture) = viewOffsetPixels else {
            return
        }

        let velocity = gesture.currentVelocity()
        let currentOffset = gesture.current()

        let normFactor = gesture.isTrackpad
            ? Double(viewportWidth) / VIEW_GESTURE_WORKING_AREA_MOVEMENT
            : 1.0
        let projectedTrackerPos = gesture.tracker.projectedEndPosition() * normFactor
        let projectedOffset = projectedTrackerPos + gesture.deltaFromTracker

        let activeColX = columnX(at: activeColumnIndex, columns: columns, gap: gap)
        let currentViewPos = Double(activeColX) + currentOffset
        let projectedViewPos = Double(activeColX) + projectedOffset

        let result = findSnapPointsAndTarget(
            projectedViewPos: projectedViewPos,
            currentViewPos: currentViewPos,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        let newColX = columnX(at: result.columnIndex, columns: columns, gap: gap)
        let offsetDelta = activeColX - newColX

        activeColumnIndex = result.columnIndex

        let targetOffset = result.viewPos - Double(newColX)

        let totalW = totalWidth(columns: columns, gap: gap)
        let maxOffset: Double = 0
        let minOffset = Double(viewportWidth - totalW)
        let clampedTarget = min(max(targetOffset, minOffset), maxOffset)

        let now = animationClock?.now() ?? CACurrentMediaTime()
        let animation = SpringAnimation(
            from: currentOffset + Double(offsetDelta),
            to: clampedTarget,
            initialVelocity: velocity,
            startTime: now,
            config: springConfig,
            displayRefreshRate: displayRefreshRate
        )
        viewOffsetPixels = .spring(animation)

        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
        selectionProgress = 0.0
    }

    struct SnapResult {
        let viewPos: Double
        let columnIndex: Int
    }

    private func findSnapPointsAndTarget(
        projectedViewPos: Double,
        currentViewPos: Double,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false
    ) -> SnapResult {
        let spans = columns.map { Double($0.cachedWidth) }
        return NiriViewportZigMath.findSnapTarget(
            spans: spans,
            gap: gap,
            viewportSpan: viewportWidth,
            projectedViewPos: projectedViewPos,
            currentViewPos: currentViewPos,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )
    }
}
