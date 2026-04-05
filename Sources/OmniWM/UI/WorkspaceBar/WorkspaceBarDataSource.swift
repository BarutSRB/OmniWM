import AppKit
import Foundation

@MainActor
enum WorkspaceBarDataSource {
    private struct WorkspaceSnapshot {
        let workspace: WorkspaceDescriptor
        let tiledEntries: [WindowModel.Entry]
        let floatingEntries: [WindowModel.Entry]
        let hasBarOccupancy: Bool
    }

    static func workspaceBarItems(
        for monitor: Monitor,
        options: WorkspaceBarProjectionOptions,
        workspaceManager: WorkspaceManager,
        appInfoCache: AppInfoCache,
        niriEngine: NiriLayoutEngine?,
        focusedToken: WindowToken?,
        settings: SettingsStore
    ) -> [WorkspaceBarItem] {
        var workspaces = workspaceManager.workspaces(on: monitor.id).map { workspace in
            let projectedEntries = workspaceManager.barVisibleEntries(
                in: workspace.id,
                showFloatingWindows: options.showFloatingWindows
            )
            return WorkspaceSnapshot(
                workspace: workspace,
                tiledEntries: projectedEntries.filter { $0.mode == .tiling },
                floatingEntries: projectedEntries.filter { $0.mode == .floating },
                hasBarOccupancy: workspaceManager.hasBarVisibleOccupancy(
                    in: workspace.id,
                    showFloatingWindows: options.showFloatingWindows
                )
            )
        }

        if options.hideEmptyWorkspaces {
            workspaces = workspaces.filter(\.hasBarOccupancy)
        }

        let activeWorkspaceId = workspaceManager.activeWorkspace(on: monitor.id)?.id

        return workspaces.map { snapshot in
            let orderedTiledEntries = WorkspaceEntryOrdering.orderedEntries(
                snapshot.tiledEntries,
                in: snapshot.workspace.id,
                engine: niriEngine
            )
            let orderedFloatingEntries = WorkspaceEntryOrdering.orderedEntries(
                snapshot.floatingEntries,
                in: snapshot.workspace.id,
                engine: niriEngine
            )
            let useLayoutOrder = niriEngine.map { !$0.columns(in: snapshot.workspace.id).isEmpty } ?? false
            let tiledWindows = createWindowItems(
                entries: orderedTiledEntries,
                deduplicate: options.deduplicateAppIcons,
                useLayoutOrder: useLayoutOrder,
                appInfoCache: appInfoCache,
                focusedToken: focusedToken
            )
            let floatingWindows = createWindowItems(
                entries: orderedFloatingEntries,
                deduplicate: options.deduplicateAppIcons,
                useLayoutOrder: useLayoutOrder,
                appInfoCache: appInfoCache,
                focusedToken: focusedToken
            )

            return WorkspaceBarItem(
                id: snapshot.workspace.id,
                name: settings.displayName(for: snapshot.workspace.name),
                rawName: snapshot.workspace.name,
                isFocused: snapshot.workspace.id == activeWorkspaceId,
                tiledWindows: tiledWindows,
                floatingWindows: floatingWindows
            )
        }
    }

    private static func createWindowItems(
        entries: [WindowModel.Entry],
        deduplicate: Bool,
        useLayoutOrder: Bool,
        appInfoCache: AppInfoCache,
        focusedToken: WindowToken?
    ) -> [WorkspaceBarWindowItem] {
        if deduplicate {
            return createDedupedWindowItems(
                entries: entries,
                useLayoutOrder: useLayoutOrder,
                appInfoCache: appInfoCache,
                focusedToken: focusedToken
            )
        }

        return createIndividualWindowItems(
            entries: entries,
            appInfoCache: appInfoCache,
            focusedToken: focusedToken
        )
    }

    private static func createDedupedWindowItems(
        entries: [WindowModel.Entry],
        useLayoutOrder: Bool,
        appInfoCache: AppInfoCache,
        focusedToken: WindowToken?
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

            return orderedAppNames.compactMap { appName -> WorkspaceBarWindowItem? in
                guard let appEntries = groupedByApp[appName], let firstEntry = appEntries.first else { return nil }
                let appInfo = appInfoCache.info(for: firstEntry.handle.pid)
                let anyFocused = appEntries.contains { $0.handle.id == focusedToken }

                let windowInfos = appEntries.map { entry -> WorkspaceBarWindowInfo in
                    WorkspaceBarWindowInfo(
                        id: entry.handle.id,
                        windowId: entry.windowId,
                        title: windowTitle(for: entry) ?? appName,
                        isFocused: entry.handle.id == focusedToken
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
            let anyFocused = appEntries.contains { $0.handle.id == focusedToken }

            let windowInfos = appEntries.map { entry -> WorkspaceBarWindowInfo in
                WorkspaceBarWindowInfo(
                    id: entry.handle.id,
                    windowId: entry.windowId,
                    title: windowTitle(for: entry) ?? appName,
                    isFocused: entry.handle.id == focusedToken
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
        focusedToken: WindowToken?
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
                isFocused: entry.handle.id == focusedToken,
                windowCount: 1,
                allWindows: [
                    WorkspaceBarWindowInfo(
                        id: entry.handle.id,
                        windowId: entry.windowId,
                        title: title,
                        isFocused: entry.handle.id == focusedToken
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
