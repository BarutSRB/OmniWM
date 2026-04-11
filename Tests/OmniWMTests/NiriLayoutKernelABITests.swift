import COmniWMKernels
import Foundation
import Testing

private func makeNiriLayoutInput(
    workingFrame: CGRect = CGRect(x: 0, y: 0, width: 1600, height: 900),
    viewFrame: CGRect? = nil,
    scale: CGFloat = 2.0,
    primaryGap: CGFloat = 8,
    secondaryGap: CGFloat = 8,
    viewOffset: CGFloat = 0,
    workspaceOffset: CGFloat = 0,
    aspectRatio: CGFloat = 4.0 / 3.0,
    activeContainerIndex: Int32 = 0,
    hiddenPlacementMonitorIndex: Int32 = -1,
    orientation: UInt32 = UInt32(OMNIWM_NIRI_ORIENTATION_HORIZONTAL),
    singleWindowMode: Bool = false
) -> omniwm_niri_layout_input {
    let resolvedViewFrame = viewFrame ?? workingFrame
    return omniwm_niri_layout_input(
        working_x: workingFrame.minX,
        working_y: workingFrame.minY,
        working_width: workingFrame.width,
        working_height: workingFrame.height,
        view_x: resolvedViewFrame.minX,
        view_y: resolvedViewFrame.minY,
        view_width: resolvedViewFrame.width,
        view_height: resolvedViewFrame.height,
        scale: scale,
        primary_gap: primaryGap,
        secondary_gap: secondaryGap,
        tab_indicator_width: 0,
        view_offset: viewOffset,
        workspace_offset: workspaceOffset,
        single_window_aspect_ratio: aspectRatio,
        single_window_aspect_tolerance: 0.001,
        active_container_index: activeContainerIndex,
        hidden_placement_monitor_index: hiddenPlacementMonitorIndex,
        orientation: orientation,
        single_window_mode: singleWindowMode ? 1 : 0
    )
}

private func makeNiriContainerInput(
    span: CGFloat,
    windowStartIndex: UInt32,
    windowCount: UInt32,
    isTabbed: Bool = false,
    manualSingleWindowWidthOverride: Bool = false
) -> omniwm_niri_container_input {
    omniwm_niri_container_input(
        span: span,
        render_offset_x: 0,
        render_offset_y: 0,
        window_start_index: windowStartIndex,
        window_count: windowCount,
        is_tabbed: isTabbed ? 1 : 0,
        has_manual_single_window_width_override: manualSingleWindowWidthOverride ? 1 : 0
    )
}

private func makeNiriWindowInput(
    sizingMode: UInt8 = UInt8(OMNIWM_NIRI_WINDOW_SIZING_NORMAL)
) -> omniwm_niri_window_input {
    omniwm_niri_window_input(
        weight: 1,
        min_constraint: 1,
        max_constraint: 0,
        fixed_value: 0,
        render_offset_x: 0,
        render_offset_y: 0,
        has_max_constraint: 0,
        is_constraint_fixed: 0,
        has_fixed_value: 0,
        sizing_mode: sizingMode
    )
}

private func zeroContainerOutput() -> omniwm_niri_container_output {
    omniwm_niri_container_output(
        canonical_x: 0,
        canonical_y: 0,
        canonical_width: 0,
        canonical_height: 0,
        rendered_x: 0,
        rendered_y: 0,
        rendered_width: 0,
        rendered_height: 0
    )
}

private func zeroWindowOutput() -> omniwm_niri_window_output {
    omniwm_niri_window_output(
        canonical_x: 0,
        canonical_y: 0,
        canonical_width: 0,
        canonical_height: 0,
        rendered_x: 0,
        rendered_y: 0,
        rendered_width: 0,
        rendered_height: 0,
        resolved_span: 0,
        hidden_edge: 0
    )
}

private func sentinelContainerOutput() -> omniwm_niri_container_output {
    omniwm_niri_container_output(
        canonical_x: 999,
        canonical_y: 999,
        canonical_width: 999,
        canonical_height: 999,
        rendered_x: 999,
        rendered_y: 999,
        rendered_width: 999,
        rendered_height: 999
    )
}

private func sentinelWindowOutput() -> omniwm_niri_window_output {
    omniwm_niri_window_output(
        canonical_x: 999,
        canonical_y: 999,
        canonical_width: 999,
        canonical_height: 999,
        rendered_x: 999,
        rendered_y: 999,
        rendered_width: 999,
        rendered_height: 999,
        resolved_span: 999,
        hidden_edge: 255
    )
}

private func makeNiriTopologyInput(
    operation: UInt32,
    direction: UInt32 = UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_RIGHT),
    centerMode: UInt32 = UInt32(OMNIWM_CENTER_FOCUSED_COLUMN_ON_OVERFLOW),
    subjectWindowId: UInt64 = 0,
    targetWindowId: UInt64 = 0,
    selectedWindowId: UInt64 = 0,
    activeColumnIndex: Int32 = 0,
    insertIndex: Int32 = 0,
    targetIndex: Int32 = 0,
    fromColumnIndex: Int32 = -1,
    maxWindowsPerColumn: UInt32 = 3,
    gap: Double = 8,
    viewportSpan: Double = 1000,
    currentViewOffset: Double = 0,
    stationaryViewOffset: Double = 0,
    defaultNewColumnSpan: Double = 400,
    infiniteLoop: Bool = false,
    animate: Bool = false
) -> omniwm_niri_topology_input {
    omniwm_niri_topology_input(
        operation: operation,
        direction: direction,
        orientation: UInt32(OMNIWM_NIRI_ORIENTATION_HORIZONTAL),
        center_mode: centerMode,
        subject_window_id: subjectWindowId,
        target_window_id: targetWindowId,
        selected_window_id: selectedWindowId,
        focused_window_id: 0,
        active_column_index: activeColumnIndex,
        insert_index: insertIndex,
        target_index: targetIndex,
        from_column_index: fromColumnIndex,
        max_windows_per_column: maxWindowsPerColumn,
        gap: gap,
        viewport_span: viewportSpan,
        current_view_offset: currentViewOffset,
        stationary_view_offset: stationaryViewOffset,
        scale: 2,
        default_new_column_span: defaultNewColumnSpan,
        previous_active_position: 0,
        activate_prev_column_on_removal: 0,
        infinite_loop: infiniteLoop ? 1 : 0,
        always_center_single_column: 0,
        animate: animate ? 1 : 0,
        has_previous_active_position: 0,
        has_activate_prev_column_on_removal: 0,
        reset_for_single_window: 0,
        is_active_workspace: 1,
        has_completed_initial_refresh: 1,
        viewport_is_gesture_or_animation: 0
    )
}

private func makeNiriTopologyColumn(
    id: UInt64,
    span: Double,
    windowStartIndex: UInt32,
    windowCount: UInt32,
    activeWindowIndex: Int32 = 0,
    isTabbed: Bool = false
) -> omniwm_niri_topology_column_input {
    omniwm_niri_topology_column_input(
        id: id,
        span: span,
        window_start_index: windowStartIndex,
        window_count: windowCount,
        active_window_index: activeWindowIndex,
        is_tabbed: isTabbed ? 1 : 0
    )
}

private func makeNiriTopologyWindow(
    id: UInt64,
    sizingMode: UInt8 = UInt8(OMNIWM_NIRI_WINDOW_SIZING_NORMAL)
) -> omniwm_niri_topology_window_input {
    omniwm_niri_topology_window_input(
        id: id,
        sizing_mode: sizingMode
    )
}

private func makeNiriTopologyResult() -> omniwm_niri_topology_result {
    omniwm_niri_topology_result(
        column_count: 0,
        window_count: 0,
        selected_window_id: 0,
        remembered_focus_window_id: 0,
        new_window_id: 0,
        fallback_window_id: 0,
        active_column_index: -1,
        source_column_index: -1,
        target_column_index: -1,
        source_window_index: -1,
        target_window_index: -1,
        viewport_action: UInt32(OMNIWM_NIRI_TOPOLOGY_VIEWPORT_NONE),
        effect_kind: UInt32(OMNIWM_NIRI_TOPOLOGY_EFFECT_NONE),
        viewport_offset_delta: 0,
        viewport_target_offset: 0,
        restore_previous_view_offset: 0,
        activate_prev_column_on_removal: 0,
        has_restore_previous_view_offset: 0,
        has_activate_prev_column_on_removal: 0,
        should_clear_activate_prev_column_on_removal: 0,
        source_column_became_empty: 0,
        inserted_before_active: 0,
        did_apply: 0
    )
}

private func callNiriTopology(
    input: inout omniwm_niri_topology_input,
    columns: [omniwm_niri_topology_column_input],
    windows: [omniwm_niri_topology_window_input],
    desiredIds: [UInt64] = [],
    removedIds: [UInt64] = [],
    columnCapacity: Int? = nil,
    windowCapacity: Int? = nil
) -> (
    status: Int32,
    columns: [omniwm_niri_topology_column_output],
    windows: [omniwm_niri_topology_window_output],
    result: omniwm_niri_topology_result
) {
    var columnOutputs = Array(
        repeating: omniwm_niri_topology_column_output(
            id: 0,
            window_start_index: 0,
            window_count: 0,
            active_window_index: 0,
            is_tabbed: 0
        ),
        count: columnCapacity ?? max(columns.count + desiredIds.count + 2, 1)
    )
    var windowOutputs = Array(
        repeating: omniwm_niri_topology_window_output(id: 0),
        count: windowCapacity ?? max(windows.count + desiredIds.count + 1, 1)
    )
    var result = makeNiriTopologyResult()

    let status = columns.withUnsafeBufferPointer { columnBuffer in
        windows.withUnsafeBufferPointer { windowBuffer in
            desiredIds.withUnsafeBufferPointer { desiredBuffer in
                removedIds.withUnsafeBufferPointer { removedBuffer in
                    columnOutputs.withUnsafeMutableBufferPointer { columnOutputBuffer in
                        windowOutputs.withUnsafeMutableBufferPointer { windowOutputBuffer in
                            omniwm_niri_topology_plan(
                                &input,
                                columnBuffer.baseAddress,
                                columnBuffer.count,
                                windowBuffer.baseAddress,
                                windowBuffer.count,
                                desiredBuffer.baseAddress,
                                desiredBuffer.count,
                                removedBuffer.baseAddress,
                                removedBuffer.count,
                                columnOutputBuffer.baseAddress,
                                columnOutputBuffer.count,
                                windowOutputBuffer.baseAddress,
                                windowOutputBuffer.count,
                                &result
                            )
                        }
                    }
                }
            }
        }
    }

    columnOutputs.removeSubrange(min(Int(result.column_count), columnOutputs.count) ..< columnOutputs.count)
    windowOutputs.removeSubrange(min(Int(result.window_count), windowOutputs.count) ..< windowOutputs.count)
    return (status, columnOutputs, windowOutputs, result)
}

struct NiriLayoutKernelABITests {
    @Test func emptyBuffersReturnSuccess() {
        #expect(
            omniwm_niri_layout_solve(
                nil,
                nil,
                0,
                nil,
                0,
                nil,
                0,
                nil,
                0,
                nil,
                0
            ) == OMNIWM_KERNELS_STATUS_OK
        )
    }

    @Test func singleWindowModeAspectFitsAndPreservesExtraOutputCapacity() {
        var input = makeNiriLayoutInput(singleWindowMode: true)
        let containers = [makeNiriContainerInput(span: 0, windowStartIndex: 0, windowCount: 1)]
        let windows = [makeNiriWindowInput()]
        var containerOutputs = [zeroContainerOutput(), sentinelContainerOutput()]
        var windowOutputs = [zeroWindowOutput(), sentinelWindowOutput()]

        let status = containers.withUnsafeBufferPointer { containerBuffer in
            windows.withUnsafeBufferPointer { windowBuffer in
                containerOutputs.withUnsafeMutableBufferPointer { containerOutputBuffer in
                    windowOutputs.withUnsafeMutableBufferPointer { windowOutputBuffer in
                        omniwm_niri_layout_solve(
                            &input,
                            containerBuffer.baseAddress,
                            containerBuffer.count,
                            windowBuffer.baseAddress,
                            windowBuffer.count,
                            nil,
                            0,
                            containerOutputBuffer.baseAddress,
                            containerOutputBuffer.count,
                            windowOutputBuffer.baseAddress,
                            windowOutputBuffer.count
                        )
                    }
                }
            }
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
        #expect(abs(containerOutputs[0].canonical_x - 200) < 0.001)
        #expect(abs(containerOutputs[0].canonical_width - 1200) < 0.001)
        #expect(abs(windowOutputs[0].rendered_x - 200) < 0.001)
        #expect(abs(windowOutputs[0].rendered_width - 1200) < 0.001)
        #expect(abs(windowOutputs[0].resolved_span - 900) < 0.001)
        #expect(windowOutputs[0].hidden_edge == UInt8(OMNIWM_NIRI_HIDDEN_EDGE_NONE))
        #expect(containerOutputs[1].canonical_x == 999)
        #expect(windowOutputs[1].resolved_span == 999)
        #expect(windowOutputs[1].hidden_edge == 255)
    }

    @Test func offscreenSecondContainerReturnsMaximumHiddenEdgeInStableIndexOrder() {
        var input = makeNiriLayoutInput(
            workingFrame: CGRect(x: 0, y: 0, width: 600, height: 900),
            viewFrame: CGRect(x: 0, y: 0, width: 600, height: 900)
        )
        let containers = [
            makeNiriContainerInput(span: 600, windowStartIndex: 0, windowCount: 1),
            makeNiriContainerInput(span: 600, windowStartIndex: 1, windowCount: 1)
        ]
        let windows = [makeNiriWindowInput(), makeNiriWindowInput()]
        var containerOutputs = [zeroContainerOutput(), zeroContainerOutput()]
        var windowOutputs = [zeroWindowOutput(), zeroWindowOutput()]

        let status = containers.withUnsafeBufferPointer { containerBuffer in
            windows.withUnsafeBufferPointer { windowBuffer in
                containerOutputs.withUnsafeMutableBufferPointer { containerOutputBuffer in
                    windowOutputs.withUnsafeMutableBufferPointer { windowOutputBuffer in
                        omniwm_niri_layout_solve(
                            &input,
                            containerBuffer.baseAddress,
                            containerBuffer.count,
                            windowBuffer.baseAddress,
                            windowBuffer.count,
                            nil,
                            0,
                            containerOutputBuffer.baseAddress,
                            containerOutputBuffer.count,
                            windowOutputBuffer.baseAddress,
                            windowOutputBuffer.count
                        )
                    }
                }
            }
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
        #expect(abs(containerOutputs[0].canonical_x - 0) < 0.001)
        #expect(abs(containerOutputs[1].canonical_x - 608) < 0.001)
        #expect(abs(windowOutputs[0].canonical_x - 0) < 0.001)
        #expect(abs(windowOutputs[1].canonical_x - 608) < 0.001)
        #expect(abs(windowOutputs[1].rendered_x - 599.5) < 0.001)
        #expect(windowOutputs[1].hidden_edge == UInt8(OMNIWM_NIRI_HIDDEN_EDGE_MAXIMUM))
    }

    @Test func insufficientOutputCapacityReturnsInvalidArgument() {
        var input = makeNiriLayoutInput()
        let containers = [makeNiriContainerInput(span: 400, windowStartIndex: 0, windowCount: 1)]
        let windows = [makeNiriWindowInput()]
        var containerOutputs = [zeroContainerOutput()]
        var windowOutputs: [omniwm_niri_window_output] = []

        let status = containers.withUnsafeBufferPointer { containerBuffer in
            windows.withUnsafeBufferPointer { windowBuffer in
                containerOutputs.withUnsafeMutableBufferPointer { containerOutputBuffer in
                    windowOutputs.withUnsafeMutableBufferPointer { windowOutputBuffer in
                        omniwm_niri_layout_solve(
                            &input,
                            containerBuffer.baseAddress,
                            containerBuffer.count,
                            windowBuffer.baseAddress,
                            windowBuffer.count,
                            nil,
                            0,
                            containerOutputBuffer.baseAddress,
                            containerOutputBuffer.count,
                            windowOutputBuffer.baseAddress,
                            windowOutputBuffer.count
                        )
                    }
                }
            }
        }

        #expect(status == OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT)
    }
}

struct NiriTopologyKernelABITests {
    @Test func addWindowIntoEmptyTopologyCreatesColumnAndSelection() {
        var input = makeNiriTopologyInput(
            operation: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_ADD_WINDOW),
            subjectWindowId: 42
        )

        let output = callNiriTopology(input: &input, columns: [], windows: [])

        #expect(output.status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.result.column_count == 1)
        #expect(output.result.window_count == 1)
        #expect(output.result.new_window_id == 42)
        #expect(output.result.selected_window_id == 42)
        #expect(output.result.effect_kind == UInt32(OMNIWM_NIRI_TOPOLOGY_EFFECT_ADD_COLUMN))
        #expect(output.windows.map(\.id) == [42])
    }

    @Test func removeFocusedWindowReturnsSiblingFallbackAndCompactedMembership() {
        var input = makeNiriTopologyInput(
            operation: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_REMOVE_WINDOW),
            subjectWindowId: 20,
            selectedWindowId: 20
        )
        let columns = [
            makeNiriTopologyColumn(
                id: 1,
                span: 500,
                windowStartIndex: 0,
                windowCount: 3,
                activeWindowIndex: 1
            )
        ]
        let windows = [10, 20, 30].map { makeNiriTopologyWindow(id: UInt64($0)) }

        let output = callNiriTopology(input: &input, columns: columns, windows: windows)

        #expect(output.status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.result.column_count == 1)
        #expect(output.result.window_count == 2)
        #expect(output.result.fallback_window_id == 30)
        #expect(output.result.selected_window_id == 30)
        #expect(output.columns[0].window_count == 2)
        #expect(output.windows.map(\.id) == [10, 30])
    }

    @Test func ensureVisibleAppliesEdgePaddingWhenTargetColumnTouchesViewportBoundary() {
        var input = makeNiriTopologyInput(
            operation: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_ENSURE_VISIBLE),
            subjectWindowId: 10,
            selectedWindowId: 10,
            activeColumnIndex: 0,
            viewportSpan: 900
        )
        let columns = [
            makeNiriTopologyColumn(id: 1, span: 400, windowStartIndex: 0, windowCount: 1),
            makeNiriTopologyColumn(id: 2, span: 400, windowStartIndex: 1, windowCount: 1)
        ]
        let windows = [10, 20].map { makeNiriTopologyWindow(id: UInt64($0)) }

        let output = callNiriTopology(input: &input, columns: columns, windows: windows)

        #expect(output.status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.result.viewport_action == UInt32(OMNIWM_NIRI_TOPOLOGY_VIEWPORT_SET_STATIC))
        #expect(abs(output.result.viewport_offset_delta) < 0.001)
        #expect(abs(output.result.viewport_target_offset + 8) < 0.001)
        #expect(output.result.active_column_index == 0)
        #expect(output.windows.map(\.id) == [10, 20])
    }

    @Test func ensureVisibleNoOpsWhenTargetColumnAlreadyFitsInNeverMode() {
        var input = makeNiriTopologyInput(
            operation: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_ENSURE_VISIBLE),
            centerMode: UInt32(OMNIWM_CENTER_FOCUSED_COLUMN_NEVER),
            subjectWindowId: 10,
            selectedWindowId: 10,
            activeColumnIndex: 0,
            viewportSpan: 900
        )
        let columns = [
            makeNiriTopologyColumn(id: 1, span: 400, windowStartIndex: 0, windowCount: 1),
            makeNiriTopologyColumn(id: 2, span: 400, windowStartIndex: 1, windowCount: 1)
        ]
        let windows = [10, 20].map { makeNiriTopologyWindow(id: UInt64($0)) }

        let output = callNiriTopology(input: &input, columns: columns, windows: windows)

        #expect(output.status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.result.viewport_action == UInt32(OMNIWM_NIRI_TOPOLOGY_VIEWPORT_NONE))
        #expect(abs(output.result.viewport_offset_delta) < 0.001)
        #expect(output.result.active_column_index == 0)
        #expect(output.windows.map(\.id) == [10, 20])
    }

    @Test func ensureVisibleAlwaysModeCentersOversizedColumn() {
        var input = makeNiriTopologyInput(
            operation: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_ENSURE_VISIBLE),
            centerMode: UInt32(OMNIWM_CENTER_FOCUSED_COLUMN_ALWAYS),
            subjectWindowId: 20,
            selectedWindowId: 20,
            activeColumnIndex: 0,
            targetIndex: 1,
            gap: 10,
            viewportSpan: 150
        )
        let columns = [
            makeNiriTopologyColumn(id: 1, span: 100, windowStartIndex: 0, windowCount: 1),
            makeNiriTopologyColumn(id: 2, span: 200, windowStartIndex: 1, windowCount: 1),
            makeNiriTopologyColumn(id: 3, span: 100, windowStartIndex: 2, windowCount: 1)
        ]
        let windows = [10, 20, 30].map { makeNiriTopologyWindow(id: UInt64($0)) }

        let output = callNiriTopology(input: &input, columns: columns, windows: windows)

        #expect(output.status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.result.viewport_action == UInt32(OMNIWM_NIRI_TOPOLOGY_VIEWPORT_SET_STATIC))
        #expect(abs(output.result.viewport_target_offset - 25) < 0.001)
        #expect(output.result.active_column_index == 1)
    }

    @Test func focusColumnCentersEdgeColumnsWhenAlwaysModeEnabled() {
        let columns = [
            makeNiriTopologyColumn(id: 1, span: 400, windowStartIndex: 0, windowCount: 1),
            makeNiriTopologyColumn(id: 2, span: 400, windowStartIndex: 1, windowCount: 1),
        ]
        let windows = [10, 20].map { makeNiriTopologyWindow(id: UInt64($0)) }

        var focusLast = makeNiriTopologyInput(
            operation: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_FOCUS_COLUMN),
            centerMode: UInt32(OMNIWM_CENTER_FOCUSED_COLUMN_ALWAYS),
            selectedWindowId: 10,
            activeColumnIndex: 0,
            targetIndex: 1,
            viewportSpan: 1200
        )
        let lastOutput = callNiriTopology(input: &focusLast, columns: columns, windows: windows)

        #expect(lastOutput.status == OMNIWM_KERNELS_STATUS_OK)
        #expect(lastOutput.result.viewport_action == UInt32(OMNIWM_NIRI_TOPOLOGY_VIEWPORT_SET_STATIC))
        #expect(lastOutput.result.active_column_index == 1)
        #expect(abs(lastOutput.result.viewport_target_offset + 400) < 0.001)

        var focusFirst = makeNiriTopologyInput(
            operation: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_FOCUS_COLUMN),
            centerMode: UInt32(OMNIWM_CENTER_FOCUSED_COLUMN_ALWAYS),
            selectedWindowId: 20,
            activeColumnIndex: 1,
            targetIndex: 0,
            viewportSpan: 1200
        )
        let firstOutput = callNiriTopology(input: &focusFirst, columns: columns, windows: windows)

        #expect(firstOutput.status == OMNIWM_KERNELS_STATUS_OK)
        #expect(firstOutput.result.viewport_action == UInt32(OMNIWM_NIRI_TOPOLOGY_VIEWPORT_SET_STATIC))
        #expect(firstOutput.result.active_column_index == 0)
        #expect(abs(firstOutput.result.viewport_target_offset + 400) < 0.001)
    }

    @Test func ensureVisibleAlwaysModeKeepsFullscreenEdgeColumnsMonitorAnchored() {
        let columns = [
            makeNiriTopologyColumn(id: 1, span: 400, windowStartIndex: 0, windowCount: 1),
            makeNiriTopologyColumn(id: 2, span: 400, windowStartIndex: 1, windowCount: 1),
        ]

        var ensureLast = makeNiriTopologyInput(
            operation: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_ENSURE_VISIBLE),
            centerMode: UInt32(OMNIWM_CENTER_FOCUSED_COLUMN_ALWAYS),
            subjectWindowId: 20,
            selectedWindowId: 10,
            activeColumnIndex: 0,
            viewportSpan: 1_200
        )
        let lastOutput = callNiriTopology(
            input: &ensureLast,
            columns: columns,
            windows: [
                makeNiriTopologyWindow(id: 10),
                makeNiriTopologyWindow(
                    id: 20,
                    sizingMode: UInt8(OMNIWM_NIRI_WINDOW_SIZING_FULLSCREEN)
                ),
            ]
        )

        #expect(lastOutput.status == OMNIWM_KERNELS_STATUS_OK)
        #expect(lastOutput.result.viewport_action == UInt32(OMNIWM_NIRI_TOPOLOGY_VIEWPORT_SET_STATIC))
        #expect(lastOutput.result.active_column_index == 1)
        #expect(abs(lastOutput.result.viewport_target_offset) < 0.001)

        var ensureFirst = makeNiriTopologyInput(
            operation: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_ENSURE_VISIBLE),
            centerMode: UInt32(OMNIWM_CENTER_FOCUSED_COLUMN_ALWAYS),
            subjectWindowId: 10,
            selectedWindowId: 20,
            activeColumnIndex: 1,
            viewportSpan: 1_200
        )
        let firstOutput = callNiriTopology(
            input: &ensureFirst,
            columns: columns,
            windows: [
                makeNiriTopologyWindow(
                    id: 10,
                    sizingMode: UInt8(OMNIWM_NIRI_WINDOW_SIZING_FULLSCREEN)
                ),
                makeNiriTopologyWindow(id: 20),
            ]
        )

        #expect(firstOutput.status == OMNIWM_KERNELS_STATUS_OK)
        #expect(firstOutput.result.viewport_action == UInt32(OMNIWM_NIRI_TOPOLOGY_VIEWPORT_SET_STATIC))
        #expect(firstOutput.result.active_column_index == 0)
        #expect(abs(firstOutput.result.viewport_target_offset) < 0.001)
    }

    @Test func ensureVisibleOnOverflowUsesNeighborPairWidthToChooseFitOrCenter() {
        let columns = [
            makeNiriTopologyColumn(id: 1, span: 100, windowStartIndex: 0, windowCount: 1),
            makeNiriTopologyColumn(id: 2, span: 100, windowStartIndex: 1, windowCount: 1),
            makeNiriTopologyColumn(id: 3, span: 100, windowStartIndex: 2, windowCount: 1),
        ]
        let windows = [10, 20, 30].map { makeNiriTopologyWindow(id: UInt64($0)) }

        var fittingPair = makeNiriTopologyInput(
            operation: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_ENSURE_VISIBLE),
            centerMode: UInt32(OMNIWM_CENTER_FOCUSED_COLUMN_ON_OVERFLOW),
            subjectWindowId: 20,
            selectedWindowId: 10,
            activeColumnIndex: 0,
            viewportSpan: 230
        )
        let fittingOutput = callNiriTopology(input: &fittingPair, columns: columns, windows: windows)

        #expect(fittingOutput.status == OMNIWM_KERNELS_STATUS_OK)
        #expect(fittingOutput.result.viewport_action == UInt32(OMNIWM_NIRI_TOPOLOGY_VIEWPORT_DELTA_ONLY))
        #expect(fittingOutput.result.active_column_index == 1)
        #expect(abs(fittingOutput.result.viewport_target_offset + 108) < 0.001)

        var overflowingPair = makeNiriTopologyInput(
            operation: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_ENSURE_VISIBLE),
            centerMode: UInt32(OMNIWM_CENTER_FOCUSED_COLUMN_ON_OVERFLOW),
            subjectWindowId: 20,
            selectedWindowId: 10,
            activeColumnIndex: 0,
            viewportSpan: 220
        )
        let overflowingOutput = callNiriTopology(input: &overflowingPair, columns: columns, windows: windows)

        #expect(overflowingOutput.status == OMNIWM_KERNELS_STATUS_OK)
        #expect(overflowingOutput.result.viewport_action == UInt32(OMNIWM_NIRI_TOPOLOGY_VIEWPORT_SET_STATIC))
        #expect(overflowingOutput.result.active_column_index == 1)
        #expect(abs(overflowingOutput.result.viewport_target_offset + 60) < 0.001)
    }

    @Test func ensureVisibleOnOverflowUsesFullscreenTargetAndSourceModes() {
        let columns = [
            makeNiriTopologyColumn(id: 1, span: 400, windowStartIndex: 0, windowCount: 1),
            makeNiriTopologyColumn(id: 2, span: 400, windowStartIndex: 1, windowCount: 1),
        ]

        var fullscreenTarget = makeNiriTopologyInput(
            operation: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_ENSURE_VISIBLE),
            centerMode: UInt32(OMNIWM_CENTER_FOCUSED_COLUMN_ON_OVERFLOW),
            subjectWindowId: 20,
            selectedWindowId: 10,
            activeColumnIndex: 0,
            viewportSpan: 1_200
        )
        let targetOutput = callNiriTopology(
            input: &fullscreenTarget,
            columns: columns,
            windows: [
                makeNiriTopologyWindow(id: 10),
                makeNiriTopologyWindow(
                    id: 20,
                    sizingMode: UInt8(OMNIWM_NIRI_WINDOW_SIZING_FULLSCREEN)
                ),
            ]
        )

        #expect(targetOutput.status == OMNIWM_KERNELS_STATUS_OK)
        #expect(targetOutput.result.viewport_action == UInt32(OMNIWM_NIRI_TOPOLOGY_VIEWPORT_SET_STATIC))
        #expect(targetOutput.result.active_column_index == 1)
        #expect(abs(targetOutput.result.viewport_target_offset) < 0.001)

        var fullscreenSource = makeNiriTopologyInput(
            operation: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_ENSURE_VISIBLE),
            centerMode: UInt32(OMNIWM_CENTER_FOCUSED_COLUMN_ON_OVERFLOW),
            subjectWindowId: 20,
            selectedWindowId: 10,
            activeColumnIndex: 0,
            viewportSpan: 1_200
        )
        let sourceOutput = callNiriTopology(
            input: &fullscreenSource,
            columns: columns,
            windows: [
                makeNiriTopologyWindow(
                    id: 10,
                    sizingMode: UInt8(OMNIWM_NIRI_WINDOW_SIZING_FULLSCREEN)
                ),
                makeNiriTopologyWindow(id: 20),
            ]
        )

        #expect(sourceOutput.status == OMNIWM_KERNELS_STATUS_OK)
        #expect(sourceOutput.result.viewport_action == UInt32(OMNIWM_NIRI_TOPOLOGY_VIEWPORT_DELTA_ONLY))
        #expect(sourceOutput.result.active_column_index == 1)
        #expect(abs(sourceOutput.result.viewport_target_offset + 408) < 0.001)
    }

    @Test func focusColumnOnOverflowCentersFirstAndLastColumnsWhenPairsOverflow() {
        let columns = [
            makeNiriTopologyColumn(id: 1, span: 100, windowStartIndex: 0, windowCount: 1),
            makeNiriTopologyColumn(id: 2, span: 100, windowStartIndex: 1, windowCount: 1),
            makeNiriTopologyColumn(id: 3, span: 100, windowStartIndex: 2, windowCount: 1),
        ]
        let windows = [10, 20, 30].map { makeNiriTopologyWindow(id: UInt64($0)) }

        var focusFirst = makeNiriTopologyInput(
            operation: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_FOCUS_COLUMN),
            centerMode: UInt32(OMNIWM_CENTER_FOCUSED_COLUMN_ON_OVERFLOW),
            selectedWindowId: 20,
            activeColumnIndex: 1,
            targetIndex: 0,
            viewportSpan: 220
        )
        let firstOutput = callNiriTopology(input: &focusFirst, columns: columns, windows: windows)

        #expect(firstOutput.status == OMNIWM_KERNELS_STATUS_OK)
        #expect(firstOutput.result.viewport_action == UInt32(OMNIWM_NIRI_TOPOLOGY_VIEWPORT_SET_STATIC))
        #expect(firstOutput.result.active_column_index == 0)
        #expect(abs(firstOutput.result.viewport_target_offset + 60) < 0.001)

        var focusLast = makeNiriTopologyInput(
            operation: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_FOCUS_COLUMN),
            centerMode: UInt32(OMNIWM_CENTER_FOCUSED_COLUMN_ON_OVERFLOW),
            selectedWindowId: 20,
            activeColumnIndex: 1,
            targetIndex: 2,
            viewportSpan: 220
        )
        let lastOutput = callNiriTopology(input: &focusLast, columns: columns, windows: windows)

        #expect(lastOutput.status == OMNIWM_KERNELS_STATUS_OK)
        #expect(lastOutput.result.viewport_action == UInt32(OMNIWM_NIRI_TOPOLOGY_VIEWPORT_SET_STATIC))
        #expect(lastOutput.result.active_column_index == 2)
        #expect(abs(lastOutput.result.viewport_target_offset + 60) < 0.001)
    }

    @Test func ensureVisibleTreatsTabbedColumnWithAnyFullscreenChildAsFullscreen() {
        var input = makeNiriTopologyInput(
            operation: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_ENSURE_VISIBLE),
            centerMode: UInt32(OMNIWM_CENTER_FOCUSED_COLUMN_ALWAYS),
            subjectWindowId: 11,
            selectedWindowId: 20,
            activeColumnIndex: 1,
            viewportSpan: 1_200
        )
        let columns = [
            makeNiriTopologyColumn(
                id: 1,
                span: 400,
                windowStartIndex: 0,
                windowCount: 2,
                activeWindowIndex: 0,
                isTabbed: true
            ),
            makeNiriTopologyColumn(id: 2, span: 400, windowStartIndex: 2, windowCount: 1),
        ]
        let windows = [
            makeNiriTopologyWindow(id: 11),
            makeNiriTopologyWindow(
                id: 12,
                sizingMode: UInt8(OMNIWM_NIRI_WINDOW_SIZING_FULLSCREEN)
            ),
            makeNiriTopologyWindow(id: 20),
        ]

        let output = callNiriTopology(input: &input, columns: columns, windows: windows)

        #expect(output.status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.result.viewport_action == UInt32(OMNIWM_NIRI_TOPOLOGY_VIEWPORT_SET_STATIC))
        #expect(output.result.active_column_index == 0)
        #expect(abs(output.result.viewport_target_offset) < 0.001)
    }

    @Test func insufficientTopologyOutputCapacityReportsRequiredCounts() {
        var input = makeNiriTopologyInput(
            operation: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_MOVE_WINDOW),
            direction: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_LEFT),
            subjectWindowId: 20,
            selectedWindowId: 20,
            activeColumnIndex: 1
        )
        let columns = [
            makeNiriTopologyColumn(id: 1, span: 400, windowStartIndex: 0, windowCount: 1),
            makeNiriTopologyColumn(id: 2, span: 400, windowStartIndex: 1, windowCount: 1)
        ]
        let windows = [10, 20].map { makeNiriTopologyWindow(id: UInt64($0)) }

        let output = callNiriTopology(
            input: &input,
            columns: columns,
            windows: windows,
            columnCapacity: 1,
            windowCapacity: 1
        )

        #expect(output.status == OMNIWM_KERNELS_STATUS_BUFFER_TOO_SMALL)
        #expect(output.result.column_count == 1)
        #expect(output.result.window_count == 2)
    }

    @Test func swapWindowsExchangesCrossColumnMembership() {
        var input = makeNiriTopologyInput(
            operation: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_SWAP_WINDOWS),
            subjectWindowId: 10,
            targetWindowId: 20,
            selectedWindowId: 10
        )
        let columns = [
            makeNiriTopologyColumn(id: 1, span: 400, windowStartIndex: 0, windowCount: 1),
            makeNiriTopologyColumn(id: 2, span: 400, windowStartIndex: 1, windowCount: 1)
        ]
        let windows = [10, 20].map { makeNiriTopologyWindow(id: UInt64($0)) }

        let output = callNiriTopology(input: &input, columns: columns, windows: windows)

        #expect(output.status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.result.effect_kind == UInt32(OMNIWM_NIRI_TOPOLOGY_EFFECT_REORDER_WINDOW))
        #expect(output.result.source_column_index == 0)
        #expect(output.result.target_column_index == 1)
        #expect(output.columns.map(\.window_count) == [1, 1])
        #expect(output.windows.map(\.id) == [20, 10])
    }

    @Test func insertWindowByMoveReordersWithinColumn() {
        var input = makeNiriTopologyInput(
            operation: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_INSERT_WINDOW_BY_MOVE),
            subjectWindowId: 10,
            targetWindowId: 30,
            selectedWindowId: 10,
            insertIndex: Int32(OMNIWM_NIRI_TOPOLOGY_INSERT_AFTER)
        )
        let columns = [
            makeNiriTopologyColumn(id: 1, span: 400, windowStartIndex: 0, windowCount: 3)
        ]
        let windows = [10, 20, 30].map { makeNiriTopologyWindow(id: UInt64($0)) }

        let output = callNiriTopology(input: &input, columns: columns, windows: windows)

        #expect(output.status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.result.effect_kind == UInt32(OMNIWM_NIRI_TOPOLOGY_EFFECT_REORDER_WINDOW))
        #expect(output.result.source_column_became_empty == 0)
        #expect(output.result.target_window_index == 2)
        #expect(output.windows.map(\.id) == [20, 30, 10])
    }

    @Test func insertWindowByMoveRemovesEmptySourceColumn() {
        var input = makeNiriTopologyInput(
            operation: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_INSERT_WINDOW_BY_MOVE),
            subjectWindowId: 10,
            targetWindowId: 30,
            selectedWindowId: 10,
            insertIndex: Int32(OMNIWM_NIRI_TOPOLOGY_INSERT_BEFORE)
        )
        let columns = [
            makeNiriTopologyColumn(id: 1, span: 400, windowStartIndex: 0, windowCount: 1),
            makeNiriTopologyColumn(id: 2, span: 400, windowStartIndex: 1, windowCount: 2)
        ]
        let windows = [10, 20, 30].map { makeNiriTopologyWindow(id: UInt64($0)) }

        let output = callNiriTopology(input: &input, columns: columns, windows: windows)

        #expect(output.status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.result.column_count == 1)
        #expect(output.result.source_column_became_empty == 1)
        #expect(output.result.target_column_index == 0)
        #expect(output.result.target_window_index == 1)
        #expect(output.windows.map(\.id) == [20, 10, 30])
    }

    @Test func insertWindowByMovePreservesTabbedSourceActiveIndex() {
        var input = makeNiriTopologyInput(
            operation: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_INSERT_WINDOW_BY_MOVE),
            subjectWindowId: 10,
            targetWindowId: 40,
            selectedWindowId: 10,
            insertIndex: Int32(OMNIWM_NIRI_TOPOLOGY_INSERT_BEFORE)
        )
        let columns = [
            makeNiriTopologyColumn(
                id: 1,
                span: 400,
                windowStartIndex: 0,
                windowCount: 3,
                activeWindowIndex: 1,
                isTabbed: true
            ),
            makeNiriTopologyColumn(id: 2, span: 400, windowStartIndex: 3, windowCount: 1)
        ]
        let windows = [10, 20, 30, 40].map { makeNiriTopologyWindow(id: UInt64($0)) }

        let output = callNiriTopology(input: &input, columns: columns, windows: windows)

        #expect(output.status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.columns.map(\.active_window_index) == [1, 0])
        #expect(output.windows.map(\.id) == [20, 30, 10, 40])
    }

    @Test func focusAtEdgePreservesSelectedTarget() {
        var input = makeNiriTopologyInput(
            operation: UInt32(OMNIWM_NIRI_TOPOLOGY_OP_FOCUS),
            direction: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_LEFT),
            subjectWindowId: 0,
            selectedWindowId: 10,
            activeColumnIndex: 0
        )
        let columns = [
            makeNiriTopologyColumn(id: 1, span: 400, windowStartIndex: 0, windowCount: 1)
        ]
        let windows = [makeNiriTopologyWindow(id: 10)]

        let output = callNiriTopology(input: &input, columns: columns, windows: windows)

        #expect(output.status == OMNIWM_KERNELS_STATUS_OK)
        #expect(output.result.selected_window_id == 10)
        #expect(output.result.active_column_index == 0)
        #expect(output.result.did_apply == 0)
        #expect(output.windows.map(\.id) == [10])
    }
}
