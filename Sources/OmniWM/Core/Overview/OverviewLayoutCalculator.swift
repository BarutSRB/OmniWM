// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import COmniWMKernels
import Foundation

typealias OverviewWorkspaceLayoutItem = (
    id: WorkspaceDescriptor.ID,
    name: String,
    isActive: Bool
)

typealias OverviewWindowLayoutData = (
    entry: WindowModel.Entry,
    title: String,
    appName: String,
    appIcon: NSImage?,
    frame: CGRect
)

enum OverviewLayoutMetrics {
    static let searchBarHeight: CGFloat = 44
    static let searchBarPadding: CGFloat = 20
    static let workspaceLabelHeight: CGFloat = 32
    static let workspaceSectionPadding: CGFloat = 16
    static let windowSpacing: CGFloat = 16
    static let windowPadding: CGFloat = 24
    static let minThumbnailWidth: CGFloat = 200
    static let maxThumbnailWidth: CGFloat = 400
    static let thumbnailAspectRatio: CGFloat = 16.0 / 10.0
    static let closeButtonSize: CGFloat = 20
    static let closeButtonPadding: CGFloat = 6
    static let contentTopPadding: CGFloat = 20
    static let contentBottomPadding: CGFloat = 40
}

@MainActor
struct OverviewLayoutCalculator {
    struct BuildContext {
        let screenFrame: CGRect
        let metricsScale: CGFloat
        let availableWidth: CGFloat
        let searchBarFrame: CGRect
        let scaledWindowPadding: CGFloat
        let scaledWorkspaceLabelHeight: CGFloat
        let scaledWorkspaceSectionPadding: CGFloat
        let scaledWindowSpacing: CGFloat
        let thumbnailWidth: CGFloat
        let initialContentY: CGFloat
        let contentBottomPadding: CGFloat
    }

    private struct ProjectionSnapshot {
        struct WorkspaceRecord {
            let workspace: OverviewWorkspaceLayoutItem
            let genericWindowRange: Range<Int>
            let niriColumnRange: Range<Int>
        }

        struct GenericWindowRecord {
            let workspaceIndex: Int
            let handle: WindowHandle
            let windowData: OverviewWindowLayoutData
            let titleSortRank: UInt32
        }

        struct NiriTileRecord {
            let handle: WindowHandle
            let windowData: OverviewWindowLayoutData
            let preferredHeight: CGFloat
        }

        struct NiriColumnRecord {
            let workspaceIndex: Int
            let columnIndex: Int
            let widthWeight: CGFloat
            let preferredWidth: CGFloat?
            let tileRange: Range<Int>
        }

        let workspaces: [WorkspaceRecord]
        let genericWindows: [GenericWindowRecord]
        let niriColumns: [NiriColumnRecord]
        let niriTiles: [NiriTileRecord]
    }

    private struct KernelProjection {
        let sectionOutputs: [omniwm_overview_section_output]
        let genericWindowOutputs: [omniwm_overview_generic_window_output]
        let niriColumnOutputs: [omniwm_overview_niri_column_output]
        let niriTileOutputs: [omniwm_overview_niri_tile_output]
        let dropZoneOutputs: [omniwm_overview_drop_zone_output]
        let result: omniwm_overview_result
    }

    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        max(0.5, min(1.5, scale))
    }

    static func viewportFrame(for monitorFrame: CGRect) -> CGRect {
        CGRect(origin: .zero, size: monitorFrame.size)
    }

    static func localizedFrame(_ frame: CGRect, to monitorFrame: CGRect) -> CGRect {
        frame.offsetBy(dx: -monitorFrame.minX, dy: -monitorFrame.minY)
    }

    static func calculateLayout(
        workspaces: [OverviewWorkspaceLayoutItem],
        windows: [WindowHandle: OverviewWindowLayoutData],
        screenFrame: CGRect,
        searchQuery: String,
        scale: CGFloat
    ) -> OverviewLayout {
        calculateLayout(
            workspaces: workspaces,
            windows: windows,
            niriSnapshotsByWorkspace: [:],
            screenFrame: screenFrame,
            searchQuery: searchQuery,
            scale: scale
        )
    }

    static func calculateLayout(
        workspaces: [OverviewWorkspaceLayoutItem],
        windows: [WindowHandle: OverviewWindowLayoutData],
        niriSnapshotsByWorkspace: [WorkspaceDescriptor.ID: NiriOverviewWorkspaceSnapshot],
        screenFrame: CGRect,
        searchQuery: String,
        scale: CGFloat
    ) -> OverviewLayout {
        let context = buildContext(screenFrame: screenFrame, scale: scale)
        let snapshot = buildProjectionSnapshot(
            workspaces: workspaces,
            windows: windows,
            niriSnapshotsByWorkspace: niriSnapshotsByWorkspace
        )
        let projection = solveProjection(snapshot: snapshot, context: context)
        return applyProjection(
            projection,
            snapshot: snapshot,
            searchQuery: searchQuery,
            scale: scale,
            context: context
        )
    }

    private static func buildContext(screenFrame: CGRect, scale: CGFloat) -> BuildContext {
        let metricsScale = clampedScale(scale)
        let scaledSearchBarHeight = OverviewLayoutMetrics.searchBarHeight * metricsScale
        let scaledSearchBarPadding = OverviewLayoutMetrics.searchBarPadding * metricsScale
        let searchBarY = screenFrame.maxY - scaledSearchBarHeight - scaledSearchBarPadding
        let searchBarFrame = CGRect(
            x: screenFrame.minX + screenFrame.width * 0.25,
            y: searchBarY,
            width: screenFrame.width * 0.5,
            height: scaledSearchBarHeight
        )

        let scaledWindowPadding = OverviewLayoutMetrics.windowPadding * metricsScale
        let availableWidth = screenFrame.width - (scaledWindowPadding * 2)
        let thumbnailWidth = min(
            OverviewLayoutMetrics.maxThumbnailWidth * metricsScale,
            max(OverviewLayoutMetrics.minThumbnailWidth * metricsScale, availableWidth / 4)
        )

        return BuildContext(
            screenFrame: screenFrame,
            metricsScale: metricsScale,
            availableWidth: availableWidth,
            searchBarFrame: searchBarFrame,
            scaledWindowPadding: scaledWindowPadding,
            scaledWorkspaceLabelHeight: OverviewLayoutMetrics.workspaceLabelHeight * metricsScale,
            scaledWorkspaceSectionPadding: OverviewLayoutMetrics.workspaceSectionPadding * metricsScale,
            scaledWindowSpacing: OverviewLayoutMetrics.windowSpacing * metricsScale,
            thumbnailWidth: thumbnailWidth,
            initialContentY: searchBarY - OverviewLayoutMetrics.contentTopPadding * metricsScale,
            contentBottomPadding: OverviewLayoutMetrics.contentBottomPadding * metricsScale
        )
    }

    private static func buildProjectionSnapshot(
        workspaces: [OverviewWorkspaceLayoutItem],
        windows: [WindowHandle: OverviewWindowLayoutData],
        niriSnapshotsByWorkspace: [WorkspaceDescriptor.ID: NiriOverviewWorkspaceSnapshot]
    ) -> ProjectionSnapshot {
        var windowsByWorkspace: [WorkspaceDescriptor.ID: [(WindowHandle, OverviewWindowLayoutData)]] = [:]
        windowsByWorkspace.reserveCapacity(workspaces.count)

        var windowsByToken: [WindowToken: (WindowHandle, OverviewWindowLayoutData)] = [:]
        windowsByToken.reserveCapacity(windows.count)

        for (handle, windowData) in windows {
            windowsByWorkspace[windowData.entry.workspaceId, default: []].append((handle, windowData))
            windowsByToken[windowData.entry.token] = (handle, windowData)
        }

        var workspaceRecords: [ProjectionSnapshot.WorkspaceRecord] = []
        workspaceRecords.reserveCapacity(workspaces.count)

        var genericWindows: [ProjectionSnapshot.GenericWindowRecord] = []
        genericWindows.reserveCapacity(windows.count)

        var niriColumns: [ProjectionSnapshot.NiriColumnRecord] = []
        var niriTiles: [ProjectionSnapshot.NiriTileRecord] = []

        for (workspaceIndex, workspace) in workspaces.enumerated() {
            let genericStart = genericWindows.count
            let niriColumnStart = niriColumns.count

            if let workspaceWindows = windowsByWorkspace[workspace.id], !workspaceWindows.isEmpty {
                if let snapshot = niriSnapshotsByWorkspace[workspace.id], !snapshot.columns.isEmpty {
                    for columnSnapshot in snapshot.columns {
                        let tileStart = niriTiles.count
                        for tile in columnSnapshot.tiles {
                            guard let (handle, windowData) = windowsByToken[tile.token] else {
                                continue
                            }
                            niriTiles.append(
                                ProjectionSnapshot.NiriTileRecord(
                                    handle: handle,
                                    windowData: windowData,
                                    preferredHeight: tile.preferredHeight
                                )
                            )
                        }

                        niriColumns.append(
                            ProjectionSnapshot.NiriColumnRecord(
                                workspaceIndex: workspaceIndex,
                                columnIndex: columnSnapshot.index,
                                widthWeight: columnSnapshot.widthWeight,
                                preferredWidth: columnSnapshot.preferredWidth,
                                tileRange: tileStart ..< niriTiles.count
                            )
                        )
                    }
                } else {
                    let orderedInputs = workspaceWindows.sorted { lhs, rhs in
                        if lhs.1.entry.windowId != rhs.1.entry.windowId {
                            return lhs.1.entry.windowId < rhs.1.entry.windowId
                        }
                        if lhs.1.entry.token.pid != rhs.1.entry.token.pid {
                            return lhs.1.entry.token.pid < rhs.1.entry.token.pid
                        }
                        return lhs.1.title < rhs.1.title
                    }
                    let titleSortRanks = previewTitleSortRanks(for: orderedInputs)

                    for (handle, windowData) in orderedInputs {
                        genericWindows.append(
                            ProjectionSnapshot.GenericWindowRecord(
                                workspaceIndex: workspaceIndex,
                                handle: handle,
                                windowData: windowData,
                                titleSortRank: titleSortRanks[ObjectIdentifier(handle)] ?? 0
                            )
                        )
                    }
                }
            }

            workspaceRecords.append(
                ProjectionSnapshot.WorkspaceRecord(
                    workspace: workspace,
                    genericWindowRange: genericStart ..< genericWindows.count,
                    niriColumnRange: niriColumnStart ..< niriColumns.count
                )
            )
        }

        return ProjectionSnapshot(
            workspaces: workspaceRecords,
            genericWindows: genericWindows,
            niriColumns: niriColumns,
            niriTiles: niriTiles
        )
    }

    private static func previewTitleSortRanks(
        for windows: [(WindowHandle, OverviewWindowLayoutData)]
    ) -> [ObjectIdentifier: UInt32] {
        let sorted = windows.sorted { lhs, rhs in
            if lhs.1.title != rhs.1.title {
                return lhs.1.title < rhs.1.title
            }
            if lhs.1.entry.windowId != rhs.1.entry.windowId {
                return lhs.1.entry.windowId < rhs.1.entry.windowId
            }
            return lhs.1.entry.token.pid < rhs.1.entry.token.pid
        }

        var ranks: [ObjectIdentifier: UInt32] = [:]
        ranks.reserveCapacity(sorted.count)

        for (index, item) in sorted.enumerated() {
            ranks[ObjectIdentifier(item.0)] = numericCast(index)
        }
        return ranks
    }

    private static func solveProjection(
        snapshot: ProjectionSnapshot,
        context: BuildContext
    ) -> KernelProjection {
        var rawContext = omniwm_overview_context(context: context)

        var workspaceInputs = ContiguousArray<omniwm_overview_workspace_input>()
        workspaceInputs.reserveCapacity(snapshot.workspaces.count)
        for workspace in snapshot.workspaces {
            workspaceInputs.append(
                omniwm_overview_workspace_input(
                    generic_window_start_index: numericCast(workspace.genericWindowRange.lowerBound),
                    generic_window_count: numericCast(workspace.genericWindowRange.count),
                    niri_column_start_index: numericCast(workspace.niriColumnRange.lowerBound),
                    niri_column_count: numericCast(workspace.niriColumnRange.count)
                )
            )
        }

        var genericWindowInputs = ContiguousArray<omniwm_overview_generic_window_input>()
        genericWindowInputs.reserveCapacity(snapshot.genericWindows.count)
        for window in snapshot.genericWindows {
            let frame = window.windowData.frame
            genericWindowInputs.append(
                omniwm_overview_generic_window_input(
                    workspace_index: numericCast(window.workspaceIndex),
                    source_x: frame.minX,
                    source_y: frame.minY,
                    source_width: frame.width,
                    source_height: frame.height,
                    title_sort_rank: window.titleSortRank
                )
            )
        }

        var niriColumnInputs = ContiguousArray<omniwm_overview_niri_column_input>()
        niriColumnInputs.reserveCapacity(snapshot.niriColumns.count)
        for column in snapshot.niriColumns {
            niriColumnInputs.append(
                omniwm_overview_niri_column_input(
                    workspace_index: numericCast(column.workspaceIndex),
                    column_index: numericCast(column.columnIndex),
                    width_weight: column.widthWeight,
                    preferred_width: column.preferredWidth ?? 0,
                    tile_start_index: numericCast(column.tileRange.lowerBound),
                    tile_count: numericCast(column.tileRange.count),
                    has_preferred_width: (column.preferredWidth ?? 0) > 0 ? 1 : 0
                )
            )
        }

        var niriTileInputs = ContiguousArray<omniwm_overview_niri_tile_input>()
        niriTileInputs.reserveCapacity(snapshot.niriTiles.count)
        for tile in snapshot.niriTiles {
            niriTileInputs.append(
                omniwm_overview_niri_tile_input(preferred_height: tile.preferredHeight)
            )
        }

        let dropZoneCapacity = snapshot.workspaces.reduce(into: 0) { count, workspace in
            if !workspace.niriColumnRange.isEmpty {
                count += workspace.niriColumnRange.count + 1
            }
        }

        var sectionOutputs = ContiguousArray(
            repeating: zeroSectionOutput(),
            count: snapshot.workspaces.count
        )
        var genericWindowOutputs = ContiguousArray(
            repeating: zeroGenericWindowOutput(),
            count: snapshot.genericWindows.count
        )
        var niriColumnOutputs = ContiguousArray(
            repeating: zeroNiriColumnOutput(),
            count: snapshot.niriColumns.count
        )
        var niriTileOutputs = ContiguousArray(
            repeating: zeroNiriTileOutput(),
            count: snapshot.niriTiles.count
        )
        var dropZoneOutputs = ContiguousArray(
            repeating: zeroDropZoneOutput(),
            count: dropZoneCapacity
        )
        var result = zeroOverviewResult()

        let status = workspaceInputs.withUnsafeBufferPointer { workspaceBuffer in
            genericWindowInputs.withUnsafeBufferPointer { genericWindowBuffer in
                niriColumnInputs.withUnsafeBufferPointer { niriColumnBuffer in
                    niriTileInputs.withUnsafeBufferPointer { niriTileBuffer in
                        sectionOutputs.withUnsafeMutableBufferPointer { sectionOutputBuffer in
                            genericWindowOutputs.withUnsafeMutableBufferPointer { genericWindowOutputBuffer in
                                niriColumnOutputs.withUnsafeMutableBufferPointer { niriColumnOutputBuffer in
                                    niriTileOutputs.withUnsafeMutableBufferPointer { niriTileOutputBuffer in
                                        dropZoneOutputs.withUnsafeMutableBufferPointer { dropZoneOutputBuffer in
                                            omniwm_overview_projection_solve(
                                                &rawContext,
                                                workspaceBuffer.baseAddress,
                                                workspaceBuffer.count,
                                                genericWindowBuffer.baseAddress,
                                                genericWindowBuffer.count,
                                                niriColumnBuffer.baseAddress,
                                                niriColumnBuffer.count,
                                                niriTileBuffer.baseAddress,
                                                niriTileBuffer.count,
                                                sectionOutputBuffer.baseAddress,
                                                sectionOutputBuffer.count,
                                                genericWindowOutputBuffer.baseAddress,
                                                genericWindowOutputBuffer.count,
                                                niriColumnOutputBuffer.baseAddress,
                                                niriColumnOutputBuffer.count,
                                                niriTileOutputBuffer.baseAddress,
                                                niriTileOutputBuffer.count,
                                                dropZoneOutputBuffer.baseAddress,
                                                dropZoneOutputBuffer.count,
                                                &result
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        precondition(
            status == OMNIWM_KERNELS_STATUS_OK,
            "omniwm_overview_projection_solve returned \(status)"
        )

        return KernelProjection(
            sectionOutputs: Array(sectionOutputs.prefix(result.section_count)),
            genericWindowOutputs: Array(genericWindowOutputs.prefix(result.generic_window_output_count)),
            niriColumnOutputs: Array(niriColumnOutputs.prefix(result.niri_column_output_count)),
            niriTileOutputs: Array(niriTileOutputs.prefix(result.niri_tile_output_count)),
            dropZoneOutputs: Array(dropZoneOutputs.prefix(result.drop_zone_output_count)),
            result: result
        )
    }

    private static func applyProjection(
        _ projection: KernelProjection,
        snapshot: ProjectionSnapshot,
        searchQuery: String,
        scale: CGFloat,
        context: BuildContext
    ) -> OverviewLayout {
        var layout = OverviewLayout()
        layout.scale = scale
        layout.searchBarFrame = context.searchBarFrame
        layout.totalContentHeight = projection.result.total_content_height
        layout.resolvedScrollOffsetBounds = projection.result.scrollOffsetBounds

        var sections: [OverviewWorkspaceSection] = []
        sections.reserveCapacity(projection.sectionOutputs.count)

        var niriColumnsByWorkspace: [WorkspaceDescriptor.ID: [OverviewNiriColumn]] = [:]
        var niriColumnDropZonesByWorkspace: [WorkspaceDescriptor.ID: [OverviewColumnDropZone]] = [:]

        for sectionOutput in projection.sectionOutputs {
            let workspaceRecord = snapshot.workspaces[Int(sectionOutput.workspace_index)]
            let workspaceId = workspaceRecord.workspace.id

            var windows: [OverviewWindowItem] = []
            if sectionOutput.generic_window_output_count > 0 {
                windows.reserveCapacity(Int(sectionOutput.generic_window_output_count))
                for output in projection.genericWindowOutputs[
                    Int(sectionOutput.generic_window_output_start_index)
                        ..< Int(sectionOutput.generic_window_output_start_index + sectionOutput.generic_window_output_count)
                ] {
                    let input = snapshot.genericWindows[Int(output.input_index)]
                    windows.append(
                        makeWindowItem(
                            handle: input.handle,
                            workspaceId: workspaceId,
                            windowData: input.windowData,
                            overviewFrame: output.frame,
                            searchQuery: searchQuery
                        )
                    )
                }
            } else if sectionOutput.niri_tile_output_count > 0 {
                windows.reserveCapacity(Int(sectionOutput.niri_tile_output_count))
                for output in projection.niriTileOutputs[
                    Int(sectionOutput.niri_tile_output_start_index)
                        ..< Int(sectionOutput.niri_tile_output_start_index + sectionOutput.niri_tile_output_count)
                ] {
                    let input = snapshot.niriTiles[Int(output.input_index)]
                    windows.append(
                        makeWindowItem(
                            handle: input.handle,
                            workspaceId: workspaceId,
                            windowData: input.windowData,
                            overviewFrame: output.frame,
                            searchQuery: searchQuery
                        )
                    )
                }
            }

            sections.append(
                OverviewWorkspaceSection(
                    workspaceId: workspaceId,
                    name: workspaceRecord.workspace.name,
                    windows: windows,
                    sectionFrame: sectionOutput.sectionFrame,
                    labelFrame: sectionOutput.labelFrame,
                    gridFrame: sectionOutput.gridFrame,
                    isActive: workspaceRecord.workspace.isActive
                )
            )

            if sectionOutput.niri_column_output_count > 0 {
                var projectedColumns: [OverviewNiriColumn] = []
                projectedColumns.reserveCapacity(Int(sectionOutput.niri_column_output_count))

                for output in projection.niriColumnOutputs[
                    Int(sectionOutput.niri_column_output_start_index)
                        ..< Int(sectionOutput.niri_column_output_start_index + sectionOutput.niri_column_output_count)
                ] {
                    let windowHandles = projection.niriTileOutputs[
                        Int(output.tile_output_start_index)
                            ..< Int(output.tile_output_start_index + output.tile_output_count)
                    ].map { snapshot.niriTiles[Int($0.input_index)].handle }

                    projectedColumns.append(
                        OverviewNiriColumn(
                            workspaceId: workspaceId,
                            columnIndex: Int(output.column_index),
                            frame: output.frame,
                            windowHandles: windowHandles
                        )
                    )
                }

                niriColumnsByWorkspace[workspaceId] = projectedColumns
            }

            if sectionOutput.drop_zone_output_count > 0 {
                niriColumnDropZonesByWorkspace[workspaceId] = projection.dropZoneOutputs[
                    Int(sectionOutput.drop_zone_output_start_index)
                        ..< Int(sectionOutput.drop_zone_output_start_index + sectionOutput.drop_zone_output_count)
                ].map { output in
                    OverviewColumnDropZone(
                        workspaceId: workspaceId,
                        insertIndex: Int(output.insert_index),
                        frame: output.frame
                    )
                }
            }
        }

        layout.workspaceSections = sections
        layout.niriColumnsByWorkspace = niriColumnsByWorkspace
        layout.niriColumnDropZonesByWorkspace = niriColumnDropZonesByWorkspace
        return layout
    }

    private static func zeroSectionOutput() -> omniwm_overview_section_output {
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

    private static func zeroGenericWindowOutput() -> omniwm_overview_generic_window_output {
        omniwm_overview_generic_window_output(
            input_index: 0,
            frame_x: 0,
            frame_y: 0,
            frame_width: 0,
            frame_height: 0
        )
    }

    private static func zeroNiriTileOutput() -> omniwm_overview_niri_tile_output {
        omniwm_overview_niri_tile_output(
            input_index: 0,
            frame_x: 0,
            frame_y: 0,
            frame_width: 0,
            frame_height: 0
        )
    }

    private static func zeroNiriColumnOutput() -> omniwm_overview_niri_column_output {
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

    private static func zeroDropZoneOutput() -> omniwm_overview_drop_zone_output {
        omniwm_overview_drop_zone_output(
            workspace_index: 0,
            insert_index: 0,
            frame_x: 0,
            frame_y: 0,
            frame_width: 0,
            frame_height: 0
        )
    }

    private static func zeroOverviewResult() -> omniwm_overview_result {
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

    private static func makeWindowItem(
        handle: WindowHandle,
        workspaceId: WorkspaceDescriptor.ID,
        windowData: OverviewWindowLayoutData,
        overviewFrame: CGRect,
        searchQuery: String
    ) -> OverviewWindowItem {
        let matchesSearch = searchQuery.isEmpty ||
            windowData.title.localizedCaseInsensitiveContains(searchQuery) ||
            windowData.appName.localizedCaseInsensitiveContains(searchQuery)

        return OverviewWindowItem(
            handle: handle,
            windowId: windowData.entry.windowId,
            workspaceId: workspaceId,
            thumbnail: nil,
            title: windowData.title,
            appName: windowData.appName,
            appIcon: windowData.appIcon,
            originalFrame: windowData.frame,
            overviewFrame: overviewFrame,
            isHovered: false,
            isSelected: false,
            matchesSearch: matchesSearch,
            closeButtonHovered: false
        )
    }

    static func updateSearchFilter(layout: inout OverviewLayout, searchQuery: String) {
        for sectionIndex in layout.workspaceSections.indices {
            for windowIndex in layout.workspaceSections[sectionIndex].windows.indices {
                let window = layout.workspaceSections[sectionIndex].windows[windowIndex]
                let matches = searchQuery.isEmpty ||
                    window.title.localizedCaseInsensitiveContains(searchQuery) ||
                    window.appName.localizedCaseInsensitiveContains(searchQuery)
                layout.workspaceSections[sectionIndex].windows[windowIndex].matchesSearch = matches
            }
        }
    }

    static func scrollOffsetBounds(layout: OverviewLayout, screenFrame: CGRect) -> ClosedRange<CGFloat> {
        _ = screenFrame
        return KernelContract.require(
            layout.resolvedScrollOffsetBounds,
            "Overview layout missing kernel scroll bounds"
        )
    }

    static func clampedScrollOffset(
        _ scrollOffset: CGFloat,
        layout: OverviewLayout,
        screenFrame: CGRect
    ) -> CGFloat {
        scrollOffset.clamped(to: scrollOffsetBounds(layout: layout, screenFrame: screenFrame))
    }

    static func findNextWindow(
        in layout: OverviewLayout,
        from currentHandle: WindowHandle?,
        direction: Direction
    ) -> WindowHandle? {
        let visibleWindows = layout.allWindows.filter(\.matchesSearch)
        guard !visibleWindows.isEmpty else { return nil }

        guard let currentHandle else {
            return visibleWindows.first?.handle
        }

        guard let currentIndex = visibleWindows.firstIndex(where: { $0.handle == currentHandle }) else {
            return visibleWindows.first?.handle
        }

        let currentWindow = visibleWindows[currentIndex]

        switch direction {
        case .left:
            let leftWindows = visibleWindows.filter {
                $0.overviewFrame.midX < currentWindow.overviewFrame.midX &&
                abs($0.overviewFrame.midY - currentWindow.overviewFrame.midY) < currentWindow.overviewFrame.height
            }.sorted { $0.overviewFrame.midX > $1.overviewFrame.midX }
            return leftWindows.first?.handle ?? findWrappedPrevious(in: visibleWindows, from: currentIndex)

        case .right:
            let rightWindows = visibleWindows.filter {
                $0.overviewFrame.midX > currentWindow.overviewFrame.midX &&
                abs($0.overviewFrame.midY - currentWindow.overviewFrame.midY) < currentWindow.overviewFrame.height
            }.sorted { $0.overviewFrame.midX < $1.overviewFrame.midX }
            return rightWindows.first?.handle ?? findWrappedNext(in: visibleWindows, from: currentIndex)

        case .up:
            let upWindows = visibleWindows.filter {
                $0.overviewFrame.midY > currentWindow.overviewFrame.midY
            }.sorted { lhs, rhs in
                let lhsYDiff = lhs.overviewFrame.midY - currentWindow.overviewFrame.midY
                let rhsYDiff = rhs.overviewFrame.midY - currentWindow.overviewFrame.midY
                let lhsXDiff = abs(lhs.overviewFrame.midX - currentWindow.overviewFrame.midX)
                let rhsXDiff = abs(rhs.overviewFrame.midX - currentWindow.overviewFrame.midX)
                if lhsYDiff < 100 && rhsYDiff < 100 {
                    return lhsXDiff < rhsXDiff
                }
                return lhsYDiff < rhsYDiff
            }
            if let closest = upWindows.first(where: {
                abs($0.overviewFrame.midX - currentWindow.overviewFrame.midX) < currentWindow.overviewFrame.width
            }) {
                return closest.handle
            }
            return upWindows.first?.handle

        case .down:
            let downWindows = visibleWindows.filter {
                $0.overviewFrame.midY < currentWindow.overviewFrame.midY
            }.sorted { lhs, rhs in
                let lhsYDiff = currentWindow.overviewFrame.midY - lhs.overviewFrame.midY
                let rhsYDiff = currentWindow.overviewFrame.midY - rhs.overviewFrame.midY
                let lhsXDiff = abs(lhs.overviewFrame.midX - currentWindow.overviewFrame.midX)
                let rhsXDiff = abs(rhs.overviewFrame.midX - currentWindow.overviewFrame.midX)
                if lhsYDiff < 100 && rhsYDiff < 100 {
                    return lhsXDiff < rhsXDiff
                }
                return lhsYDiff < rhsYDiff
            }
            if let closest = downWindows.first(where: {
                abs($0.overviewFrame.midX - currentWindow.overviewFrame.midX) < currentWindow.overviewFrame.width
            }) {
                return closest.handle
            }
            return downWindows.first?.handle
        }
    }

    private static func findWrappedNext(in windows: [OverviewWindowItem], from index: Int) -> WindowHandle? {
        let nextIndex = (index + 1) % windows.count
        return windows[nextIndex].handle
    }

    private static func findWrappedPrevious(in windows: [OverviewWindowItem], from index: Int) -> WindowHandle? {
        let prevIndex = (index - 1 + windows.count) % windows.count
        return windows[prevIndex].handle
    }
}

private extension omniwm_overview_context {
    init(context: OverviewLayoutCalculator.BuildContext) {
        self.init(
            screen_x: context.screenFrame.minX,
            screen_y: context.screenFrame.minY,
            screen_width: context.screenFrame.width,
            screen_height: context.screenFrame.height,
            metrics_scale: context.metricsScale,
            available_width: context.availableWidth,
            scaled_window_padding: context.scaledWindowPadding,
            scaled_workspace_label_height: context.scaledWorkspaceLabelHeight,
            scaled_workspace_section_padding: context.scaledWorkspaceSectionPadding,
            scaled_window_spacing: context.scaledWindowSpacing,
            thumbnail_width: context.thumbnailWidth,
            initial_content_y: context.initialContentY,
            content_bottom_padding: context.contentBottomPadding,
            total_content_height_override: 0,
            has_total_content_height_override: 0
        )
    }
}

private extension omniwm_overview_result {
    var scrollOffsetBounds: ClosedRange<CGFloat> {
        min_scroll_offset ... max_scroll_offset
    }
}

private extension omniwm_overview_section_output {
    var sectionFrame: CGRect {
        CGRect(x: section_x, y: section_y, width: section_width, height: section_height)
    }

    var labelFrame: CGRect {
        CGRect(x: label_x, y: label_y, width: label_width, height: label_height)
    }

    var gridFrame: CGRect {
        CGRect(x: grid_x, y: grid_y, width: grid_width, height: grid_height)
    }
}

private extension omniwm_overview_generic_window_output {
    var frame: CGRect {
        CGRect(x: frame_x, y: frame_y, width: frame_width, height: frame_height)
    }
}

private extension omniwm_overview_niri_tile_output {
    var frame: CGRect {
        CGRect(x: frame_x, y: frame_y, width: frame_width, height: frame_height)
    }
}

private extension omniwm_overview_niri_column_output {
    var frame: CGRect {
        CGRect(x: frame_x, y: frame_y, width: frame_width, height: frame_height)
    }
}

private extension omniwm_overview_drop_zone_output {
    var frame: CGRect {
        CGRect(x: frame_x, y: frame_y, width: frame_width, height: frame_height)
    }
}
