import AppKit
import Foundation

private let VIEW_GESTURE_WORKING_AREA_MOVEMENT: Double = 1200.0

extension ViewportState {
    @discardableResult
    mutating func beginGesture(isTrackpad: Bool, columns: [NiriContainer]) -> Bool {
        guard !columns.isEmpty else { return false }
        let currentOffset = viewOffsetPixels.current()
        viewOffsetPixels = .gesture(ViewGesture(currentViewOffset: Double(currentOffset), isTrackpad: isTrackpad))
        selectionProgress = 0.0
        return true
    }

    mutating func updateGesture(
        deltaPixels: CGFloat,
        timestamp: TimeInterval,
        isTrackpad: Bool? = nil,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat
    ) -> Int? {
        guard case let .gesture(gesture) = viewOffsetPixels else {
            return nil
        }
        if let isTrackpad, isTrackpad != gesture.isTrackpad {
            return nil
        }

        gesture.tracker.push(delta: Double(deltaPixels), timestamp: timestamp)

        let normFactor = gesture.isTrackpad
            ? Double(viewportWidth) / VIEW_GESTURE_WORKING_AREA_MOVEMENT
            : 1.0
        let pos = gesture.tracker.position * normFactor
        let viewOffset = pos + gesture.deltaFromTracker

        gesture.currentViewOffset = viewOffset
        return nil
    }

    mutating func endGesture(
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        motion: MotionSnapshot,
        isTrackpad: Bool? = nil,
        snapToColumn: Bool = true,
        centerMode: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false,
        workingArea: CGRect? = nil,
        viewFrame: CGRect? = nil,
        scale: CGFloat = 2.0,
        timestamp: TimeInterval? = nil
    ) {
        guard case let .gesture(gesture) = viewOffsetPixels else {
            return
        }
        if let isTrackpad, isTrackpad != gesture.isTrackpad {
            return
        }

        let currentOffsetForFallback = gesture.current()
        let now = timestamp ?? animationClock?.now() ?? CACurrentMediaTime()
        gesture.tracker.push(delta: 0, timestamp: now)

        let normFactor = gesture.isTrackpad
            ? Double(viewportWidth) / VIEW_GESTURE_WORKING_AREA_MOVEMENT
            : 1.0
        let pos = gesture.tracker.position * normFactor
        let currentOffset = pos + gesture.deltaFromTracker

        guard !columns.isEmpty else {
            endGestureWithoutSnap(currentOffset: currentOffsetForFallback)
            return
        }

        let totalColumnWidth = Double(totalWidth(columns: columns, gap: gap))
        guard totalColumnWidth.isFinite, totalColumnWidth > 0 else {
            endGestureWithoutSnap(currentOffset: currentOffsetForFallback)
            return
        }

        gesture.currentViewOffset = currentOffset

        guard snapToColumn else {
            endGesturePreservingCurrentOffset(
                currentOffset: currentOffset,
                columns: columns,
                gap: gap,
                viewportWidth: viewportWidth
            )
            return
        }

        let velocity = gesture.tracker.velocity() * normFactor
        let projectedTrackerPos = gesture.tracker.projectedEndPosition() * normFactor
        let projectedOffset = projectedTrackerPos + gesture.deltaFromTracker

        let activeColX = columnX(at: activeColumnIndex, columns: columns, gap: gap)
        let projectedViewPos = Double(activeColX) + projectedOffset
        let areas = normalizedGestureAreas(
            viewportWidth: viewportWidth,
            workingArea: workingArea,
            viewFrame: viewFrame,
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
            viewOffsetPixels = .static(CGFloat(targetOffset))
            activatePrevColumnOnRemoval = nil
            selectionProgress = 0.0
            return
        }

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
        selectionProgress = 0.0
    }

    struct SnapResult {
        let viewPos: Double
        let columnIndex: Int
    }

    private struct GestureAreas {
        let working: CGRect
        let parent: CGRect
        let viewWidth: Double
        let scale: CGFloat
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
        areas: GestureAreas,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false
    ) -> SnapResult {
        guard !columns.isEmpty else { return SnapResult(viewPos: 0, columnIndex: 0) }

        let isCentering = centerMode == .always || (alwaysCenterSingleColumn && columns.count <= 1)
        let viewWidth = areas.viewWidth
        let gaps = Double(gap)
        var snapPoints: [SnapPoint] = []

        if isCentering {
            var colX = 0.0
            for (idx, col) in columns.enumerated() {
                let colW = Double(col.cachedWidth)
                let mode = sizingMode(for: col)
                let area = area(for: mode, areas: areas)
                let leftStrut = Double(area.minX)

                let viewPos: Double
                if mode.isFullscreen {
                    viewPos = colX
                } else if Double(area.width) <= colW {
                    viewPos = colX - leftStrut
                } else {
                    viewPos = colX - (Double(area.width) - colW) / 2.0 - leftStrut
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
                let mode = sizingMode(for: column)

                if mode.isFullscreen {
                    return (colX, colX + colW)
                }

                let area = area(for: mode, areas: areas)
                let areaWidth = Double(area.width)
                let leftStrut = Double(area.minX)
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
        guard let closest = snapPoints.min(by: { abs($0.viewPos - projectedViewPos) < abs($1.viewPos - projectedViewPos) }) else {
            return SnapResult(viewPos: 0, columnIndex: 0)
        }

        var newColIdx = closest.columnIndex

        if !isCentering {
            let scrollingRight = projectedOffset >= currentOffset
            if scrollingRight {
                for idx in (newColIdx + 1) ..< columns.count {
                    let colX = Double(columnX(at: idx, columns: columns, gap: gap))
                    let colW = Double(columns[idx].cachedWidth)
                    let mode = sizingMode(for: columns[idx])
                    let area = area(for: mode, areas: areas)

                    if mode.isFullscreen {
                        if closest.viewPos + viewWidth < colX + colW {
                            break
                        }
                    } else {
                        let padding = mode.isMaximized ? 0 : ((Double(area.width) - colW) / 2.0).clamped(to: 0 ... gaps)
                        if closest.viewPos + Double(area.minX) + Double(area.width) < colX + colW + padding {
                            break
                        }
                    }

                    newColIdx = idx
                }
            } else {
                for idx in stride(from: newColIdx - 1, through: 0, by: -1) {
                    let colX = Double(columnX(at: idx, columns: columns, gap: gap))
                    let colW = Double(columns[idx].cachedWidth)
                    let mode = sizingMode(for: columns[idx])
                    let area = area(for: mode, areas: areas)

                    if mode.isFullscreen {
                        if colX < closest.viewPos {
                            break
                        }
                    } else {
                        let padding = mode.isMaximized ? 0 : ((Double(area.width) - colW) / 2.0).clamped(to: 0 ... gaps)
                        if colX - padding < closest.viewPos + Double(area.minX) {
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
        areas: GestureAreas,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool
    ) -> Double {
        guard columns.indices.contains(columnIndex) else { return 0 }
        let colX = Double(columnX(at: columnIndex, columns: columns, gap: gap))
        let colW = Double(columns[columnIndex].cachedWidth)
        let mode = sizingMode(for: columns[columnIndex])
        let isCentering = centerMode == .always || (alwaysCenterSingleColumn && columns.count <= 1)

        if isCentering {
            return computeNewViewOffsetCentered(
                targetViewPos: targetViewPos,
                colX: colX,
                colW: colW,
                mode: mode,
                areas: areas,
                gap: gap
            )
        }

        return computeNewViewOffsetFit(
            targetViewPos: targetViewPos,
            colX: colX,
            colW: colW,
            mode: mode,
            areas: areas,
            gap: gap
        )
    }

    private func computeNewViewOffsetCentered(
        targetViewPos: Double,
        colX: Double,
        colW: Double,
        mode: SizingMode,
        areas: GestureAreas,
        gap: CGFloat
    ) -> Double {
        if mode.isFullscreen {
            return computeNewViewOffsetFit(
                targetViewPos: targetViewPos,
                colX: colX,
                colW: colW,
                mode: mode,
                areas: areas,
                gap: gap
            )
        }

        let area = area(for: mode, areas: areas)
        let areaWidth = Double(area.width)
        let leftStrut = Double(area.minX)
        if areaWidth <= colW {
            return computeNewViewOffsetFit(
                targetViewPos: targetViewPos,
                colX: colX,
                colW: colW,
                mode: mode,
                areas: areas,
                gap: gap
            )
        }

        return -(areaWidth - colW) / 2.0 - leftStrut
    }

    private func computeNewViewOffsetFit(
        targetViewPos: Double,
        colX: Double,
        colW: Double,
        mode: SizingMode,
        areas: GestureAreas,
        gap: CGFloat
    ) -> Double {
        if mode.isFullscreen {
            return 0
        }

        let area = area(for: mode, areas: areas)
        let padding = mode.isMaximized ? 0 : Double(gap)
        let newOffset = computeNewViewOffset(
            currentX: targetViewPos + Double(area.minX),
            viewWidth: Double(area.width),
            newColumnX: colX,
            newColumnWidth: colW,
            gaps: padding
        )
        return newOffset - Double(area.minX)
    }

    private func computeNewViewOffset(
        currentX: Double,
        viewWidth: Double,
        newColumnX: Double,
        newColumnWidth: Double,
        gaps: Double
    ) -> Double {
        if viewWidth <= newColumnWidth {
            return 0
        }

        let padding = ((viewWidth - newColumnWidth) / 2.0).clamped(to: 0 ... gaps)
        let newX = newColumnX - padding
        let newRightX = newColumnX + newColumnWidth + padding

        if currentX <= newX, newRightX <= currentX + viewWidth {
            return -(newColumnX - currentX)
        }

        let distToLeft = abs(currentX - newX)
        let distToRight = abs((currentX + viewWidth) - newRightX)
        if distToLeft <= distToRight {
            return -padding
        } else {
            return -(viewWidth - padding - newColumnWidth)
        }
    }

    private func normalizedGestureAreas(
        viewportWidth: CGFloat,
        workingArea: CGRect?,
        viewFrame: CGRect?,
        scale: CGFloat
    ) -> GestureAreas {
        let parentFrame = viewFrame ?? CGRect(x: 0, y: 0, width: viewportWidth, height: 0)
        let parent = CGRect(origin: .zero, size: parentFrame.size)

        let working: CGRect
        if let workingArea {
            working = CGRect(
                x: workingArea.minX - parentFrame.minX,
                y: workingArea.minY - parentFrame.minY,
                width: workingArea.width,
                height: workingArea.height
            )
        } else {
            working = CGRect(x: 0, y: 0, width: viewportWidth, height: parentFrame.height)
        }

        return GestureAreas(
            working: working.width > 0 ? working : CGRect(x: 0, y: 0, width: viewportWidth, height: parentFrame.height),
            parent: parent.width > 0 ? parent : CGRect(x: 0, y: 0, width: viewportWidth, height: parentFrame.height),
            viewWidth: Double(parent.width > 0 ? parent.width : viewportWidth),
            scale: scale
        )
    }

    private func area(for mode: SizingMode, areas: GestureAreas) -> CGRect {
        mode.isMaximized ? areas.parent : areas.working
    }

    private func sizingMode(for column: NiriContainer) -> SizingMode {
        var anyFullscreen = false
        var anyMaximized = false
        for window in column.windowNodes {
            switch window.sizingMode {
            case .normal:
                continue
            case .maximized:
                anyMaximized = true
            case .fullscreen:
                anyFullscreen = true
            }
        }

        if anyFullscreen {
            return .fullscreen
        } else if anyMaximized {
            return .maximized
        } else {
            return .normal
        }
    }

    private func appendSnapPoint(_ viewPos: Double, _ columnIndex: Int, to snapPoints: inout [SnapPoint]) {
        guard viewPos.isFinite else { return }
        snapPoints.append(SnapPoint(viewPos: viewPos, columnIndex: columnIndex))
    }

    private mutating func endGesturePreservingCurrentOffset(
        currentOffset: Double,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat
    ) {
        var finalOffset = currentOffset
        let totalColumnWidth = Double(totalWidth(columns: columns, gap: gap))
        let viewportWidth = Double(viewportWidth)

        if let preservedOffset = normalizedPreservedGestureOffset(
            currentOffset: currentOffset,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth,
            totalColumnWidth: totalColumnWidth
        ) {
            finalOffset = preservedOffset.finalOffset
            if activeColumnIndex != preservedOffset.normalizedActiveColumn {
                viewOffsetToRestore = nil
            }
            activeColumnIndex = preservedOffset.normalizedActiveColumn
        }

        viewOffsetPixels = .static(CGFloat(finalOffset))
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
        viewOffsetPixels = .static(CGFloat(currentOffset))
        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
        selectionProgress = 0.0
    }
}

private extension SizingMode {
    var isMaximized: Bool {
        self == .maximized
    }

    var isFullscreen: Bool {
        self == .fullscreen
    }
}
