import Foundation

struct OverviewSearchFilter {

    static func filterWindows(
        in layout: inout OverviewLayout,
        query: String
    ) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespaces).lowercased()

        for sectionIndex in layout.workspaceSections.indices {
            for windowIndex in layout.workspaceSections[sectionIndex].windows.indices {
                let window = layout.workspaceSections[sectionIndex].windows[windowIndex]
                let matches = matchesQuery(window: window, query: normalizedQuery)
                layout.workspaceSections[sectionIndex].windows[windowIndex].matchesSearch = matches
            }
        }
    }

    static func matchesQuery(window: OverviewWindowItem, query: String) -> Bool {
        if query.isEmpty {
            return true
        }

        let title = window.title.lowercased()
        let appName = window.appName.lowercased()

        if title.contains(query) || appName.contains(query) {
            return true
        }

        let queryWords = query.split(separator: " ").map { String($0) }
        if queryWords.count > 1 {
            return queryWords.allSatisfy { word in
                title.contains(word) || appName.contains(word)
            }
        }

        return false
    }

    static func firstMatchingWindow(in layout: OverviewLayout) -> OverviewWindowItem? {
        for section in layout.workspaceSections {
            for window in section.windows where window.matchesSearch {
                return window
            }
        }
        return nil
    }

    static func allMatchingWindows(in layout: OverviewLayout) -> [OverviewWindowItem] {
        layout.workspaceSections.flatMap { section in
            section.windows.filter(\.matchesSearch)
        }
    }

    static func matchingCount(in layout: OverviewLayout) -> Int {
        layout.workspaceSections.reduce(0) { total, section in
            total + section.windows.filter(\.matchesSearch).count
        }
    }

    static func updateSelectionForSearch(layout: inout OverviewLayout) {
        guard let currentSelected = layout.selectedWindow() else {
            if let first = firstMatchingWindow(in: layout) {
                layout.setSelected(handle: first.handle)
            }
            return
        }

        if currentSelected.matchesSearch {
            return
        }

        if let first = firstMatchingWindow(in: layout) {
            layout.setSelected(handle: first.handle)
        } else {
            layout.setSelected(handle: nil)
        }
    }

    @MainActor
    static func selectNextMatch(
        layout: inout OverviewLayout,
        from currentHandle: WindowHandle?,
        direction: Direction
    ) {
        let matching = allMatchingWindows(in: layout)
        guard !matching.isEmpty else { return }

        guard let currentHandle else {
            if let first = matching.first {
                layout.setSelected(handle: first.handle)
            }
            return
        }

        guard matching.contains(where: { $0.handle == currentHandle }) else {
            if let first = matching.first {
                layout.setSelected(handle: first.handle)
            }
            return
        }

        let nextHandle = OverviewLayoutCalculator.findNextWindow(
            in: layout,
            from: currentHandle,
            direction: direction
        )

        if let nextHandle {
            layout.setSelected(handle: nextHandle)
        }
    }
}
