import AppKit
import Foundation

extension ViewportState {
    mutating func beginGesture(isTrackpad: Bool) {
        let currentOffset = viewOffsetPixels.current()
        viewOffsetPixels = .gesture(ViewGesture(currentViewOffset: Double(currentOffset), isTrackpad: isTrackpad))
        selectionProgress = 0.0
    }

    mutating func updateGesture(
        deltaPixels: CGFloat,
        timestamp: TimeInterval,
        columnSpans: [CGFloat],
        gap: CGFloat,
        viewportSpan: CGFloat
    ) -> Int? {
        guard case let .gesture(gesture) = viewOffsetPixels else {
            return nil
        }

        let normalizedActiveIndex: Int = if columnSpans.isEmpty {
            0
        } else {
            activeColumnIndex.clamped(to: 0 ... (columnSpans.count - 1))
        }

        let result = ZigNiriViewportMath.gestureUpdate(
            state: &gesture.gestureState,
            spans: columnSpans.map(Double.init),
            activeContainerIndex: normalizedActiveIndex,
            deltaPixels: deltaPixels,
            timestamp: timestamp,
            gap: gap,
            viewportSpan: viewportSpan,
            selectionProgress: selectionProgress
        )

        selectionProgress = result.selectionProgress
        return result.selectionSteps
    }

    mutating func endGesture(
        columnSpans: [CGFloat],
        gap: CGFloat,
        viewportSpan: CGFloat,
        centerMode: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false
    ) {
        guard case let .gesture(gesture) = viewOffsetPixels else {
            return
        }

        let normalizedActiveIndex: Int = if columnSpans.isEmpty {
            0
        } else {
            activeColumnIndex.clamped(to: 0 ... (columnSpans.count - 1))
        }

        let result = ZigNiriViewportMath.gestureEnd(
            state: gesture.gestureState,
            spans: columnSpans.map(Double.init),
            activeContainerIndex: normalizedActiveIndex,
            gap: gap,
            viewportSpan: viewportSpan,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )

        let now = animationClock?.now() ?? CACurrentMediaTime()
        let animation = SpringAnimation(
            from: result.springFrom,
            to: result.springTo,
            initialVelocity: result.initialVelocity,
            startTime: now,
            config: springConfig,
            displayRefreshRate: displayRefreshRate
        )
        activeColumnIndex = result.resolvedColumnIndex
        viewOffsetPixels = .spring(animation)

        activatePrevColumnOnRemoval = nil
        viewOffsetToRestore = nil
        selectionProgress = 0.0
    }
}
