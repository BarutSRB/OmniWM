// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension OverviewLayoutGeometry {
    struct NiriWorkspaceProjection {
        let section: OverviewWorkspaceSection
        let columns: [OverviewNiriColumn]
        let columnDropZones: [OverviewColumnDropZone]
    }

    private struct NiriGridGeometry {
        let workspaceId: WorkspaceDescriptor.ID
        let frame: CGRect
        let scale: CGFloat
        let columnWidths: [CGFloat]
        let columnHeights: [CGFloat]

        func columnFrame(at index: Int, x: CGFloat) -> CGRect {
            let width = columnWidths.indices.contains(index) ? columnWidths[index] : 0
            let height = columnHeights.indices.contains(index) ? columnHeights[index] : frame.height
            return CGRect(x: x, y: frame.minY, width: width, height: height)
        }
    }

    func buildNiriWorkspaceProjection(
        workspace: OverviewWorkspaceLayoutItem,
        snapshot: NiriOverviewWorkspaceSnapshot,
        windowsByToken: [WindowToken: (WindowHandle, OverviewWindowLayoutData)],
        searchQuery: String,
        currentY: inout CGFloat
    ) -> NiriWorkspaceProjection? {
        guard !snapshot.columns.isEmpty else { return nil }

        let labelFrame = makeWorkspaceLabelFrame(currentY: &currentY)

        let grid = niriGridGeometry(
            workspaceId: workspace.id,
            columns: snapshot.columns,
            top: currentY
        )

        var windowItems: [OverviewWindowItem] = []
        windowItems.reserveCapacity(snapshot.columns.reduce(0) { $0 + $1.tiles.count })

        let projectedColumns = projectNiriColumns(
            snapshot.columns,
            windowsByToken: windowsByToken,
            searchQuery: searchQuery,
            grid: grid,
            windowItems: &windowItems
        )

        let section = makeWorkspaceSection(
            workspace: workspace,
            windows: windowItems,
            labelFrame: labelFrame,
            gridFrame: grid.frame,
            currentY: &currentY
        )

        return NiriWorkspaceProjection(
            section: section,
            columns: projectedColumns,
            columnDropZones: buildNiriColumnDropZones(
                workspaceId: workspace.id,
                gridFrame: grid.frame,
                columns: projectedColumns
            )
        )
    }

    private func niriGridGeometry(
        workspaceId: WorkspaceDescriptor.ID,
        columns: [NiriOverviewColumnSnapshot],
        top: CGFloat
    ) -> NiriGridGeometry {
        let columnCount = columns.count
        let totalWeight = columns.reduce(CGFloat(0)) { partial, column in
            partial + max(column.widthWeight, 0.001)
        }
        let rawColumnWidths = columns.map { column in
            preferredNiriColumnWidth(
                for: column,
                totalWeight: totalWeight,
                columnCount: columnCount
            )
        }
        let rawColumnHeights = columns.map { column in
            preferredNiriColumnHeight(for: column, spacing: scaledWindowSpacing)
        }
        let rawTotalWidth = rawColumnWidths.reduce(CGFloat(0), +) +
            scaledWindowSpacing * CGFloat(max(0, columnCount - 1))
        let rawMaxHeight = max(rawColumnHeights.max() ?? 1, 1)
        let workspaceScale = workspacePreviewScale(
            for: CGSize(width: rawTotalWidth, height: rawMaxHeight)
        )
        let columnWidths = rawColumnWidths.map { $0 * workspaceScale }
        let columnHeights = rawColumnHeights.map { $0 * workspaceScale }
        let totalGridWidth = rawTotalWidth * workspaceScale
        let gridHeight = rawMaxHeight * workspaceScale
        let gridStartX = screenFrame.minX + (screenFrame.width - totalGridWidth) / 2
        let gridFrame = CGRect(
            x: gridStartX,
            y: top - gridHeight,
            width: totalGridWidth,
            height: gridHeight
        )

        return NiriGridGeometry(
            workspaceId: workspaceId,
            frame: gridFrame,
            scale: workspaceScale,
            columnWidths: columnWidths,
            columnHeights: columnHeights
        )
    }

    private func projectNiriColumns(
        _ columns: [NiriOverviewColumnSnapshot],
        windowsByToken: [WindowToken: (WindowHandle, OverviewWindowLayoutData)],
        searchQuery: String,
        grid: NiriGridGeometry,
        windowItems: inout [OverviewWindowItem]
    ) -> [OverviewNiriColumn] {
        var projectedColumns: [OverviewNiriColumn] = []
        projectedColumns.reserveCapacity(columns.count)

        var currentX = grid.frame.minX
        for (columnIndex, columnSnapshot) in columns.enumerated() {
            let columnFrame = grid.columnFrame(at: columnIndex, x: currentX)

            let mappedWindows = columnSnapshot.tiles.compactMap { windowsByToken[$0.token] }
            let projectedTileHeights = columnSnapshot.tiles.map { max($0.preferredHeight, 1) * grid.scale }

            var handles: [WindowHandle] = []
            handles.reserveCapacity(mappedWindows.count)

            var nextTileY = columnFrame.maxY
            for (tileIndex, (handle, windowData)) in mappedWindows.enumerated() {
                let tileHeight = projectedTileHeights.indices.contains(tileIndex)
                    ? projectedTileHeights[tileIndex]
                    : max(windowData.frame.height * grid.scale, 1)
                let tileY = nextTileY - tileHeight
                let tileFrame = CGRect(
                    x: columnFrame.minX,
                    y: tileY,
                    width: columnFrame.width,
                    height: tileHeight
                )

                windowItems.append(
                    makeWindowItem(
                        handle: handle,
                        workspaceId: grid.workspaceId,
                        windowData: windowData,
                        overviewFrame: tileFrame,
                        searchQuery: searchQuery
                    )
                )
                handles.append(handle)
                nextTileY = tileY - scaledWindowSpacing
            }

            projectedColumns.append(
                OverviewNiriColumn(
                    workspaceId: grid.workspaceId,
                    columnIndex: columnSnapshot.index,
                    frame: columnFrame,
                    windowHandles: handles
                )
            )

            currentX += columnFrame.width + scaledWindowSpacing
        }

        return projectedColumns
    }

    private func preferredNiriColumnWidth(
        for column: NiriOverviewColumnSnapshot,
        totalWeight: CGFloat,
        columnCount: Int
    ) -> CGFloat {
        if let preferredWidth = column.preferredWidth, preferredWidth > 0 {
            return preferredWidth
        }

        let normalizedWeight = max(column.widthWeight, 0.001) / max(totalWeight, 0.001)
        return thumbnailWidth * CGFloat(columnCount) * normalizedWeight
    }

    private func preferredNiriColumnHeight(
        for column: NiriOverviewColumnSnapshot,
        spacing: CGFloat
    ) -> CGFloat {
        guard !column.tiles.isEmpty else { return 1 }

        let preferredHeight = column.tiles.reduce(CGFloat(0)) { partial, tile in
            partial + max(tile.preferredHeight, 1)
        }
        return preferredHeight + spacing * CGFloat(max(0, column.tiles.count - 1))
    }

    private func buildNiriColumnDropZones(
        workspaceId: WorkspaceDescriptor.ID,
        gridFrame: CGRect,
        columns: [OverviewNiriColumn]
    ) -> [OverviewColumnDropZone] {
        guard !columns.isEmpty else { return [] }

        let edgeZoneWidth = max(12 * metricsScale, min(30 * metricsScale, scaledWindowSpacing))
        var zones: [OverviewColumnDropZone] = []
        zones.reserveCapacity(columns.count + 1)

        zones.append(
            OverviewColumnDropZone(
                workspaceId: workspaceId,
                insertIndex: 0,
                frame: CGRect(
                    x: gridFrame.minX - edgeZoneWidth,
                    y: gridFrame.minY,
                    width: edgeZoneWidth,
                    height: gridFrame.height
                )
            )
        )

        if columns.count > 1 {
            for index in 0 ..< (columns.count - 1) {
                let left = columns[index].frame.maxX
                let right = columns[index + 1].frame.minX
                zones.append(
                    OverviewColumnDropZone(
                        workspaceId: workspaceId,
                        insertIndex: index + 1,
                        frame: CGRect(
                            x: left,
                            y: gridFrame.minY,
                            width: max(0, right - left),
                            height: gridFrame.height
                        )
                    )
                )
            }
        }

        zones.append(
            OverviewColumnDropZone(
                workspaceId: workspaceId,
                insertIndex: columns.count,
                frame: CGRect(
                    x: gridFrame.maxX,
                    y: gridFrame.minY,
                    width: edgeZoneWidth,
                    height: gridFrame.height
                )
            )
        )

        return zones
    }
}
