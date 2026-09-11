// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension OverviewLayoutGeometry {
    func buildGenericWorkspaceSection(
        workspace: OverviewWorkspaceLayoutItem,
        windows: [(WindowHandle, OverviewWindowLayoutData)],
        searchQuery: String,
        currentY: inout CGFloat
    ) -> OverviewWorkspaceSection? {
        guard !windows.isEmpty else { return nil }

        let orderedWindows = windows.sorted { lhs, rhs in
            compareWindowsForPreview(lhs.1, rhs.1)
        }

        let labelFrame = makeWorkspaceLabelFrame(currentY: &currentY)

        var windowItems: [OverviewWindowItem] = []
        windowItems.reserveCapacity(orderedWindows.count)

        let normalizedFrames = orderedWindows.map { normalizedSourceFrame($0.1.frame) }
        let sourceBounds = boundingRect(for: normalizedFrames)
        let previewScale = workspacePreviewScale(for: sourceBounds.size)
        let projectedSize = CGSize(
            width: sourceBounds.width * previewScale,
            height: sourceBounds.height * previewScale
        )
        let previewOrigin = CGPoint(
            x: screenFrame.minX + (screenFrame.width - projectedSize.width) / 2,
            y: currentY - projectedSize.height
        )

        for ((handle, windowData), sourceFrame) in zip(orderedWindows, normalizedFrames) {
            let overviewFrame = projectFrame(
                sourceFrame,
                from: sourceBounds,
                previewOrigin: previewOrigin,
                scale: previewScale
            )

            windowItems.append(
                makeWindowItem(
                    handle: handle,
                    workspaceId: workspace.id,
                    windowData: windowData,
                    overviewFrame: overviewFrame,
                    searchQuery: searchQuery
                )
            )
        }

        let gridFrame = CGRect(
            origin: previewOrigin,
            size: projectedSize
        )

        let section = makeWorkspaceSection(
            workspace: workspace,
            windows: windowItems,
            labelFrame: labelFrame,
            gridFrame: gridFrame,
            currentY: &currentY
        )

        return section
    }

    private func compareWindowsForPreview(
        _ lhs: OverviewWindowLayoutData,
        _ rhs: OverviewWindowLayoutData
    ) -> Bool {
        let lhsFrame = normalizedSourceFrame(lhs.frame)
        let rhsFrame = normalizedSourceFrame(rhs.frame)
        if abs(lhsFrame.maxY - rhsFrame.maxY) > 1 {
            return lhsFrame.maxY > rhsFrame.maxY
        }
        if abs(lhsFrame.minX - rhsFrame.minX) > 1 {
            return lhsFrame.minX < rhsFrame.minX
        }
        return lhs.title < rhs.title
    }

    private func normalizedSourceFrame(_ frame: CGRect) -> CGRect {
        let standardized = frame.standardized
        return CGRect(
            x: standardized.minX,
            y: standardized.minY,
            width: max(standardized.width, 1),
            height: max(standardized.height, 1)
        )
    }

    private func boundingRect(for frames: [CGRect]) -> CGRect {
        let bounds = frames.reduce(into: CGRect.null) { partial, frame in
            partial = partial.union(frame)
        }
        if bounds.isNull {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        return CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: max(bounds.width, 1),
            height: max(bounds.height, 1)
        )
    }

    private func projectFrame(
        _ sourceFrame: CGRect,
        from sourceBounds: CGRect,
        previewOrigin: CGPoint,
        scale: CGFloat
    ) -> CGRect {
        CGRect(
            x: previewOrigin.x + (sourceFrame.minX - sourceBounds.minX) * scale,
            y: previewOrigin.y + (sourceFrame.minY - sourceBounds.minY) * scale,
            width: sourceFrame.width * scale,
            height: sourceFrame.height * scale
        )
    }
}
