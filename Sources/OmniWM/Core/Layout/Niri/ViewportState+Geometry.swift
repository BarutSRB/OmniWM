// SPDX-License-Identifier: GPL-2.0-only
import COmniWMKernels
import Foundation

private extension CenterFocusedColumn {
    var zigRawValue: UInt32 {
        switch self {
        case .never:
            return UInt32(OMNIWM_CENTER_FOCUSED_COLUMN_NEVER)
        case .always:
            return UInt32(OMNIWM_CENTER_FOCUSED_COLUMN_ALWAYS)
        case .onOverflow:
            return UInt32(OMNIWM_CENTER_FOCUSED_COLUMN_ON_OVERFLOW)
        }
    }
}

private extension SizingMode {
    var viewportGeometryRawValue: UInt8 {
        switch self {
        case .normal:
            return UInt8(OMNIWM_NIRI_WINDOW_SIZING_NORMAL)
        case .fullscreen:
            return UInt8(OMNIWM_NIRI_WINDOW_SIZING_FULLSCREEN)
        }
    }
}

extension ViewportState {
    struct GeometrySnapTarget {
        let viewPos: Double
        let columnIndex: Int
    }

    private func withViewportBuffers<Result>(
        containers: [NiriContainer],
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>,
        _ body: (UnsafeBufferPointer<Double>, UnsafeBufferPointer<UInt8>) -> Result
    ) -> Result {
        withUnsafeTemporaryAllocation(of: Double.self, capacity: containers.count) { spans in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: containers.count) { modes in
                for (index, container) in containers.enumerated() {
                    spans[index] = container[keyPath: sizeKeyPath]
                    modes[index] = container.effectiveSizingMode.viewportGeometryRawValue
                }
                return body(
                    UnsafeBufferPointer(start: spans.baseAddress, count: containers.count),
                    UnsafeBufferPointer(start: modes.baseAddress, count: containers.count)
                )
            }
        }
    }

    func columnX(at index: Int, columns: [NiriContainer], gap: CGFloat) -> CGFloat {
        containerPosition(at: index, containers: columns, gap: gap, sizeKeyPath: \.cachedWidth)
    }

    func columnPlanningX(at index: Int, columns: [NiriContainer], gap: CGFloat) -> CGFloat {
        containerPosition(at: index, containers: columns, gap: gap, sizeKeyPath: \.planningWidth)
    }

    func totalWidth(columns: [NiriContainer], gap: CGFloat) -> CGFloat {
        totalSpan(containers: columns, gap: gap, sizeKeyPath: \.cachedWidth)
    }

    func totalPlanningWidth(columns: [NiriContainer], gap: CGFloat) -> CGFloat {
        totalSpan(containers: columns, gap: gap, sizeKeyPath: \.planningWidth)
    }

    func containerPosition(
        at index: Int,
        containers: [NiriContainer],
        gap: CGFloat,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>
    ) -> CGFloat {
        guard index >= 0 else { return 0 }

        return withViewportBuffers(containers: containers, sizeKeyPath: sizeKeyPath) { spans, _ in
            omniwm_geometry_container_position(
                spans.baseAddress,
                spans.count,
                gap,
                numericCast(index)
            )
        }
    }

    func totalSpan(
        containers: [NiriContainer],
        gap: CGFloat,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>
    ) -> CGFloat {
        withViewportBuffers(containers: containers, sizeKeyPath: sizeKeyPath) { spans, _ in
            omniwm_geometry_total_span(
                spans.baseAddress,
                spans.count,
                gap
            )
        }
    }

    func computeCenteredOffset(
        containerIndex: Int,
        containers: [NiriContainer],
        gap: CGFloat,
        viewportSpan: CGFloat,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>
    ) -> CGFloat {
        guard containerIndex >= 0 else { return 0 }

        return withViewportBuffers(containers: containers, sizeKeyPath: sizeKeyPath) { spans, modes in
            omniwm_geometry_centered_offset(
                spans.baseAddress,
                modes.baseAddress,
                spans.count,
                gap,
                viewportSpan,
                numericCast(containerIndex)
            )
        }
    }

    func computeVisibleOffset(
        containerIndex: Int,
        containers: [NiriContainer],
        gap: CGFloat,
        viewportSpan: CGFloat,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>,
        currentViewStart: CGFloat,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false,
        fromContainerIndex: Int? = nil,
        scale: CGFloat = 2.0
    ) -> CGFloat {
        guard containerIndex >= 0 else { return 0 }

        return withViewportBuffers(containers: containers, sizeKeyPath: sizeKeyPath) { spans, modes in
            omniwm_geometry_visible_offset(
                spans.baseAddress,
                modes.baseAddress,
                spans.count,
                gap,
                viewportSpan,
                Int32(containerIndex),
                currentViewStart,
                centerMode.zigRawValue,
                alwaysCenterSingleColumn ? 1 : 0,
                Int32(fromContainerIndex ?? -1),
                scale
            )
        }
    }

    func snapTarget(
        projectedViewPos: Double,
        currentViewPos: Double,
        containers: [NiriContainer],
        gap: CGFloat,
        viewportSpan: CGFloat,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false
    ) -> GeometrySnapTarget {
        guard !containers.isEmpty else {
            return GeometrySnapTarget(viewPos: 0, columnIndex: 0)
        }

        return withViewportBuffers(containers: containers, sizeKeyPath: sizeKeyPath) { spans, modes in
            let result = omniwm_geometry_snap_target(
                spans.baseAddress,
                modes.baseAddress,
                spans.count,
                gap,
                viewportSpan,
                projectedViewPos,
                currentViewPos,
                centerMode.zigRawValue,
                alwaysCenterSingleColumn ? 1 : 0
            )
            return GeometrySnapTarget(
                viewPos: result.view_pos,
                columnIndex: numericCast(result.column_index)
            )
        }
    }

    func computeCenteredOffset(
        columnIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat
    ) -> CGFloat {
        computeCenteredOffset(
            containerIndex: columnIndex,
            containers: columns,
            gap: gap,
            viewportSpan: viewportWidth,
            sizeKeyPath: \.cachedWidth
        )
    }

    func computePlanningCenteredOffset(
        columnIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat
    ) -> CGFloat {
        computeCenteredOffset(
            containerIndex: columnIndex,
            containers: columns,
            gap: gap,
            viewportSpan: viewportWidth,
            sizeKeyPath: \.planningWidth
        )
    }

    func computeVisibleOffset(
        columnIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        currentOffset: CGFloat,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false,
        fromColumnIndex: Int? = nil,
        scale: CGFloat = 2.0
    ) -> CGFloat {
        let columnPosition = columnX(at: columnIndex, columns: columns, gap: gap)
        return computeVisibleOffset(
            containerIndex: columnIndex,
            containers: columns,
            gap: gap,
            viewportSpan: viewportWidth,
            sizeKeyPath: \.cachedWidth,
            currentViewStart: columnPosition + currentOffset,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            fromContainerIndex: fromColumnIndex,
            scale: scale
        )
    }

    func computePlanningVisibleOffset(
        columnIndex: Int,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        currentOffset: CGFloat,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false,
        fromColumnIndex: Int? = nil,
        scale: CGFloat = 2.0
    ) -> CGFloat {
        let columnPosition = columnPlanningX(at: columnIndex, columns: columns, gap: gap)
        return computeVisibleOffset(
            containerIndex: columnIndex,
            containers: columns,
            gap: gap,
            viewportSpan: viewportWidth,
            sizeKeyPath: \.planningWidth,
            currentViewStart: columnPosition + currentOffset,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn,
            fromContainerIndex: fromColumnIndex,
            scale: scale
        )
    }

    func snapTarget(
        projectedViewPos: Double,
        currentViewPos: Double,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false
    ) -> GeometrySnapTarget {
        snapTarget(
            projectedViewPos: projectedViewPos,
            currentViewPos: currentViewPos,
            containers: columns,
            gap: gap,
            viewportSpan: viewportWidth,
            sizeKeyPath: \.cachedWidth,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )
    }

    func planningSnapTarget(
        projectedViewPos: Double,
        currentViewPos: Double,
        columns: [NiriContainer],
        gap: CGFloat,
        viewportWidth: CGFloat,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false
    ) -> GeometrySnapTarget {
        snapTarget(
            projectedViewPos: projectedViewPos,
            currentViewPos: currentViewPos,
            containers: columns,
            gap: gap,
            viewportSpan: viewportWidth,
            sizeKeyPath: \.planningWidth,
            centerMode: centerMode,
            alwaysCenterSingleColumn: alwaysCenterSingleColumn
        )
    }
}
