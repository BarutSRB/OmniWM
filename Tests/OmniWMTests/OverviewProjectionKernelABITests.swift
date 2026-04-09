import COmniWMKernels
import Foundation
import Testing

private func makeOverviewKernelContext(
    screenFrame: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 900),
    scale: CGFloat = 1.0,
    totalContentHeightOverride: CGFloat? = nil
) -> omniwm_overview_context {
    let metricsScale = max(0.5, min(1.5, scale))
    let scaledWindowPadding = 24 * metricsScale
    let scaledSearchBarHeight = 44 * metricsScale
    let scaledSearchBarPadding = 20 * metricsScale
    let searchBarY = screenFrame.maxY - scaledSearchBarHeight - scaledSearchBarPadding

    return omniwm_overview_context(
        screen_x: screenFrame.minX,
        screen_y: screenFrame.minY,
        screen_width: screenFrame.width,
        screen_height: screenFrame.height,
        metrics_scale: metricsScale,
        available_width: screenFrame.width - (scaledWindowPadding * 2),
        scaled_window_padding: scaledWindowPadding,
        scaled_workspace_label_height: 32 * metricsScale,
        scaled_workspace_section_padding: 16 * metricsScale,
        scaled_window_spacing: 16 * metricsScale,
        thumbnail_width: min(400 * metricsScale, max(200 * metricsScale, (screenFrame.width - (scaledWindowPadding * 2)) / 4)),
        initial_content_y: searchBarY - 20 * metricsScale,
        content_bottom_padding: 40 * metricsScale,
        total_content_height_override: totalContentHeightOverride ?? 0,
        has_total_content_height_override: totalContentHeightOverride == nil ? 0 : 1
    )
}

private func zeroOverviewSectionOutput() -> omniwm_overview_section_output {
    omniwm_overview_section_output(
        workspace_index: 0,
        section_x: 0,
        section_y: 0,
        section_width: 0,
        section_height: 0,
        label_x: 0,
        label_y: 0,
        label_width: 0,
        label_height: 0,
        grid_x: 0,
        grid_y: 0,
        grid_width: 0,
        grid_height: 0,
        generic_window_output_start_index: 0,
        generic_window_output_count: 0,
        niri_column_output_start_index: 0,
        niri_column_output_count: 0,
        niri_tile_output_start_index: 0,
        niri_tile_output_count: 0,
        drop_zone_output_start_index: 0,
        drop_zone_output_count: 0
    )
}

private func zeroOverviewGenericWindowOutput() -> omniwm_overview_generic_window_output {
    omniwm_overview_generic_window_output(
        input_index: 0,
        frame_x: 0,
        frame_y: 0,
        frame_width: 0,
        frame_height: 0
    )
}

private func sentinelOverviewGenericWindowOutput() -> omniwm_overview_generic_window_output {
    omniwm_overview_generic_window_output(
        input_index: 999,
        frame_x: 999,
        frame_y: 999,
        frame_width: 999,
        frame_height: 999
    )
}

private func zeroOverviewNiriColumnOutput() -> omniwm_overview_niri_column_output {
    omniwm_overview_niri_column_output(
        input_index: 0,
        column_index: 0,
        frame_x: 0,
        frame_y: 0,
        frame_width: 0,
        frame_height: 0,
        tile_output_start_index: 0,
        tile_output_count: 0
    )
}

private func zeroOverviewNiriTileOutput() -> omniwm_overview_niri_tile_output {
    omniwm_overview_niri_tile_output(
        input_index: 0,
        frame_x: 0,
        frame_y: 0,
        frame_width: 0,
        frame_height: 0
    )
}

private func zeroOverviewDropZoneOutput() -> omniwm_overview_drop_zone_output {
    omniwm_overview_drop_zone_output(
        workspace_index: 0,
        insert_index: 0,
        frame_x: 0,
        frame_y: 0,
        frame_width: 0,
        frame_height: 0
    )
}

private func zeroOverviewResult() -> omniwm_overview_result {
    omniwm_overview_result(
        total_content_height: 0,
        min_scroll_offset: 0,
        max_scroll_offset: 0,
        section_count: 0,
        generic_window_output_count: 0,
        niri_column_output_count: 0,
        niri_tile_output_count: 0,
        drop_zone_output_count: 0
    )
}

@Suite struct OverviewProjectionKernelABITests {
    @Test func emptySolveSupportsScrollSummaryOnly() {
        var context = makeOverviewKernelContext(totalContentHeightOverride: 1300)
        var result = zeroOverviewResult()

        let status = omniwm_overview_projection_solve(
            &context,
            nil,
            0,
            nil,
            0,
            nil,
            0,
            nil,
            0,
            nil,
            0,
            nil,
            0,
            nil,
            0,
            nil,
            0,
            nil,
            0,
            &result
        )

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
        #expect(result.section_count == 0)
        #expect(result.total_content_height == 1300)
        #expect(result.min_scroll_offset == -484)
        #expect(result.max_scroll_offset == 0)
    }

    @Test func singleGenericWindowUsesOnlyRequestedOutputSlots() {
        var context = makeOverviewKernelContext()
        let workspaces = [
            omniwm_overview_workspace_input(
                generic_window_start_index: 0,
                generic_window_count: 1,
                niri_column_start_index: 0,
                niri_column_count: 0
            )
        ]
        let windows = [
            omniwm_overview_generic_window_input(
                workspace_index: 0,
                source_x: 220,
                source_y: 140,
                source_width: 960,
                source_height: 640,
                title_sort_rank: 0
            )
        ]
        var sections = [zeroOverviewSectionOutput()]
        var windowOutputs = [zeroOverviewGenericWindowOutput(), sentinelOverviewGenericWindowOutput()]
        var result = zeroOverviewResult()

        let status = workspaces.withUnsafeBufferPointer { workspaceBuffer in
            windows.withUnsafeBufferPointer { windowBuffer in
                sections.withUnsafeMutableBufferPointer { sectionBuffer in
                    windowOutputs.withUnsafeMutableBufferPointer { windowOutputBuffer in
                        omniwm_overview_projection_solve(
                            &context,
                            workspaceBuffer.baseAddress,
                            workspaceBuffer.count,
                            windowBuffer.baseAddress,
                            windowBuffer.count,
                            nil,
                            0,
                            nil,
                            0,
                            sectionBuffer.baseAddress,
                            sectionBuffer.count,
                            windowOutputBuffer.baseAddress,
                            windowOutputBuffer.count,
                            nil,
                            0,
                            nil,
                            0,
                            nil,
                            0,
                            &result
                        )
                    }
                }
            }
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
        #expect(result.section_count == 1)
        #expect(result.generic_window_output_count == 1)
        #expect(windowOutputs[0].input_index == 0)
        #expect(windowOutputs[0].frame_width > 0)
        #expect(windowOutputs[0].frame_height > 0)
        #expect(windowOutputs[1].input_index == 999)
        #expect(windowOutputs[1].frame_x == 999)
    }

    @Test func niriSolvePreservesStableColumnTileAndDropZoneIndices() {
        var context = makeOverviewKernelContext()
        let workspaces = [
            omniwm_overview_workspace_input(
                generic_window_start_index: 0,
                generic_window_count: 0,
                niri_column_start_index: 0,
                niri_column_count: 2
            )
        ]
        let columns = [
            omniwm_overview_niri_column_input(
                workspace_index: 0,
                column_index: 0,
                width_weight: 1,
                preferred_width: 0,
                tile_start_index: 0,
                tile_count: 1,
                has_preferred_width: 0
            ),
            omniwm_overview_niri_column_input(
                workspace_index: 0,
                column_index: 1,
                width_weight: 1,
                preferred_width: 0,
                tile_start_index: 1,
                tile_count: 1,
                has_preferred_width: 0
            )
        ]
        let tiles = [
            omniwm_overview_niri_tile_input(preferred_height: 420),
            omniwm_overview_niri_tile_input(preferred_height: 240)
        ]
        var sections = [zeroOverviewSectionOutput()]
        var columnOutputs = [zeroOverviewNiriColumnOutput(), zeroOverviewNiriColumnOutput()]
        var tileOutputs = [zeroOverviewNiriTileOutput(), zeroOverviewNiriTileOutput()]
        var dropZoneOutputs = [zeroOverviewDropZoneOutput(), zeroOverviewDropZoneOutput(), zeroOverviewDropZoneOutput()]
        var result = zeroOverviewResult()

        let status = workspaces.withUnsafeBufferPointer { workspaceBuffer in
            columns.withUnsafeBufferPointer { columnBuffer in
                tiles.withUnsafeBufferPointer { tileBuffer in
                    sections.withUnsafeMutableBufferPointer { sectionBuffer in
                        columnOutputs.withUnsafeMutableBufferPointer { columnOutputBuffer in
                            tileOutputs.withUnsafeMutableBufferPointer { tileOutputBuffer in
                                dropZoneOutputs.withUnsafeMutableBufferPointer { dropZoneBuffer in
                                    omniwm_overview_projection_solve(
                                        &context,
                                        workspaceBuffer.baseAddress,
                                        workspaceBuffer.count,
                                        nil,
                                        0,
                                        columnBuffer.baseAddress,
                                        columnBuffer.count,
                                        tileBuffer.baseAddress,
                                        tileBuffer.count,
                                        sectionBuffer.baseAddress,
                                        sectionBuffer.count,
                                        nil,
                                        0,
                                        columnOutputBuffer.baseAddress,
                                        columnOutputBuffer.count,
                                        tileOutputBuffer.baseAddress,
                                        tileOutputBuffer.count,
                                        dropZoneBuffer.baseAddress,
                                        dropZoneBuffer.count,
                                        &result
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }

        #expect(status == OMNIWM_KERNELS_STATUS_OK)
        #expect(result.niri_column_output_count == 2)
        #expect(result.niri_tile_output_count == 2)
        #expect(result.drop_zone_output_count == 3)
        #expect(columnOutputs.map(\.input_index) == [0, 1])
        #expect(tileOutputs.map(\.input_index) == [0, 1])
        #expect(dropZoneOutputs.map(\.insert_index) == [0, 1, 2])
    }

    @Test func insufficientOutputCapacityReturnsInvalidArgument() {
        var context = makeOverviewKernelContext()
        let workspaces = [
            omniwm_overview_workspace_input(
                generic_window_start_index: 0,
                generic_window_count: 1,
                niri_column_start_index: 0,
                niri_column_count: 0
            )
        ]
        let windows = [
            omniwm_overview_generic_window_input(
                workspace_index: 0,
                source_x: 220,
                source_y: 140,
                source_width: 960,
                source_height: 640,
                title_sort_rank: 0
            )
        ]
        var result = zeroOverviewResult()

        let status = workspaces.withUnsafeBufferPointer { workspaceBuffer in
            windows.withUnsafeBufferPointer { windowBuffer in
                omniwm_overview_projection_solve(
                    &context,
                    workspaceBuffer.baseAddress,
                    workspaceBuffer.count,
                    windowBuffer.baseAddress,
                    windowBuffer.count,
                    nil,
                    0,
                    nil,
                    0,
                    nil,
                    0,
                    nil,
                    0,
                    nil,
                    0,
                    nil,
                    0,
                    nil,
                    0,
                    &result
                )
            }
        }

        #expect(status == OMNIWM_KERNELS_STATUS_INVALID_ARGUMENT)
    }
}
