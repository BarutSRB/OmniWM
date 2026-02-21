import AppKit
import Foundation

@MainActor
enum WorkspaceBarDataSource {
    private struct SortKey {
        let group: Int
        let primary: Int
        let secondary: Int
    }

    static func workspaceBarItems(
        for monitor: Monitor,
        deduplicate: Bool,
        hideEmpty: Bool,
        workspaceManager: WorkspaceManager,
        appInfoCache: AppInfoCache,
        niriEngine: NiriLayoutEngine?,
        focusedHandle: WindowHandle?,
        settings: SettingsStore
    ) -> [WorkspaceBarItem] {
        var workspaces = workspaceManager.workspaces(on: monitor.id)

        if hideEmpty {
            workspaces = workspaces.filter { !workspaceManager.entries(in: $0.id).isEmpty }
        }

        let activeWorkspaceId = workspaceManager.activeWorkspace(on: monitor.id)?.id

        return workspaces.map { workspace in
            let entries = workspaceManager.entries(in: workspace.id)
            let orderMap = orderMap(for: workspace.id, engine: niriEngine)
            let orderedEntries = sortEntries(entries, orderMap: orderMap)
            let useLayoutOrder = !(orderMap?.isEmpty ?? true)
            let windows: [WorkspaceBarWindowItem] = if deduplicate {
                createDedupedWindowItems(
                    entries: orderedEntries,
                    useLayoutOrder: useLayoutOrder,
                    appInfoCache: appInfoCache,
                    focusedHandle: focusedHandle
                )
            } else {
                createIndividualWindowItems(
                    entries: orderedEntries,
                    appInfoCache: appInfoCache,
                    focusedHandle: focusedHandle
                )
            }

            return WorkspaceBarItem(
                id: workspace.id,
                name: settings.displayName(for: workspace.name),
                isFocused: workspace.id == activeWorkspaceId,
                windows: windows
            )
        }
    }

    private static func orderMap(
        for workspaceId: WorkspaceDescriptor.ID,
        engine: NiriLayoutEngine?
    ) -> [WindowHandle: SortKey]? {
        guard let engine else { return nil }

        var order: [WindowHandle: SortKey] = [:]
        let columns = engine.columns(in: workspaceId)

        for (colIdx, column) in columns.enumerated() {
            for (rowIdx, window) in column.windowNodes.enumerated() {
                order[window.handle] = SortKey(group: 0, primary: colIdx, secondary: rowIdx)
            }
        }

        return order
    }

    private static func sortEntries(
        _ entries: [WindowModel.Entry],
        orderMap: [WindowHandle: SortKey]?
    ) -> [WindowModel.Entry] {
        guard let orderMap else { return entries }
        let fallbackOrder = Dictionary(uniqueKeysWithValues: entries.enumerated()
            .map { ($0.element.handle, $0.offset) })

        return entries.sorted { lhs, rhs in
            let lhsKey = orderMap[lhs.handle] ?? SortKey(group: 2, primary: Int.max, secondary: Int.max)
            let rhsKey = orderMap[rhs.handle] ?? SortKey(group: 2, primary: Int.max, secondary: Int.max)

            if lhsKey.group != rhsKey.group { return lhsKey.group < rhsKey.group }
            if lhsKey.primary != rhsKey.primary { return lhsKey.primary < rhsKey.primary }
            if lhsKey.secondary != rhsKey.secondary { return lhsKey.secondary < rhsKey.secondary }

            let lhsFallback = fallbackOrder[lhs.handle] ?? 0
            let rhsFallback = fallbackOrder[rhs.handle] ?? 0
            return lhsFallback < rhsFallback
        }
    }

    private static func createDedupedWindowItems(
        entries: [WindowModel.Entry],
        useLayoutOrder: Bool,
        appInfoCache: AppInfoCache,
        focusedHandle: WindowHandle?
    ) -> [WorkspaceBarWindowItem] {
        if useLayoutOrder {
            var groupedByApp: [String: [WindowModel.Entry]] = [:]
            var orderedAppNames: [String] = []

            for entry in entries {
                let appName = appInfoCache.name(for: entry.handle.pid) ?? "Unknown"

                if groupedByApp[appName] == nil {
                    groupedByApp[appName] = []
                    orderedAppNames.append(appName)
                }

                groupedByApp[appName]?.append(entry)
            }

            return orderedAppNames.compactMap { appName in
                guard let appEntries = groupedByApp[appName], let firstEntry = appEntries.first else { return nil }
                let appInfo = appInfoCache.info(for: firstEntry.handle.pid)
                let anyFocused = appEntries.contains { $0.handle.id == focusedHandle?.id }

                let windowInfos = appEntries.map { entry -> WorkspaceBarWindowInfo in
                    WorkspaceBarWindowInfo(
                        id: entry.handle.id,
                        windowId: entry.windowId,
                        title: windowTitle(for: entry) ?? appName,
                        isFocused: entry.handle.id == focusedHandle?.id
                    )
                }

                return WorkspaceBarWindowItem(
                    id: firstEntry.handle.id,
                    windowId: firstEntry.windowId,
                    appName: appName,
                    icon: appInfo?.icon,
                    isFocused: anyFocused,
                    windowCount: appEntries.count,
                    allWindows: windowInfos
                )
            }
        }

        let groupedByApp = Dictionary(grouping: entries) { entry -> String in
            appInfoCache.name(for: entry.handle.pid) ?? "Unknown"
        }

        return groupedByApp.map { appName, appEntries -> WorkspaceBarWindowItem in
            let firstEntry = appEntries.first!
            let appInfo = appInfoCache.info(for: firstEntry.handle.pid)
            let anyFocused = appEntries.contains { $0.handle.id == focusedHandle?.id }

            let windowInfos = appEntries.map { entry -> WorkspaceBarWindowInfo in
                WorkspaceBarWindowInfo(
                    id: entry.handle.id,
                    windowId: entry.windowId,
                    title: windowTitle(for: entry) ?? appName,
                    isFocused: entry.handle.id == focusedHandle?.id
                )
            }

            return WorkspaceBarWindowItem(
                id: firstEntry.handle.id,
                windowId: firstEntry.windowId,
                appName: appName,
                icon: appInfo?.icon,
                isFocused: anyFocused,
                windowCount: appEntries.count,
                allWindows: windowInfos
            )
        }.sorted { $0.appName < $1.appName }
    }

    private static func createIndividualWindowItems(
        entries: [WindowModel.Entry],
        appInfoCache: AppInfoCache,
        focusedHandle: WindowHandle?
    ) -> [WorkspaceBarWindowItem] {
        entries.map { entry in
            let appInfo = appInfoCache.info(for: entry.handle.pid)
            let appName = appInfo?.name ?? "Unknown"
            let title = windowTitle(for: entry) ?? appName

            return WorkspaceBarWindowItem(
                id: entry.handle.id,
                windowId: entry.windowId,
                appName: appName,
                icon: appInfo?.icon,
                isFocused: entry.handle.id == focusedHandle?.id,
                windowCount: 1,
                allWindows: [
                    WorkspaceBarWindowInfo(
                        id: entry.handle.id,
                        windowId: entry.windowId,
                        title: title,
                        isFocused: entry.handle.id == focusedHandle?.id
                    )
                ]
            )
        }
    }

    private static func windowTitle(for entry: WindowModel.Entry) -> String? {
        guard let title = AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId)),
              !title.isEmpty else { return nil }
        return title
    }
}
