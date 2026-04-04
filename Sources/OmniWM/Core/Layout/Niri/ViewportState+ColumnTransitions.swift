import AppKit
import Foundation

extension ViewportState {
    mutating func setActiveColumn(
        _ index: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        motion: MotionSnapshot,
        animate: Bool = false
    ) {
        guard !columns.isEmpty else { return }
        let clampedIndex = index.clamped(to: 0 ... (columns.count - 1))

        let oldActiveColX = columnX(at: activeColumnIndex, columns: columns, gap: gap)
        let newActiveColX = columnX(at: clampedIndex, columns: columns, gap: gap)
        let offsetDelta = oldActiveColX - newActiveColX

        viewOffsetPixels.offset(delta: Double(offsetDelta))

        let targetOffset = computeCenteredOffset(
            columnIndex: clampedIndex,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth
        )

        if animate {
            animateToOffset(targetOffset, motion: motion)
        } else {
            viewOffsetPixels = .static(targetOffset)
        }

        activeColumnIndex = clampedIndex
        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
    }

    mutating func transitionToColumn(
        _ newIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        motion: MotionSnapshot,
        animate: Bool,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false,
        fromColumnIndex: Int? = nil,
        scale: CGFloat = 2.0
    ) {
        guard !columns.isEmpty else { return }
        let clampedIndex = newIndex.clamped(to: 0 ... (columns.count - 1))

        let oldActiveColX = columnX(at: activeColumnIndex, columns: columns, gap: gap)

        let prevActiveColumn = activeColumnIndex
        activeColumnIndex = clampedIndex

        let newActiveColX = columnX(at: clampedIndex, columns: columns, gap: gap)
        let offsetDelta = oldActiveColX - newActiveColX

        viewOffsetPixels.offset(delta: Double(offsetDelta))

        let targetOffset = computeVisibleOffset(
            columnIndex: clampedIndex,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth,
            currentOffset: viewOffsetPixels.target(),
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            fromColumnIndex: fromColumnIndex ?? prevActiveColumn,
            scale: scale
        )

        let pixel: CGFloat = 1.0 / max(scale, 1.0)
        let toDiff = targetOffset - viewOffsetPixels.target()
        if abs(toDiff) < pixel {
            viewOffsetPixels.offset(delta: Double(toDiff))
            activatePrevColumnOnRemoval = nil
            viewOffsetToRestore = nil
            return
        }

        if animate {
            animateToOffset(targetOffset, motion: motion)
        } else {
            viewOffsetPixels = .static(targetOffset)
        }

        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
    }

    mutating func ensureContainerVisible(
        containerIndex: Int,
        containers: [NiriContainer],
        gap: CGFloat,
        viewportSpan: CGFloat,
        motion: MotionSnapshot,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>,
        animate: Bool = true,
        centerMode: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false,
        animationConfig: SpringConfig? = nil,
        fromContainerIndex: Int? = nil,
        scale: CGFloat = 2.0
    ) {
        guard !containers.isEmpty, containerIndex >= 0, containerIndex < containers.count else { return }

        let stationaryOffset = stationary()
        let activePos = containerPosition(at: activeColumnIndex, containers: containers, gap: gap, sizeKeyPath: sizeKeyPath)
        let stationaryViewStart = activePos + stationaryOffset
        let pixelEpsilon: CGFloat = 1.0 / max(scale, 1.0)

        let targetOffset = computeVisibleOffset(
            containerIndex: containerIndex,
            containers: containers,
            gap: gap,
            viewportSpan: viewportSpan,
            sizeKeyPath: sizeKeyPath,
            currentViewStart: stationaryViewStart,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            fromContainerIndex: fromContainerIndex,
            scale: scale
        )

        if abs(targetOffset - stationaryOffset) <= pixelEpsilon {
            return
        }

        if animate {
            animateToOffset(
                targetOffset,
                motion: motion,
                config: animationConfig,
                scale: scale
            )
        } else {
            viewOffsetPixels = .static(targetOffset)
        }
    }

    mutating func snapToColumn(
        _ columnIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat
    ) {
        guard !columns.isEmpty else { return }
        let clampedIndex = columnIndex.clamped(to: 0 ... (columns.count - 1))
        activeColumnIndex = clampedIndex

        let targetOffset = computeCenteredOffset(
            columnIndex: clampedIndex,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth
        )
        viewOffsetPixels = .static(targetOffset)
        selectionProgress = 0
    }

    mutating func scrollByPixels(
        _ deltaPixels: CGFloat,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        changeSelection: Bool
    ) -> Int? {
        guard abs(deltaPixels) > CGFloat.ulpOfOne else { return nil }
        guard !columns.isEmpty else { return nil }

        let totalW = totalWidth(columns: columns, gap: gap)
        guard totalW > 0 else { return nil }

        let currentOffset = viewOffsetPixels.current()
        var newOffset = currentOffset + deltaPixels

        let maxOffset: CGFloat = 0
        let minOffset = viewportWidth - totalW

        if minOffset < maxOffset {
            newOffset = newOffset.clamped(to: minOffset ... maxOffset)
        } else {
            newOffset = 0
        }

        viewOffsetPixels = .static(newOffset)

        if changeSelection {
            selectionProgress += deltaPixels
            let avgColumnWidth = totalW / CGFloat(columns.count)
            let steps = Int((selectionProgress / avgColumnWidth).rounded(.towardZero))
            if steps != 0 {
                selectionProgress -= CGFloat(steps) * avgColumnWidth
                return steps
            }
        }

        return nil
    }
}
