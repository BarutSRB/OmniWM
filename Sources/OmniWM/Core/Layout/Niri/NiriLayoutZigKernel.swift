import AppKit
import CZigLayout
import Foundation

enum NiriLayoutZigKernel {
    struct LayoutPassResult {
        let windows: [WindowResult]
        let columns: [ColumnResult]
    }

    struct WindowResult {
        let window: NiriWindow
        let baseFrame: CGRect
        let animatedFrame: CGRect
        let resolvedSpan: CGFloat
        let wasConstrained: Bool
        let hideSide: HideSide?
    }

    struct ColumnResult {
        let column: NiriContainer
        let frame: CGRect
        let hideSide: HideSide?
        let isVisible: Bool
    }

    struct ResizeHitResult {
        let window: NiriWindow
        let columnIndex: Int
        let edges: ResizeEdge
        let frame: CGRect
    }

    struct ResizeComputationInput {
        let edges: ResizeEdge
        let startLocation: CGPoint
        let currentLocation: CGPoint
        let originalColumnWidth: CGFloat
        let minColumnWidth: CGFloat
        let maxColumnWidth: CGFloat
        let originalWindowWeight: CGFloat
        let minWindowWeight: CGFloat
        let maxWindowWeight: CGFloat
        let pixelsPerWeight: CGFloat
        let originalViewOffset: CGFloat?
    }

    struct ResizeComputationResult {
        let changedWidth: Bool
        let newColumnWidth: CGFloat
        let changedWeight: Bool
        let newWindowWeight: CGFloat
        let adjustViewOffset: Bool
        let newViewOffset: CGFloat
    }

    private struct HitTestEntry {
        let window: NiriWindow
        let columnIndex: Int
        let frame: CGRect
    }

    private static func orientationCode(_ orientation: Monitor.Orientation) -> UInt8 {
        switch orientation {
        case .horizontal:
            0
        case .vertical:
            1
        }
    }

    private static func sizingModeCode(_ mode: SizingMode) -> UInt8 {
        switch mode {
        case .normal:
            0
        case .fullscreen:
            1
        }
    }

    private static func hideSideFromCode(_ code: UInt8) -> HideSide? {
        if code == 1 {
            return .left
        }
        if code == 2 {
            return .right
        }
        return nil
    }

    private static func resizeEdgeCode(_ edges: ResizeEdge) -> UInt8 {
        UInt8(edges.rawValue & 0xFF)
    }

    private static func resizeEdgeFromCode(_ code: UInt8) -> ResizeEdge {
        ResizeEdge(rawValue: UInt32(code))
    }

    static func run(
        columns: [NiriContainer],
        orientation: Monitor.Orientation,
        primaryGap: CGFloat,
        secondaryGap: CGFloat,
        workingFrame: CGRect,
        viewFrame: CGRect,
        fullscreenFrame: CGRect,
        viewStart: CGFloat,
        viewportSpan: CGFloat,
        workspaceOffset: CGFloat,
        scale: CGFloat,
        tabIndicatorWidth: CGFloat,
        time: TimeInterval
    ) -> LayoutPassResult {
        guard !columns.isEmpty else {
            return LayoutPassResult(windows: [], columns: [])
        }

        var columnInputs: [OmniNiriColumnInput] = []
        columnInputs.reserveCapacity(columns.count)

        var windowInputs: [OmniNiriWindowInput] = []
        var flatWindows: [NiriWindow] = []

        for column in columns {
            let start = windowInputs.count
            let windows = column.windowNodes
            flatWindows.append(contentsOf: windows)

            for window in windows {
                let weight: CGFloat
                let minConstraint: CGFloat
                let maxConstraint: CGFloat
                let hasMaxConstraint: Bool
                let hasFixedValue: Bool
                let fixedValue: CGFloat

                switch orientation {
                case .horizontal:
                    weight = max(0.1, window.heightWeight)
                    minConstraint = window.constraints.minSize.height
                    maxConstraint = window.constraints.maxSize.height
                    hasMaxConstraint = window.constraints.hasMaxHeight
                    switch window.height {
                    case let .fixed(h):
                        hasFixedValue = true
                        fixedValue = h
                    case .auto:
                        hasFixedValue = false
                        fixedValue = 0
                    }
                case .vertical:
                    weight = max(0.1, window.widthWeight)
                    minConstraint = window.constraints.minSize.width
                    maxConstraint = window.constraints.maxSize.width
                    hasMaxConstraint = window.constraints.hasMaxWidth
                    switch window.windowWidth {
                    case let .fixed(w):
                        hasFixedValue = true
                        fixedValue = w
                    case .auto:
                        hasFixedValue = false
                        fixedValue = 0
                    }
                }

                let renderOffset = window.renderOffset(at: time)
                windowInputs.append(
                    OmniNiriWindowInput(
                        weight: Double(weight),
                        min_constraint: Double(minConstraint),
                        max_constraint: Double(maxConstraint),
                        has_max_constraint: hasMaxConstraint ? 1 : 0,
                        is_constraint_fixed: window.constraints.isFixed ? 1 : 0,
                        has_fixed_value: hasFixedValue ? 1 : 0,
                        fixed_value: Double(fixedValue),
                        sizing_mode: sizingModeCode(window.sizingMode),
                        render_offset_x: Double(renderOffset.x),
                        render_offset_y: Double(renderOffset.y)
                    )
                )
            }

            let span: CGFloat = switch orientation {
            case .horizontal:
                column.cachedWidth
            case .vertical:
                column.cachedHeight
            }

            let columnRenderOffset = column.renderOffset(at: time)
            columnInputs.append(
                OmniNiriColumnInput(
                    span: Double(span),
                    render_offset_x: Double(columnRenderOffset.x),
                    render_offset_y: Double(columnRenderOffset.y),
                    is_tabbed: column.isTabbed ? 1 : 0,
                    tab_indicator_width: Double(column.isTabbed ? tabIndicatorWidth : 0),
                    window_start: start,
                    window_count: windows.count
                )
            )
        }

        var rawColumnOutputs = [OmniNiriColumnOutput](
            repeating: OmniNiriColumnOutput(
                frame_x: 0,
                frame_y: 0,
                frame_width: 0,
                frame_height: 0,
                hide_side: 0,
                is_visible: 0
            ),
            count: columnInputs.count
        )

        var rawOutputs = [OmniNiriWindowOutput](
            repeating: OmniNiriWindowOutput(
                frame_x: 0,
                frame_y: 0,
                frame_width: 0,
                frame_height: 0,
                animated_x: 0,
                animated_y: 0,
                animated_width: 0,
                animated_height: 0,
                resolved_span: 0,
                was_constrained: 0,
                hide_side: 0,
                column_index: 0
            ),
            count: windowInputs.count
        )

        let rc: Int32 = columnInputs.withUnsafeBufferPointer { colBuf in
            windowInputs.withUnsafeBufferPointer { winBuf in
                rawOutputs.withUnsafeMutableBufferPointer { winOutBuf in
                    rawColumnOutputs.withUnsafeMutableBufferPointer { colOutBuf in
                        omni_niri_layout_pass_v2(
                            colBuf.baseAddress,
                            colBuf.count,
                            winBuf.baseAddress,
                            winBuf.count,
                            Double(workingFrame.origin.x),
                            Double(workingFrame.origin.y),
                            Double(workingFrame.width),
                            Double(workingFrame.height),
                            Double(viewFrame.origin.x),
                            Double(viewFrame.origin.y),
                            Double(viewFrame.width),
                            Double(viewFrame.height),
                            Double(fullscreenFrame.origin.x),
                            Double(fullscreenFrame.origin.y),
                            Double(fullscreenFrame.width),
                            Double(fullscreenFrame.height),
                            Double(primaryGap),
                            Double(secondaryGap),
                            Double(viewStart),
                            Double(viewportSpan),
                            Double(workspaceOffset),
                            Double(scale),
                            orientationCode(orientation),
                            winOutBuf.baseAddress,
                            winOutBuf.count,
                            colOutBuf.baseAddress,
                            colOutBuf.count
                        )
                    }
                }
            }
        }

        precondition(
            rc == OMNI_OK,
            "omni_niri_layout_pass_v2 failed rc=\(rc) columns=\(columnInputs.count) windows=\(windowInputs.count)"
        )

        let windows = zip(flatWindows, rawOutputs).map { window, output in
            WindowResult(
                window: window,
                baseFrame: CGRect(
                    x: output.frame_x,
                    y: output.frame_y,
                    width: output.frame_width,
                    height: output.frame_height
                ),
                animatedFrame: CGRect(
                    x: output.animated_x,
                    y: output.animated_y,
                    width: output.animated_width,
                    height: output.animated_height
                ),
                resolvedSpan: CGFloat(output.resolved_span),
                wasConstrained: output.was_constrained != 0,
                hideSide: hideSideFromCode(output.hide_side)
            )
        }

        let columnsOut = zip(columns, rawColumnOutputs).map { column, output in
            ColumnResult(
                column: column,
                frame: CGRect(
                    x: output.frame_x,
                    y: output.frame_y,
                    width: output.frame_width,
                    height: output.frame_height
                ),
                hideSide: hideSideFromCode(output.hide_side),
                isVisible: output.is_visible != 0
            )
        }

        return LayoutPassResult(windows: windows, columns: columnsOut)
    }

    static func hitTestTiled(
        columns: [NiriContainer],
        point: CGPoint
    ) -> NiriWindow? {
        let entries = collectHitTestEntries(columns: columns)
        guard !entries.isEmpty else { return nil }

        let inputs = entries.enumerated().map { index, entry in
            OmniNiriHitTestWindow(
                window_index: index,
                column_index: entry.columnIndex,
                frame_x: Double(entry.frame.origin.x),
                frame_y: Double(entry.frame.origin.y),
                frame_width: Double(entry.frame.width),
                frame_height: Double(entry.frame.height),
                is_fullscreen: entry.window.isFullscreen ? 1 : 0
            )
        }

        var outIndex: Int64 = -1
        let rc = inputs.withUnsafeBufferPointer { buf in
            withUnsafeMutablePointer(to: &outIndex) { outPtr in
                omni_niri_hit_test_tiled(
                    buf.baseAddress,
                    buf.count,
                    Double(point.x),
                    Double(point.y),
                    outPtr
                )
            }
        }

        precondition(rc == OMNI_OK, "omni_niri_hit_test_tiled failed rc=\(rc)")
        guard outIndex >= 0, outIndex < Int64(entries.count) else { return nil }
        return entries[Int(outIndex)].window
    }

    static func hitTestResize(
        columns: [NiriContainer],
        point: CGPoint,
        threshold: CGFloat
    ) -> ResizeHitResult? {
        let entries = collectHitTestEntries(columns: columns)
        guard !entries.isEmpty else { return nil }

        let inputs = entries.enumerated().map { index, entry in
            OmniNiriHitTestWindow(
                window_index: index,
                column_index: entry.columnIndex,
                frame_x: Double(entry.frame.origin.x),
                frame_y: Double(entry.frame.origin.y),
                frame_width: Double(entry.frame.width),
                frame_height: Double(entry.frame.height),
                is_fullscreen: entry.window.isFullscreen ? 1 : 0
            )
        }

        var out = OmniNiriResizeHitResult(window_index: -1, edges: 0)
        let rc = inputs.withUnsafeBufferPointer { buf in
            withUnsafeMutablePointer(to: &out) { outPtr in
                omni_niri_hit_test_resize(
                    buf.baseAddress,
                    buf.count,
                    Double(point.x),
                    Double(point.y),
                    Double(threshold),
                    outPtr
                )
            }
        }

        precondition(rc == OMNI_OK, "omni_niri_hit_test_resize failed rc=\(rc)")
        guard out.window_index >= 0, out.window_index < Int64(entries.count) else { return nil }

        let index = Int(out.window_index)
        let entry = entries[index]
        let edges = resizeEdgeFromCode(out.edges)
        guard !edges.isEmpty else { return nil }

        return ResizeHitResult(
            window: entry.window,
            columnIndex: entry.columnIndex,
            edges: edges,
            frame: entry.frame
        )
    }

    static func computeResize(_ input: ResizeComputationInput) -> ResizeComputationResult {
        var rawInput = OmniNiriResizeInput(
            edges: resizeEdgeCode(input.edges),
            start_x: Double(input.startLocation.x),
            start_y: Double(input.startLocation.y),
            current_x: Double(input.currentLocation.x),
            current_y: Double(input.currentLocation.y),
            original_column_width: Double(input.originalColumnWidth),
            min_column_width: Double(input.minColumnWidth),
            max_column_width: Double(input.maxColumnWidth),
            original_window_weight: Double(input.originalWindowWeight),
            min_window_weight: Double(input.minWindowWeight),
            max_window_weight: Double(input.maxWindowWeight),
            pixels_per_weight: Double(input.pixelsPerWeight),
            has_original_view_offset: input.originalViewOffset == nil ? 0 : 1,
            original_view_offset: Double(input.originalViewOffset ?? 0)
        )
        var rawOutput = OmniNiriResizeResult(
            changed_width: 0,
            new_column_width: 0,
            changed_weight: 0,
            new_window_weight: 0,
            adjust_view_offset: 0,
            new_view_offset: 0
        )

        let rc = withUnsafePointer(to: &rawInput) { inputPtr in
            withUnsafeMutablePointer(to: &rawOutput) { outputPtr in
                omni_niri_resize_compute(inputPtr, outputPtr)
            }
        }
        precondition(rc == OMNI_OK, "omni_niri_resize_compute failed rc=\(rc)")

        return ResizeComputationResult(
            changedWidth: rawOutput.changed_width != 0,
            newColumnWidth: CGFloat(rawOutput.new_column_width),
            changedWeight: rawOutput.changed_weight != 0,
            newWindowWeight: CGFloat(rawOutput.new_window_weight),
            adjustViewOffset: rawOutput.adjust_view_offset != 0,
            newViewOffset: CGFloat(rawOutput.new_view_offset)
        )
    }

    private static func collectHitTestEntries(columns: [NiriContainer]) -> [HitTestEntry] {
        var entries: [HitTestEntry] = []
        for (columnIndex, column) in columns.enumerated() {
            for child in column.children {
                guard let window = child as? NiriWindow,
                      let frame = window.frame else { continue }
                entries.append(
                    HitTestEntry(
                        window: window,
                        columnIndex: columnIndex,
                        frame: frame
                    )
                )
            }
        }
        return entries
    }
}
