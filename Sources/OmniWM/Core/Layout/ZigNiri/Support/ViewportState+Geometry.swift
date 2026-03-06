import Foundation

extension ViewportState {
    func columnX(at index: Int, spans: [CGFloat], gap: CGFloat) -> CGFloat {
        containerPosition(at: index, spans: spans, gap: gap)
    }

    func containerPosition(at index: Int, spans: [CGFloat], gap: CGFloat) -> CGFloat {
        var pos: CGFloat = 0
        for i in 0 ..< index {
            guard i < spans.count else { break }
            pos += spans[i] + gap
        }
        return pos
    }

    func totalSpan(spans: [CGFloat], gap: CGFloat) -> CGFloat {
        guard !spans.isEmpty else { return 0 }
        let sizeSum = spans.reduce(0, +)
        let gapSum = CGFloat(max(0, spans.count - 1)) * gap
        return sizeSum + gapSum
    }

    func computeVisibleOffset(
        containerIndex: Int,
        spans: [CGFloat],
        gap: CGFloat,
        viewportSpan: CGFloat,
        currentViewStart: CGFloat,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false,
        fromContainerIndex: Int? = nil
    ) -> CGFloat {
        guard !spans.isEmpty, containerIndex >= 0, containerIndex < spans.count else { return 0 }

        return ZigNiriViewportMath.computeVisibleOffset(
            spans: spans.map(Double.init),
            containerIndex: containerIndex,
            gap: gap,
            viewportSpan: viewportSpan,
            currentViewStart: currentViewStart,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            fromContainerIndex: fromContainerIndex
        )
    }

    func computeVisibleOffset(
        columnIndex: Int,
        columnSpans: [CGFloat],
        gap: CGFloat,
        viewportSpan: CGFloat,
        currentOffset: CGFloat,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false,
        fromColumnIndex: Int? = nil
    ) -> CGFloat {
        let colX = columnX(at: columnIndex, spans: columnSpans, gap: gap)
        return computeVisibleOffset(
            containerIndex: columnIndex,
            spans: columnSpans,
            gap: gap,
            viewportSpan: viewportSpan,
            currentViewStart: colX + currentOffset,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            fromContainerIndex: fromColumnIndex
        )
    }
}
