// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
struct OverviewLayoutGeometry {
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
    let contentTopPadding: CGFloat
    let contentBottomPadding: CGFloat

    init(screenFrame: CGRect, scale: CGFloat) {
        let metricsScale = OverviewLayoutCalculator.clampedScale(scale)
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

        self.screenFrame = screenFrame
        self.metricsScale = metricsScale
        self.availableWidth = availableWidth
        self.searchBarFrame = searchBarFrame
        self.scaledWindowPadding = scaledWindowPadding
        self.scaledWorkspaceLabelHeight = OverviewLayoutMetrics.workspaceLabelHeight * metricsScale
        self.scaledWorkspaceSectionPadding = OverviewLayoutMetrics.workspaceSectionPadding * metricsScale
        self.scaledWindowSpacing = OverviewLayoutMetrics.windowSpacing * metricsScale
        self.thumbnailWidth = thumbnailWidth
        self.initialContentY = searchBarY - OverviewLayoutMetrics.contentTopPadding * metricsScale
        self.contentTopPadding = OverviewLayoutMetrics.contentTopPadding * metricsScale
        self.contentBottomPadding = OverviewLayoutMetrics.contentBottomPadding * metricsScale
    }

    func makeWorkspaceLabelFrame(currentY: inout CGFloat) -> CGRect {
        currentY -= scaledWorkspaceLabelHeight
        let frame = CGRect(
            x: screenFrame.minX + scaledWindowPadding,
            y: currentY,
            width: availableWidth,
            height: scaledWorkspaceLabelHeight
        )
        currentY -= scaledWorkspaceSectionPadding
        return frame
    }

    func makeWorkspaceSection(
        workspace: OverviewWorkspaceLayoutItem,
        windows: [OverviewWindowItem],
        labelFrame: CGRect,
        gridFrame: CGRect,
        currentY: inout CGFloat
    ) -> OverviewWorkspaceSection {
        let sectionBottom = gridFrame.minY
        let sectionFrame = CGRect(
            x: screenFrame.minX,
            y: sectionBottom,
            width: screenFrame.width,
            height: currentY + scaledWorkspaceLabelHeight - sectionBottom
        )

        let section = OverviewWorkspaceSection(
            workspaceId: workspace.id,
            name: workspace.name,
            windows: windows,
            sectionFrame: sectionFrame,
            labelFrame: labelFrame,
            gridFrame: gridFrame,
            isActive: workspace.isActive
        )
        currentY = section.sectionFrame.minY - scaledWorkspaceSectionPadding
        return section
    }

    func workspacePreviewScale(
        for sourceSize: CGSize
    ) -> CGFloat {
        let safeWidth = max(sourceSize.width, 1)
        let safeHeight = max(sourceSize.height, 1)
        let maxPreviewWidth = min(
            availableWidth,
            screenFrame.width * 0.72 * metricsScale
        )
        let maxPreviewHeight = max(
            thumbnailWidth / OverviewLayoutMetrics.thumbnailAspectRatio,
            screenFrame.height * 0.42 * metricsScale
        )
        return max(
            0.01,
            min(maxPreviewWidth / safeWidth, maxPreviewHeight / safeHeight)
        )
    }

    func makeWindowItem(
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
            windowId: windowData.token.windowId,
            workspaceId: workspaceId,
            title: windowData.title,
            appName: windowData.appName,
            appIcon: windowData.appIcon?.cgImage(forProposedRect: nil, context: nil, hints: nil),
            originalFrame: windowData.frame,
            overviewFrame: overviewFrame,
            matchesSearch: matchesSearch
        )
    }

    func totalContentHeight(currentY: CGFloat) -> CGFloat {
        let contentTop = searchBarFrame.minY - contentTopPadding
        let contentBottom = currentY + scaledWorkspaceSectionPadding - contentBottomPadding
        return contentTop - contentBottom
    }
}
