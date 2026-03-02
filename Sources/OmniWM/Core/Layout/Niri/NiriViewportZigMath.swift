import CZigLayout
import Foundation

enum NiriViewportZigMath {
    private static func centerModeCode(_ centerMode: CenterFocusedColumn) -> UInt8 {
        switch centerMode {
        case .never:
            0
        case .always:
            1
        case .onOverflow:
            2
        }
    }

    static func computeVisibleOffset(
        spans: [Double],
        containerIndex: Int,
        gap: CGFloat,
        viewportSpan: CGFloat,
        currentViewStart: CGFloat,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool,
        fromContainerIndex: Int?
    ) -> CGFloat {
        precondition(containerIndex >= 0, "NiriViewportZigMath.computeVisibleOffset requires non-negative containerIndex")

        var outTarget: Double = 0
        let fromIndex = Int64(fromContainerIndex ?? -1)

        let rc: Int32 = spans.withUnsafeBufferPointer { spansBuf in
            withUnsafeMutablePointer(to: &outTarget) { outPtr in
                omni_viewport_compute_visible_offset(
                    spansBuf.baseAddress,
                    spans.count,
                    containerIndex,
                    Double(gap),
                    Double(viewportSpan),
                    Double(currentViewStart),
                    centerModeCode(centerMode),
                    alwaysCenterSingleColumn ? 1 : 0,
                    fromIndex,
                    outPtr
                )
            }
        }

        if rc != OMNI_OK {
            fatalError(
                "omni_viewport_compute_visible_offset failed rc=\(rc) span_count=\(spans.count) " +
                    "container_index=\(containerIndex) gap=\(gap) viewport_span=\(viewportSpan) " +
                    "current_view_start=\(currentViewStart) center_mode=\(centerModeCode(centerMode)) " +
                    "always_center_single_column=\(alwaysCenterSingleColumn) from_container_index=\(fromIndex)"
            )
        }
        return CGFloat(outTarget)
    }

    static func findSnapTarget(
        spans: [Double],
        gap: CGFloat,
        viewportSpan: CGFloat,
        projectedViewPos: Double,
        currentViewPos: Double,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool
    ) -> ViewportState.SnapResult {
        var out = OmniSnapResult(view_pos: 0, column_index: 0)

        let rc: Int32 = spans.withUnsafeBufferPointer { spansBuf in
            withUnsafeMutablePointer(to: &out) { outPtr in
                omni_viewport_find_snap_target(
                    spansBuf.baseAddress,
                    spans.count,
                    Double(gap),
                    Double(viewportSpan),
                    projectedViewPos,
                    currentViewPos,
                    centerModeCode(centerMode),
                    alwaysCenterSingleColumn ? 1 : 0,
                    outPtr
                )
            }
        }

        if rc != OMNI_OK {
            fatalError(
                "omni_viewport_find_snap_target failed rc=\(rc) span_count=\(spans.count) gap=\(gap) " +
                    "viewport_span=\(viewportSpan) projected_view_pos=\(projectedViewPos) " +
                    "current_view_pos=\(currentViewPos) center_mode=\(centerModeCode(centerMode)) " +
                    "always_center_single_column=\(alwaysCenterSingleColumn)"
            )
        }
        return ViewportState.SnapResult(
            viewPos: out.view_pos,
            columnIndex: Int(out.column_index)
        )
    }
}
