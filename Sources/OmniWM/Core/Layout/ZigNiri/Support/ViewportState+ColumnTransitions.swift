import AppKit
import Foundation

extension ViewportState {
    mutating func setActiveColumn(
        _ index: Int,
        columnSpans: [CGFloat],
        gap: CGFloat,
        viewportSpan: CGFloat,
        animate: Bool = false
    ) {
        guard !columnSpans.isEmpty else { return }
        let safeCurrentIndex = activeColumnIndex.clamped(to: 0 ... (columnSpans.count - 1))
        let clampedIndex = index.clamped(to: 0 ... (columnSpans.count - 1))
        transitionToColumn(
            clampedIndex,
            columnSpans: columnSpans,
            gap: gap,
            viewportSpan: viewportSpan,
            animate: animate,
            centerMode: .always,
            alwaysCenterSingleColumn: true,
            fromColumnIndex: safeCurrentIndex,
            scale: 2.0
        )
    }

    mutating func transitionToColumn(
        _ newIndex: Int,
        columnSpans: [CGFloat],
        gap: CGFloat,
        viewportSpan: CGFloat,
        animate: Bool,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false,
        fromColumnIndex: Int? = nil,
        scale: CGFloat = 2.0
    ) {
        guard !columnSpans.isEmpty else { return }
        let safeCurrentIndex = activeColumnIndex.clamped(to: 0 ... (columnSpans.count - 1))
        let requestedNonNegative = max(newIndex, 0)
        let resolvedFromColumnIndex: Int = if let fromColumnIndex,
                                              (0 ..< columnSpans.count).contains(fromColumnIndex) {
            fromColumnIndex
        } else {
            safeCurrentIndex
        }

        let plan = ZigNiriViewportMath.transitionPlan(
            spans: columnSpans.map(Double.init),
            currentActiveIndex: safeCurrentIndex,
            requestedIndex: requestedNonNegative,
            gap: gap,
            viewportSpan: viewportSpan,
            currentTargetOffset: viewOffsetPixels.target(),
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            fromContainerIndex: resolvedFromColumnIndex,
            scale: scale
        )

        activeColumnIndex = plan.resolvedColumnIndex
        viewOffsetPixels.offset(delta: Double(plan.offsetDelta))

        if plan.snapToTargetImmediately {
            viewOffsetPixels.offset(delta: Double(plan.snapDelta))
            activatePrevColumnOnRemoval = nil
            viewOffsetToRestore = nil
            return
        }

        if animate {
            animateToOffset(plan.targetOffset)
        } else {
            viewOffsetPixels = .static(plan.targetOffset)
        }

        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
    }

    mutating func ensureContainerVisible(
        containerIndex: Int,
        spans: [CGFloat],
        gap: CGFloat,
        viewportSpan: CGFloat,
        animate: Bool = true,
        centerMode: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false,
        animationConfig: SpringConfig? = nil,
        fromContainerIndex: Int? = nil
    ) {
        guard !spans.isEmpty, containerIndex >= 0, containerIndex < spans.count else { return }
        let safeActiveIndex = activeColumnIndex.clamped(to: 0 ... (spans.count - 1))
        let normalizedFromContainerIndex: Int? = if let fromContainerIndex {
            if (0 ..< spans.count).contains(fromContainerIndex) {
                fromContainerIndex
            } else {
                safeActiveIndex
            }
        } else {
            nil
        }

        let currentOffset = viewOffsetPixels.current()
        let plan = ZigNiriViewportMath.ensureVisiblePlan(
            spans: spans.map(Double.init),
            activeContainerIndex: safeActiveIndex,
            targetContainerIndex: containerIndex,
            gap: gap,
            viewportSpan: viewportSpan,
            currentOffset: currentOffset,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            fromContainerIndex: normalizedFromContainerIndex
        )

        if plan.isNoop {
            return
        }

        if animate {
            let now = animationClock?.now() ?? CACurrentMediaTime()
            let currentVelocity = viewOffsetPixels.currentVelocity()
            let config = animationConfig ?? springConfig
            let animation = SpringAnimation(
                from: Double(currentOffset),
                to: Double(plan.targetOffset),
                initialVelocity: currentVelocity,
                startTime: now,
                config: config,
                displayRefreshRate: displayRefreshRate
            )
            viewOffsetPixels = .spring(animation)
        } else {
            viewOffsetPixels = .static(plan.targetOffset)
        }
    }

    mutating func snapToColumn(
        _ columnIndex: Int,
        columnSpans: [CGFloat],
        gap: CGFloat,
        viewportSpan: CGFloat
    ) {
        guard !columnSpans.isEmpty else { return }
        let safeCurrentIndex = activeColumnIndex.clamped(to: 0 ... (columnSpans.count - 1))
        let requestedNonNegative = max(columnIndex, 0)
        let plan = ZigNiriViewportMath.transitionPlan(
            spans: columnSpans.map(Double.init),
            currentActiveIndex: safeCurrentIndex,
            requestedIndex: requestedNonNegative,
            gap: gap,
            viewportSpan: viewportSpan,
            currentTargetOffset: viewOffsetPixels.target(),
            centerMode: .always,
            alwaysCenterSingleColumn: true,
            fromContainerIndex: safeCurrentIndex,
            scale: 2.0
        )

        activeColumnIndex = plan.resolvedColumnIndex
        viewOffsetPixels = .static(plan.targetOffset)
        selectionProgress = 0
    }

    mutating func scrollByPixels(
        _ deltaPixels: CGFloat,
        columnSpans: [CGFloat],
        gap: CGFloat,
        viewportSpan: CGFloat,
        changeSelection: Bool
    ) -> Int? {
        let result = ZigNiriViewportMath.scrollStep(
            spans: columnSpans.map(Double.init),
            deltaPixels: deltaPixels,
            viewportSpan: viewportSpan,
            gap: gap,
            currentOffset: viewOffsetPixels.current(),
            selectionProgress: selectionProgress,
            changeSelection: changeSelection
        )

        guard result.applied else {
            return nil
        }

        viewOffsetPixels = .static(result.newOffset)
        selectionProgress = result.selectionProgress
        return result.selectionSteps
    }
}
