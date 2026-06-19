// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension ViewportState {
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
        scale: CGFloat = 2.0,
        workingArea: CGRect? = nil,
        viewFrame: CGRect? = nil
    ) {
        guard !columns.isEmpty else { return }
        let clampedIndex = newIndex.clamped(to: 0 ... (columns.count - 1))

        let oldActiveColX = columnX(at: activeColumnIndex, columns: columns, gap: gap)

        let prevActiveColumn = activeColumnIndex
        activeColumnIndex = clampedIndex

        let newActiveColX = columnX(at: clampedIndex, columns: columns, gap: gap)
        let offsetDelta = oldActiveColX - newActiveColX

        rebaseOffset(by: offsetDelta)

        let targetOffset = computeVisibleOffset(
            columnIndex: clampedIndex,
            columns: columns,
            gap: gap,
            viewportWidth: viewportWidth,
            currentOffset: viewOffset,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            fromColumnIndex: fromColumnIndex ?? prevActiveColumn,
            scale: scale,
            workingArea: workingArea,
            viewFrame: viewFrame
        )

        let pixel: CGFloat = 1.0 / max(scale, 1.0)
        let toDiff = targetOffset - viewOffset
        if abs(toDiff) < pixel {
            rebaseOffset(by: toDiff)
            activatePrevColumnOnRemoval = nil
            viewOffsetToRestore = nil
            return
        }

        if animate {
            animateToOffset(targetOffset, motion: motion)
        } else {
            jumpOffset(to: targetOffset)
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
        scale: CGFloat = 2.0,
        workingArea: CGRect? = nil,
        viewFrame: CGRect? = nil,
        orientation: Monitor.Orientation = .horizontal
    ) {
        guard !containers.isEmpty, containerIndex >= 0, containerIndex < containers.count else { return }

        let stationaryOffset = viewOffset
        let activePos = containerPosition(
            at: activeColumnIndex,
            containers: containers,
            gap: gap,
            sizeKeyPath: sizeKeyPath
        )
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
            scale: scale,
            workingArea: workingArea,
            viewFrame: viewFrame,
            orientation: orientation
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
            jumpOffset(to: targetOffset)
        }
    }
}
