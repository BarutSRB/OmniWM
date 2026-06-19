// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension ViewportState {
    mutating func endGesture(
        currentOffset: Double,
        projectedOffset: Double,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        motion: MotionSnapshot,
        snapToColumn: Bool = true,
        centerMode: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false,
        workingArea: CGRect? = nil,
        viewFrame: CGRect? = nil,
        scale: CGFloat = 2.0
    ) {
        guard !columns.isEmpty else {
            endGestureWithoutSnap(currentOffset: currentOffset)
            return
        }

        let totalColumnWidth = Double(totalWidth(columns: columns, gap: gap))
        guard totalColumnWidth.isFinite, totalColumnWidth > 0 else {
            endGestureWithoutSnap(currentOffset: currentOffset)
            return
        }

        guard snapToColumn else {
            endGestureWithMomentum(
                projectedOffset: projectedOffset,
                columns: columns,
                gap: gap,
                viewportWidth: viewportWidth,
                totalColumnWidth: totalColumnWidth,
                motion: motion
            )
            return
        }

        let activeColX = columnX(at: activeColumnIndex, columns: columns, gap: gap)
        let projectedViewPos = Double(activeColX) + projectedOffset
        let areas = normalizedFittingAreas(
            viewportSpan: viewportWidth,
            workingArea: workingArea,
            viewFrame: viewFrame,
            orientation: .horizontal,
            scale: scale
        )

        let result = findSnapPointsAndTarget(
            projectedViewPos: projectedViewPos,
            projectedOffset: projectedOffset,
            currentOffset: currentOffset,
            columns: columns,
            gap: gap,
            areas: areas,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        let newColX = columnX(at: result.columnIndex, columns: columns, gap: gap)
        let offsetDelta = activeColX - newColX

        let previousActiveColumnIndex = activeColumnIndex
        activeColumnIndex = result.columnIndex
        if previousActiveColumnIndex != result.columnIndex {
            viewOffsetToRestore = nil
        }

        let snapTargetOffset = result.viewPos - Double(newColX)
        let correctedTargetOffset = correctedGestureTargetOffset(
            targetViewPos: result.viewPos,
            columnIndex: result.columnIndex,
            columns: columns,
            gap: gap,
            areas: areas,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )
        let pixel = 1.0 / Double(max(areas.scale, 1.0))
        let targetOffset = abs(correctedTargetOffset - snapTargetOffset) < pixel
            ? snapTargetOffset
            : correctedTargetOffset

        guard motion.animationsEnabled else {
            jumpOffset(to: CGFloat(targetOffset))
            activatePrevColumnOnRemoval = nil
            selectionProgress = 0.0
            return
        }

        rebaseOffset(by: offsetDelta)
        springOffset(to: CGFloat(targetOffset))

        activatePrevColumnOnRemoval = nil
        selectionProgress = 0.0
    }

    struct SnapResult {
        let viewPos: Double
        let columnIndex: Int
    }

    private struct SnapPoint {
        let viewPos: Double
        let columnIndex: Int
    }

    private struct PreservedGestureOffset {
        let finalOffset: Double
        let normalizedActiveColumn: Int
    }

    private func findSnapPointsAndTarget(
        projectedViewPos: Double,
        projectedOffset: Double,
        currentOffset: Double,
        columns: [NiriContainer],
        gap: CGFloat,
        areas: ViewportFittingAreas,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false
    ) -> SnapResult {
        guard !columns.isEmpty else { return SnapResult(viewPos: 0, columnIndex: 0) }

        let isCentering = centerMode == .always || (alwaysCenterSingleColumn && columns.count <= 1)
        let viewWidth = Double(areas.viewSpan)
        let gaps = Double(gap)
        var snapPoints: [SnapPoint] = []

        if isCentering {
            var colX = 0.0
            for (idx, col) in columns.enumerated() {
                let colW = Double(col.cachedWidth)
                let mode = col.effectiveSizingMode
                let area = areas.area(for: mode)
                let areaWidth = Double(areas.span(of: area))
                let leftStrut = Double(areas.origin(of: area))

                let viewPos: Double
                if mode.isFullscreen {
                    viewPos = colX
                } else if areaWidth <= colW {
                    viewPos = colX - leftStrut
                } else {
                    viewPos = colX - (areaWidth - colW) / 2.0 - leftStrut
                }
                appendSnapPoint(viewPos, idx, to: &snapPoints)

                colX += colW + gaps
            }
        } else {
            let centerOnOverflow = centerMode == .onOverflow

            func snapPair(
                colX: Double,
                column: NiriContainer,
                prevColWidth: Double?,
                nextColWidth: Double?
            ) -> (left: Double, right: Double) {
                let colW = Double(column.cachedWidth)
                let mode = column.effectiveSizingMode

                if mode.isFullscreen {
                    return (colX, colX + colW)
                }

                let area = areas.area(for: mode)
                let areaWidth = Double(areas.span(of: area))
                let leftStrut = Double(areas.origin(of: area))
                let rightStrut = viewWidth - areaWidth - leftStrut
                let padding = mode.isMaximized ? 0 : ((areaWidth - colW) / 2.0).clamped(to: 0 ... gaps)
                let center = if areaWidth <= colW {
                    colX - leftStrut
                } else {
                    colX - (areaWidth - colW) / 2.0 - leftStrut
                }

                let isOverflowing: (Double?) -> Bool = { adjacentWidth in
                    guard centerOnOverflow, let adjacentWidth else { return false }
                    return adjacentWidth + 3.0 * gaps + colW > areaWidth
                }

                let left = isOverflowing(nextColWidth) ? center : colX - padding - leftStrut
                let right = isOverflowing(prevColWidth) ? center + viewWidth : colX + colW + padding + rightStrut
                return (left, right)
            }

            // Match Niri's snap-boundary guard: gestures may only snap within the first and last
            // column boundary points, which prevents high momentum at the strip ends from wrapping
            // or choosing an interior snap that would feel like scrolling past the content.
            let leftmostSnap = snapPair(
                colX: 0,
                column: columns[0],
                prevColWidth: nil,
                nextColWidth: columns.dropFirst().first.map { Double($0.cachedWidth) }
            ).left
            let lastColIdx = columns.count - 1
            let lastColX = Double(columnX(at: lastColIdx, columns: columns, gap: gap))
            let rightmostSnap = snapPair(
                colX: lastColX,
                column: columns[lastColIdx],
                prevColWidth: lastColIdx > 0 ? Double(columns[lastColIdx - 1].cachedWidth) : nil,
                nextColWidth: nil
            ).right - viewWidth

            appendSnapPoint(leftmostSnap, 0, to: &snapPoints)
            appendSnapPoint(rightmostSnap, lastColIdx, to: &snapPoints)

            func push(_ colIdx: Int, _ left: Double, _ right: Double) {
                if leftmostSnap < left, left < rightmostSnap {
                    appendSnapPoint(left, colIdx, to: &snapPoints)
                }

                let rightViewPos = right - viewWidth
                if leftmostSnap < rightViewPos, rightViewPos < rightmostSnap {
                    appendSnapPoint(rightViewPos, colIdx, to: &snapPoints)
                }
            }

            var colX = 0.0
            for (idx, col) in columns.enumerated() {
                let pair = snapPair(
                    colX: colX,
                    column: col,
                    prevColWidth: idx > 0 ? Double(columns[idx - 1].cachedWidth) : nil,
                    nextColWidth: idx + 1 < columns.count ? Double(columns[idx + 1].cachedWidth) : nil
                )
                push(idx, pair.left, pair.right)

                colX += Double(col.cachedWidth) + gaps
            }
        }

        snapPoints.sort { $0.viewPos < $1.viewPos }
        guard let closest = snapPoints
            .min(by: { abs($0.viewPos - projectedViewPos) < abs($1.viewPos - projectedViewPos) })
        else {
            return SnapResult(viewPos: 0, columnIndex: 0)
        }

        var newColIdx = closest.columnIndex

        if !isCentering {
            let scrollingRight = projectedOffset >= currentOffset
            if scrollingRight {
                for idx in (newColIdx + 1) ..< columns.count {
                    let colX = Double(columnX(at: idx, columns: columns, gap: gap))
                    let colW = Double(columns[idx].cachedWidth)
                    let mode = columns[idx].effectiveSizingMode
                    let area = areas.area(for: mode)

                    if mode.isFullscreen {
                        if closest.viewPos + viewWidth < colX + colW {
                            break
                        }
                    } else {
                        let areaWidth = Double(areas.span(of: area))
                        let leftStrut = Double(areas.origin(of: area))
                        let padding = mode.isMaximized ? 0 : ((areaWidth - colW) / 2.0).clamped(to: 0 ... gaps)
                        if closest.viewPos + leftStrut + areaWidth < colX + colW + padding {
                            break
                        }
                    }

                    newColIdx = idx
                }
            } else {
                for idx in stride(from: newColIdx - 1, through: 0, by: -1) {
                    let colX = Double(columnX(at: idx, columns: columns, gap: gap))
                    let colW = Double(columns[idx].cachedWidth)
                    let mode = columns[idx].effectiveSizingMode
                    let area = areas.area(for: mode)

                    if mode.isFullscreen {
                        if colX < closest.viewPos {
                            break
                        }
                    } else {
                        let areaWidth = Double(areas.span(of: area))
                        let leftStrut = Double(areas.origin(of: area))
                        let padding = mode.isMaximized ? 0 : ((areaWidth - colW) / 2.0).clamped(to: 0 ... gaps)
                        if colX - padding < closest.viewPos + leftStrut {
                            break
                        }
                    }

                    newColIdx = idx
                }
            }
        }

        return SnapResult(viewPos: closest.viewPos, columnIndex: newColIdx)
    }

    private func correctedGestureTargetOffset(
        targetViewPos: Double,
        columnIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        areas: ViewportFittingAreas,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool
    ) -> Double {
        guard columns.indices.contains(columnIndex) else { return 0 }
        let colX = Double(columnX(at: columnIndex, columns: columns, gap: gap))
        let colW = Double(columns[columnIndex].cachedWidth)
        let mode = columns[columnIndex].effectiveSizingMode
        let isCentering = centerMode == .always || (alwaysCenterSingleColumn && columns.count <= 1)

        let offset = if isCentering {
            computeModeAwareCenteredOffset(
                currentViewStart: CGFloat(targetViewPos),
                targetPos: CGFloat(colX),
                targetSpan: CGFloat(colW),
                mode: mode,
                areas: areas,
                gap: gap
            )
        } else {
            computeModeAwareFitOffset(
                currentViewStart: CGFloat(targetViewPos),
                targetPos: CGFloat(colX),
                targetSpan: CGFloat(colW),
                mode: mode,
                areas: areas,
                gap: gap
            )
        }
        return Double(offset)
    }

    private func appendSnapPoint(_ viewPos: Double, _ columnIndex: Int, to snapPoints: inout [SnapPoint]) {
        guard viewPos.isFinite else { return }
        snapPoints.append(SnapPoint(viewPos: viewPos, columnIndex: columnIndex))
    }

    private mutating func endGestureWithMomentum(
        projectedOffset: Double,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        totalColumnWidth: Double,
        motion: MotionSnapshot
    ) {
        let oldActiveX = columnX(at: activeColumnIndex, columns: columns, gap: gap)

        guard let preserved = normalizedPreservedGestureOffset(
            currentOffset: projectedOffset,
            columns: columns,
            gap: gap,
            viewportWidth: Double(viewportWidth),
            totalColumnWidth: totalColumnWidth
        ) else {
            jumpOffset(to: CGFloat(projectedOffset))
            activatePrevColumnOnRemoval = nil
            selectionProgress = 0.0
            return
        }

        let newActiveX = columnX(at: preserved.normalizedActiveColumn, columns: columns, gap: gap)
        let offsetDelta = oldActiveX - newActiveX

        if activeColumnIndex != preserved.normalizedActiveColumn {
            viewOffsetToRestore = nil
        }
        activeColumnIndex = preserved.normalizedActiveColumn

        let maxViewStart = max(0, totalColumnWidth - Double(viewportWidth))
        let overscrolled = Double(oldActiveX) + projectedOffset < 0
            || Double(oldActiveX) + projectedOffset > maxViewStart

        guard motion.animationsEnabled else {
            jumpOffset(to: CGFloat(preserved.finalOffset))
            activatePrevColumnOnRemoval = nil
            selectionProgress = 0.0
            return
        }

        rebaseOffset(by: offsetDelta)
        if overscrolled {
            springOffset(to: CGFloat(preserved.finalOffset))
        } else {
            decelerateOffset(to: CGFloat(preserved.finalOffset))
        }
        activatePrevColumnOnRemoval = nil
        selectionProgress = 0.0
    }

    private func normalizedPreservedGestureOffset(
        currentOffset: Double,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: Double,
        totalColumnWidth: Double
    ) -> PreservedGestureOffset? {
        guard !columns.isEmpty,
              totalColumnWidth.isFinite,
              totalColumnWidth > 0,
              viewportWidth.isFinite,
              viewportWidth > 0
        else {
            return nil
        }

        let previousActiveColumn = activeColumnIndex.clamped(to: 0 ... columns.count - 1)
        let gap = Double(gap)
        var positions: [Double] = []
        positions.reserveCapacity(columns.count)
        var runningPosition = 0.0
        for column in columns {
            positions.append(runningPosition)
            runningPosition += Double(column.cachedWidth) + gap
        }

        let previousActiveX = positions[previousActiveColumn]
        let rawViewStart = previousActiveX + currentOffset
        let maxViewStart = max(0, totalColumnWidth - viewportWidth)
        let viewStart = rawViewStart.clamped(to: 0 ... maxViewStart)
        let viewEnd = viewStart + viewportWidth

        let currentColumnWidth = max(0, Double(columns[previousActiveColumn].cachedWidth))
        let currentColumnOverlap = visibleOverlap(
            start: previousActiveX,
            end: previousActiveX + currentColumnWidth,
            viewStart: viewStart,
            viewEnd: viewEnd
        )
        let normalizedActiveColumn: Int
        if currentColumnWidth > 0, currentColumnOverlap + 0.001 >= currentColumnWidth / 2.0 {
            normalizedActiveColumn = previousActiveColumn
        } else {
            let viewportCenter = viewStart + viewportWidth / 2.0
            var bestIndex = previousActiveColumn
            var bestOverlap = -Double.infinity
            var bestCenterDistance = Double.infinity

            for (index, column) in columns.enumerated() {
                let columnStart = positions[index]
                let columnWidth = max(0, Double(column.cachedWidth))
                let columnEnd = columnStart + columnWidth
                let overlap = visibleOverlap(
                    start: columnStart,
                    end: columnEnd,
                    viewStart: viewStart,
                    viewEnd: viewEnd
                )
                let centerDistance = abs((columnStart + columnEnd) / 2.0 - viewportCenter)

                if overlap > bestOverlap + 0.001 ||
                    (abs(overlap - bestOverlap) <= 0.001 && centerDistance < bestCenterDistance)
                {
                    bestIndex = index
                    bestOverlap = overlap
                    bestCenterDistance = centerDistance
                }
            }

            normalizedActiveColumn = bestIndex
        }

        let normalizedActiveX = positions[normalizedActiveColumn]
        return PreservedGestureOffset(
            finalOffset: viewStart - normalizedActiveX,
            normalizedActiveColumn: normalizedActiveColumn
        )
    }

    private func visibleOverlap(
        start: Double,
        end: Double,
        viewStart: Double,
        viewEnd: Double
    ) -> Double {
        max(0, min(end, viewEnd) - max(start, viewStart))
    }

    private mutating func endGestureWithoutSnap(currentOffset: Double) {
        jumpOffset(to: CGFloat(currentOffset))
        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
        selectionProgress = 0.0
    }
}
