import AppKit
import Foundation

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

    static func calculateLayout(
        workspaces: [(id: WorkspaceDescriptor.ID, name: String, isActive: Bool)],
        windows: [WindowHandle: (entry: WindowModel.Entry, title: String, appName: String, appIcon: NSImage?, frame: CGRect)],
        screenFrame: CGRect,
        searchQuery: String
    ) -> OverviewLayout {
        var layout = OverviewLayout()

        let searchBarY = screenFrame.maxY - OverviewLayoutMetrics.searchBarHeight - OverviewLayoutMetrics.searchBarPadding
        layout.searchBarFrame = CGRect(
            x: screenFrame.minX + screenFrame.width * 0.25,
            y: searchBarY,
            width: screenFrame.width * 0.5,
            height: OverviewLayoutMetrics.searchBarHeight
        )

        let availableWidth = screenFrame.width - (OverviewLayoutMetrics.windowPadding * 2)
        let thumbnailWidth = min(
            OverviewLayoutMetrics.maxThumbnailWidth,
            max(OverviewLayoutMetrics.minThumbnailWidth, availableWidth / 4)
        )
        let thumbnailHeight = thumbnailWidth / OverviewLayoutMetrics.thumbnailAspectRatio

        var currentY = searchBarY - OverviewLayoutMetrics.contentTopPadding

        for workspace in workspaces {
            let workspaceWindows = windows.filter { $0.value.entry.workspaceId == workspace.id }

            if workspaceWindows.isEmpty {
                continue
            }

            var windowItems: [OverviewWindowItem] = []

            let sortedWindows = workspaceWindows.sorted { lhs, rhs in
                lhs.value.title < rhs.value.title
            }

            let columns = calculateOptimalColumns(
                windowCount: sortedWindows.count,
                availableWidth: availableWidth,
                thumbnailWidth: thumbnailWidth
            )

            let totalGridWidth = CGFloat(columns) * thumbnailWidth + CGFloat(columns - 1) * OverviewLayoutMetrics.windowSpacing
            let gridStartX = screenFrame.minX + (screenFrame.width - totalGridWidth) / 2

            currentY -= OverviewLayoutMetrics.workspaceLabelHeight

            let labelFrame = CGRect(
                x: screenFrame.minX + OverviewLayoutMetrics.windowPadding,
                y: currentY,
                width: availableWidth,
                height: OverviewLayoutMetrics.workspaceLabelHeight
            )

            currentY -= OverviewLayoutMetrics.workspaceSectionPadding

            var windowIndex = 0
            for (handle, windowData) in sortedWindows {
                let column = windowIndex % columns
                let row = windowIndex / columns

                let windowX = gridStartX + CGFloat(column) * (thumbnailWidth + OverviewLayoutMetrics.windowSpacing)
                let windowY = currentY - CGFloat(row + 1) * (thumbnailHeight + OverviewLayoutMetrics.windowSpacing)

                let overviewFrame = CGRect(
                    x: windowX,
                    y: windowY,
                    width: thumbnailWidth,
                    height: thumbnailHeight
                )

                let matchesSearch = searchQuery.isEmpty ||
                    windowData.title.localizedCaseInsensitiveContains(searchQuery) ||
                    windowData.appName.localizedCaseInsensitiveContains(searchQuery)

                let item = OverviewWindowItem(
                    handle: handle,
                    windowId: windowData.entry.windowId,
                    workspaceId: workspace.id,
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
                windowItems.append(item)
                windowIndex += 1
            }

            let rows = (sortedWindows.count + columns - 1) / columns
            let gridHeight = CGFloat(rows) * thumbnailHeight + CGFloat(rows - 1) * OverviewLayoutMetrics.windowSpacing
            let gridFrame = CGRect(
                x: gridStartX,
                y: currentY - gridHeight,
                width: totalGridWidth,
                height: gridHeight
            )

            let sectionBottom = currentY - gridHeight
            let sectionFrame = CGRect(
                x: screenFrame.minX,
                y: sectionBottom,
                width: screenFrame.width,
                height: currentY + OverviewLayoutMetrics.workspaceLabelHeight - sectionBottom
            )

            let section = OverviewWorkspaceSection(
                workspaceId: workspace.id,
                name: workspace.name,
                windows: windowItems,
                sectionFrame: sectionFrame,
                labelFrame: labelFrame,
                gridFrame: gridFrame,
                isActive: workspace.isActive
            )
            layout.workspaceSections.append(section)

            currentY = sectionBottom - OverviewLayoutMetrics.workspaceSectionPadding
        }

        let contentTop = searchBarY - OverviewLayoutMetrics.contentTopPadding
        let contentBottom = currentY + OverviewLayoutMetrics.workspaceSectionPadding - OverviewLayoutMetrics.contentBottomPadding
        layout.totalContentHeight = contentTop - contentBottom

        return layout
    }

    private static func calculateOptimalColumns(
        windowCount: Int,
        availableWidth: CGFloat,
        thumbnailWidth: CGFloat
    ) -> Int {
        let maxColumns = Int((availableWidth + OverviewLayoutMetrics.windowSpacing) / (thumbnailWidth + OverviewLayoutMetrics.windowSpacing))
        let idealColumns = min(windowCount, max(1, maxColumns))

        if windowCount <= 3 {
            return min(windowCount, idealColumns)
        }

        if windowCount <= 6 {
            return min(3, idealColumns)
        }

        return min(4, idealColumns)
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
