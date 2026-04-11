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
        motion: MotionSnapshot,
        centerMode: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false,
        snapToColumnBoundaries: Bool = false
    ) {
        guard case let .gesture(gesture) = viewOffsetPixels else {
            return
        }

        let velocity = gesture.currentVelocity()
        let currentOffset = gesture.current()

        let normFactor = gesture.isTrackpad
            ? Double(viewportWidth) / viewGestureWorkingAreaMovement
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
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            snapToColumnBoundaries: snapToColumnBoundaries
        )

        let newColX = columnX(at: result.columnIndex, columns: columns, gap: gap)
        let offsetDelta = activeColX - newColX

        activeColumnIndex = result.columnIndex

        let targetOffset = result.viewPos - Double(newColX)

        let totalW = totalWidth(columns: columns, gap: gap)
        let maxOffset: Double = 0
        let minOffset = Double(viewportWidth - totalW)
        let clampedTarget = min(max(targetOffset, minOffset), maxOffset)

        guard motion.animationsEnabled else {
            viewOffsetPixels = .static(CGFloat(clampedTarget))
            activatePrevColumnOnRemoval = nil
            viewOffsetToRestore = nil
            selectionProgress = 0.0
            return
        }

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
        alwaysCenterSingleColumn: Bool = false,
        snapToColumnBoundaries: Bool = false
    ) -> SnapResult {
        guard !columns.isEmpty else { return SnapResult(viewPos: 0, columnIndex: 0) }

        let effectiveCenterMode = (columns.count == 1 && alwaysCenterSingleColumn) ? .always : centerMode

        let vw = Double(viewportWidth)
        let gaps = Double(gap)
        var snapPoints: [(viewPos: Double, columnIndex: Int)] = []

        if effectiveCenterMode == .always {
            for (idx, _) in columns.enumerated() {
                let colX = Double(columnX(at: idx, columns: columns, gap: gap))
                let offset = Double(computeCenteredOffset(
                    columnIndex: idx,
                    columns: columns,
                    gap: gap,
                    viewportWidth: viewportWidth
                ))
                let snapViewPos = colX + offset
                snapPoints.append((snapViewPos, idx))
            }
        } else if snapToColumnBoundaries {
            var colX: Double = 0
            for (idx, col) in columns.enumerated() {
                let colW = Double(col.cachedWidth)
                // Snap point: column left edge aligned to viewport left edge
                snapPoints.append((colX, idx))
                colX += colW + gaps
            }
        } else {
            var colX: Double = 0
            for (idx, col) in columns.enumerated() {
                let colW = Double(col.cachedWidth)
                let padding = max(0, min((vw - colW) / 2.0, gaps))

                let leftSnap = colX - padding
                let rightSnap = colX + colW + padding - vw

                snapPoints.append((leftSnap, idx))
                if rightSnap != leftSnap {
                    snapPoints.append((rightSnap, idx))
                }
                colX += colW + gaps
            }
        }

        let totalW = Double(totalWidth(columns: columns, gap: gap))
        let maxViewPos: Double = 0
        let minViewPos = vw - totalW

        let clampedSnaps = snapPoints.map { snap -> (viewPos: Double, columnIndex: Int) in
            let clampedPos = min(max(snap.viewPos, minViewPos), maxViewPos)
            return (clampedPos, snap.columnIndex)
        }

        guard let closest = clampedSnaps.min(by: { abs($0.viewPos - projectedViewPos) < abs($1.viewPos - projectedViewPos) }) else {
            return SnapResult(viewPos: 0, columnIndex: 0)
        }

        var newColIdx = closest.columnIndex

        if effectiveCenterMode != .always {
            let scrollingRight = projectedViewPos >= currentViewPos
            if scrollingRight {
                for idx in (newColIdx + 1) ..< columns.count {
                    let colX = Double(columnX(at: idx, columns: columns, gap: gap))
                    let colW = Double(columns[idx].cachedWidth)
                    let padding = snapToColumnBoundaries ? 0.0 : max(0, min((vw - colW) / 2.0, gaps))
                    if closest.viewPos + vw >= colX + colW + padding {
                        newColIdx = idx
                    } else {
                        break
                    }
                }
            } else {
                for idx in stride(from: newColIdx - 1, through: 0, by: -1) {
                    let colX = Double(columnX(at: idx, columns: columns, gap: gap))
                    let colW = Double(columns[idx].cachedWidth)
                    let padding = snapToColumnBoundaries ? 0.0 : max(0, min((vw - colW) / 2.0, gaps))
                    if colX - padding >= closest.viewPos {
                        newColIdx = idx
                    } else {
                        break
                    }
                }
            }
        }

        return SnapResult(viewPos: closest.viewPos, columnIndex: newColIdx)
    }
}
