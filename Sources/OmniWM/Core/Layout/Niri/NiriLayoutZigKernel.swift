import AppKit
import CZigLayout
import Foundation

enum NiriLayoutZigKernel {
    struct InteractionIndex {
        let windowEntries: [InteractionWindowEntry]
        let windowIndexByNodeId: [NodeId: Int]
    }

    struct LayoutPassResult {
        let windows: [WindowResult]
        let columns: [ColumnResult]
    }

    final class LayoutContext {
        fileprivate let raw: OpaquePointer

        init?() {
            guard let raw = omni_niri_runtime_create() else { return nil }
            self.raw = raw
        }

        @inline(__always)
        func withRawContext<T>(_ body: (OpaquePointer) -> T) -> T {
            body(raw)
        }

        deinit {
            omni_niri_runtime_destroy(raw)
        }
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

    struct InteractionWindowEntry {
        let window: NiriWindow
        let columnIndex: Int
        let frame: CGRect
    }

    struct MoveTargetResult {
        let window: NiriWindow
        let insertPosition: InsertPosition
    }

    enum KernelCallError: Error, Equatable, CustomStringConvertible {
        case runtimeRenderStateMismatch(rc: Int32, columns: Int, windows: Int)
        case runtimeRenderFailed(rc: Int32, columns: Int, windows: Int)
        case hitTestTiledFailed(rc: Int32)
        case hitTestResizeFailed(rc: Int32)
        case hitTestMoveTargetFailed(rc: Int32)
        case insertionDropzoneFailed(rc: Int32)
        case resizeComputeFailed(rc: Int32)

        var description: String {
            switch self {
            case let .runtimeRenderStateMismatch(rc, columns, windows):
                return "omni_niri_runtime_render state mismatch rc=\(rc) columns=\(columns) windows=\(windows)"
            case let .runtimeRenderFailed(rc, columns, windows):
                return "omni_niri_runtime_render failed rc=\(rc) columns=\(columns) windows=\(windows)"
            case let .hitTestTiledFailed(rc):
                return "omni_niri_ctx_hit_test_tiled failed rc=\(rc)"
            case let .hitTestResizeFailed(rc):
                return "omni_niri_ctx_hit_test_resize failed rc=\(rc)"
            case let .hitTestMoveTargetFailed(rc):
                return "omni_niri_ctx_hit_test_move_target failed rc=\(rc)"
            case let .insertionDropzoneFailed(rc):
                return "omni_niri_ctx_insertion_dropzone failed rc=\(rc)"
            case let .resizeComputeFailed(rc):
                return "omni_niri_resize_compute failed rc=\(rc)"
            }
        }
    }

    private static func orientationCode(_ orientation: Monitor.Orientation) -> UInt8 {
        switch orientation {
        case .horizontal:
            UInt8(truncatingIfNeeded: OMNI_NIRI_ORIENTATION_HORIZONTAL.rawValue)
        case .vertical:
            UInt8(truncatingIfNeeded: OMNI_NIRI_ORIENTATION_VERTICAL.rawValue)
        }
    }

    private static func sizingModeCode(_ mode: SizingMode) -> UInt8 {
        switch mode {
        case .normal:
            UInt8(truncatingIfNeeded: OMNI_NIRI_SIZING_NORMAL.rawValue)
        case .fullscreen:
            UInt8(truncatingIfNeeded: OMNI_NIRI_SIZING_FULLSCREEN.rawValue)
        }
    }

    private static func hideSideFromCode(_ code: UInt8) -> HideSide? {
        if code == UInt8(truncatingIfNeeded: OMNI_NIRI_HIDE_LEFT.rawValue) {
            return .left
        }
        if code == UInt8(truncatingIfNeeded: OMNI_NIRI_HIDE_RIGHT.rawValue) {
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

    private static func insertPositionCode(_ position: InsertPosition) -> UInt8 {
        switch position {
        case .before:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_INSERT_BEFORE.rawValue)
        case .after:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_INSERT_AFTER.rawValue)
        case .swap:
            return UInt8(truncatingIfNeeded: OMNI_NIRI_INSERT_SWAP.rawValue)
        }
    }

    private static func insertPositionFromCode(_ code: UInt8) -> InsertPosition? {
        switch code {
        case UInt8(truncatingIfNeeded: OMNI_NIRI_INSERT_BEFORE.rawValue):
            return .before
        case UInt8(truncatingIfNeeded: OMNI_NIRI_INSERT_AFTER.rawValue):
            return .after
        case UInt8(truncatingIfNeeded: OMNI_NIRI_INSERT_SWAP.rawValue):
            return .swap
        default:
            return nil
        }
    }

    static func run(
        context: LayoutContext,
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
    ) throws -> LayoutPassResult {
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

        let renderOnce: () -> Int32 = {
            columnInputs.withUnsafeBufferPointer { colBuf in
                windowInputs.withUnsafeBufferPointer { winBuf in
                    rawOutputs.withUnsafeMutableBufferPointer { winOutBuf in
                        rawColumnOutputs.withUnsafeMutableBufferPointer { colOutBuf in
                            var renderRequest = OmniNiriRuntimeRenderRequest(
                                columns: colBuf.baseAddress,
                                column_count: colBuf.count,
                                windows: winBuf.baseAddress,
                                window_count: winBuf.count,
                                working_x: Double(workingFrame.origin.x),
                                working_y: Double(workingFrame.origin.y),
                                working_width: Double(workingFrame.width),
                                working_height: Double(workingFrame.height),
                                view_x: Double(viewFrame.origin.x),
                                view_y: Double(viewFrame.origin.y),
                                view_width: Double(viewFrame.width),
                                view_height: Double(viewFrame.height),
                                fullscreen_x: Double(fullscreenFrame.origin.x),
                                fullscreen_y: Double(fullscreenFrame.origin.y),
                                fullscreen_width: Double(fullscreenFrame.width),
                                fullscreen_height: Double(fullscreenFrame.height),
                                primary_gap: Double(primaryGap),
                                secondary_gap: Double(secondaryGap),
                                view_start: Double(viewStart),
                                viewport_span: Double(viewportSpan),
                                workspace_offset: Double(workspaceOffset),
                                scale: Double(scale),
                                orientation: orientationCode(orientation)
                            )
                            var renderOutput = OmniNiriRuntimeRenderOutput(
                                windows: winOutBuf.baseAddress,
                                window_count: winOutBuf.count,
                                columns: colOutBuf.baseAddress,
                                column_count: colOutBuf.count
                            )
                            return withUnsafePointer(to: &renderRequest) { requestPtr in
                                withUnsafeMutablePointer(to: &renderOutput) { outputPtr in
                                    omni_niri_runtime_render(
                                        context.raw,
                                        context.raw,
                                        requestPtr,
                                        outputPtr
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }

        let rc = renderOnce()
        guard rc == OMNI_OK else {
            if rc == OMNI_ERR_OUT_OF_RANGE {
                throw KernelCallError.runtimeRenderStateMismatch(
                    rc: rc,
                    columns: columnInputs.count,
                    windows: windowInputs.count
                )
            }
            throw KernelCallError.runtimeRenderFailed(
                rc: rc,
                columns: columnInputs.count,
                windows: windowInputs.count
            )
        }

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

    static func makeInteractionIndex(columns: [NiriContainer]) -> InteractionIndex {
        let estimatedWindowCount = columns.reduce(0) { partial, column in
            partial + column.windowNodes.count
        }

        var entries: [InteractionWindowEntry] = []
        entries.reserveCapacity(estimatedWindowCount)

        var indexByNodeId: [NodeId: Int] = [:]
        indexByNodeId.reserveCapacity(estimatedWindowCount)

        for (columnIndex, column) in columns.enumerated() {
            for window in column.windowNodes {
                guard let frame = window.frame else { continue }
                let index = entries.count
                entries.append(
                    InteractionWindowEntry(
                        window: window,
                        columnIndex: columnIndex,
                        frame: frame
                    )
                )
                indexByNodeId[window.id] = index
            }
        }

        return InteractionIndex(
            windowEntries: entries,
            windowIndexByNodeId: indexByNodeId
        )
    }

    static func makeInteractionIndex(
        view: NiriRuntimeWorkspaceView,
        handleToNode: [WindowHandle: NiriWindow]
    ) -> InteractionIndex {
        var entries: [InteractionWindowEntry] = []
        entries.reserveCapacity(view.windows.count)

        var indexByNodeId: [NodeId: Int] = [:]
        indexByNodeId.reserveCapacity(view.windows.count)

        for window in view.windows {
            guard let handle = window.handle,
                  let windowNode = handleToNode[handle],
                  let frame = windowNode.frame
            else {
                continue
            }
            let entryIndex = entries.count
            entries.append(
                InteractionWindowEntry(
                    window: windowNode,
                    columnIndex: window.columnOrderIndex,
                    frame: frame
                )
            )
            indexByNodeId[window.windowId] = entryIndex
        }

        return InteractionIndex(
            windowEntries: entries,
            windowIndexByNodeId: indexByNodeId
        )
    }

    static func hitTestTiled(
        context: LayoutContext,
        interaction: InteractionIndex,
        point: CGPoint
    ) throws -> NiriWindow? {
        guard !interaction.windowEntries.isEmpty else { return nil }

        var outIndex: Int64 = -1
        let rc = withUnsafeMutablePointer(to: &outIndex) { outPtr in
            omni_niri_ctx_hit_test_tiled(
                context.raw,
                Double(point.x),
                Double(point.y),
                outPtr
            )
        }

        guard rc == OMNI_OK else {
            throw KernelCallError.hitTestTiledFailed(rc: rc)
        }
        guard outIndex >= 0, outIndex < Int64(interaction.windowEntries.count) else { return nil }
        return interaction.windowEntries[Int(outIndex)].window
    }

    static func hitTestResize(
        context: LayoutContext,
        interaction: InteractionIndex,
        point: CGPoint,
        threshold: CGFloat
    ) throws -> ResizeHitResult? {
        guard !interaction.windowEntries.isEmpty else { return nil }

        var out = OmniNiriResizeHitResult(window_index: -1, edges: 0)
        let rc = withUnsafeMutablePointer(to: &out) { outPtr in
            omni_niri_ctx_hit_test_resize(
                context.raw,
                Double(point.x),
                Double(point.y),
                Double(threshold),
                outPtr
            )
        }

        guard rc == OMNI_OK else {
            throw KernelCallError.hitTestResizeFailed(rc: rc)
        }
        guard out.window_index >= 0, out.window_index < Int64(interaction.windowEntries.count) else { return nil }

        let index = Int(out.window_index)
        let entry = interaction.windowEntries[index]
        let edges = resizeEdgeFromCode(out.edges)
        guard !edges.isEmpty else { return nil }

        return ResizeHitResult(
            window: entry.window,
            columnIndex: entry.columnIndex,
            edges: edges,
            frame: entry.frame
        )
    }

    static func hitTestMoveTarget(
        context: LayoutContext,
        interaction: InteractionIndex,
        point: CGPoint,
        excludingWindowId: NodeId,
        isInsertMode: Bool
    ) throws -> MoveTargetResult? {
        guard !interaction.windowEntries.isEmpty else { return nil }

        let excludingIndex = interaction.windowIndexByNodeId[excludingWindowId].map(Int64.init) ?? -1
        var out = OmniNiriMoveTargetResult(
            window_index: -1,
            insert_position: insertPositionCode(.swap)
        )

        let rc = withUnsafeMutablePointer(to: &out) { outPtr in
            omni_niri_ctx_hit_test_move_target(
                context.raw,
                Double(point.x),
                Double(point.y),
                excludingIndex,
                isInsertMode ? 1 : 0,
                outPtr
            )
        }

        guard rc == OMNI_OK else {
            throw KernelCallError.hitTestMoveTargetFailed(rc: rc)
        }
        guard out.window_index >= 0, out.window_index < Int64(interaction.windowEntries.count) else { return nil }
        guard let position = insertPositionFromCode(out.insert_position) else { return nil }

        return MoveTargetResult(
            window: interaction.windowEntries[Int(out.window_index)].window,
            insertPosition: position
        )
    }

    static func insertionDropzoneFrame(
        context: LayoutContext,
        interaction: InteractionIndex,
        targetWindowId: NodeId,
        position: InsertPosition,
        gap: CGFloat
    ) throws -> CGRect? {
        guard let windowIndex = interaction.windowIndexByNodeId[targetWindowId] else { return nil }

        var rawOutput = OmniNiriDropzoneResult(
            frame_x: 0,
            frame_y: 0,
            frame_width: 0,
            frame_height: 0,
            is_valid: 0
        )
        let rc = withUnsafeMutablePointer(to: &rawOutput) { outputPtr in
            omni_niri_ctx_insertion_dropzone(
                context.raw,
                Int64(windowIndex),
                Double(gap),
                insertPositionCode(position),
                outputPtr
            )
        }
        guard rc == OMNI_OK else {
            throw KernelCallError.insertionDropzoneFailed(rc: rc)
        }
        guard rawOutput.is_valid != 0 else { return nil }
        return CGRect(
            x: rawOutput.frame_x,
            y: rawOutput.frame_y,
            width: rawOutput.frame_width,
            height: rawOutput.frame_height
        )
    }

    static func computeResize(_ input: ResizeComputationInput) throws -> ResizeComputationResult {
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
        guard rc == OMNI_OK else {
            throw KernelCallError.resizeComputeFailed(rc: rc)
        }

        return ResizeComputationResult(
            changedWidth: rawOutput.changed_width != 0,
            newColumnWidth: CGFloat(rawOutput.new_column_width),
            changedWeight: rawOutput.changed_weight != 0,
            newWindowWeight: CGFloat(rawOutput.new_window_weight),
            adjustViewOffset: rawOutput.adjust_view_offset != 0,
            newViewOffset: CGFloat(rawOutput.new_view_offset)
        )
    }

}
