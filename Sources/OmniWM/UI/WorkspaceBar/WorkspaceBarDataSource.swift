// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
struct WorkspaceBarDataSource {
    private let workspaceManager: WorkspaceManager
    private let windowProjector: WorkspaceBarWindowProjector
    private let settings: SettingsStore

    init(
        workspaceManager: WorkspaceManager,
        appInfoCache: AppInfoCache,
        iconResolver: WorkspaceBarIconResolver,
        settings: SettingsStore
    ) {
        self.workspaceManager = workspaceManager
        self.windowProjector = WorkspaceBarWindowProjector(
            workspaceManager: workspaceManager,
            appInfoCache: appInfoCache,
            iconResolver: iconResolver
        )
        self.settings = settings
    }

    private struct WorkspaceSnapshot {
        let workspace: WorkspaceDescriptor
        let tiledEntries: [WindowState]
        let floatingEntries: [WindowState]
        let hasBarOccupancy: Bool
    }

    func workspaceBarProjection(
        for monitor: Monitor,
        options: WorkspaceBarProjectionOptions,
        focusedToken: WindowToken?
    ) -> WorkspaceBarProjection {
        WorkspaceBarProjection(
            items: workspaceItems(
                for: monitor,
                options: options,
                focusedToken: focusedToken
            ),
            scratchpads: scratchpadItems(
                options: options,
                focusedToken: focusedToken
            )
        )
    }

    private func workspaceItems(
        for monitor: Monitor,
        options: WorkspaceBarProjectionOptions,
        focusedToken: WindowToken?
    ) -> [WorkspaceBarItem] {
        var workspaces = workspaceManager.workspaces(on: monitor.id).map { workspace in
            workspaceSnapshot(
                for: workspace,
                options: options
            )
        }

        let activeWorkspaceId = workspaceManager.activeWorkspace(on: monitor.id)?.id
        let hiddenAppPIDs = workspaceManager.hiddenAppPIDs

        if options.hideEmptyWorkspaces {
            workspaces = workspaces.filter { $0.hasBarOccupancy || $0.workspace.id == activeWorkspaceId }
        }

        return workspaces.map { snapshot in
            workspaceItem(
                snapshot,
                options: options,
                activeWorkspaceId: activeWorkspaceId,
                focusedToken: focusedToken,
                hiddenAppPIDs: hiddenAppPIDs
            )
        }
    }

    private func workspaceItem(
        _ snapshot: WorkspaceSnapshot,
        options: WorkspaceBarProjectionOptions,
        activeWorkspaceId: WorkspaceDescriptor.ID?,
        focusedToken: WindowToken?,
        hiddenAppPIDs: Set<pid_t>
    ) -> WorkspaceBarItem {
        let topology = workspaceManager.layoutTopology(for: snapshot.workspace.id)
        let orderedTiledEntries = visibilityOrderedEntries(
            WorkspaceEntryOrdering.orderedEntries(
                snapshot.tiledEntries,
                topology: topology
            ),
            hiddenAppPIDs: hiddenAppPIDs
        )
        let orderedFloatingEntries = visibilityOrderedEntries(
            WorkspaceEntryOrdering.orderedEntries(
                snapshot.floatingEntries,
                topology: topology
            ),
            hiddenAppPIDs: hiddenAppPIDs
        )
        let useLayoutOrder = topology.hasColumns
        let tiledWindows = windowProjector.items(
            entries: orderedTiledEntries,
            deduplicate: options.deduplicateAppIcons,
            useLayoutOrder: useLayoutOrder,
            focusedToken: focusedToken,
            hiddenAppPIDs: hiddenAppPIDs
        )
        let floatingWindows = windowProjector.items(
            entries: orderedFloatingEntries,
            deduplicate: options.deduplicateAppIcons,
            useLayoutOrder: useLayoutOrder,
            focusedToken: focusedToken,
            hiddenAppPIDs: hiddenAppPIDs
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

    private func workspaceSnapshot(
        for workspace: WorkspaceDescriptor,
        options: WorkspaceBarProjectionOptions
    ) -> WorkspaceSnapshot {
        let projectedEntries = workspaceManager.barVisibleEntries(
            in: workspace.id,
            showFloatingWindows: options.showFloatingWindows
        )
        var tiledEntries: [WindowState] = []
        var floatingEntries: [WindowState] = []
        for entry in projectedEntries {
            if windowProjector.isExcluded(entry, options: options) {
                continue
            }
            switch entry.mode {
            case .tiling:
                tiledEntries.append(entry)
            case .floating:
                floatingEntries.append(entry)
            }
        }
        return WorkspaceSnapshot(
            workspace: workspace,
            tiledEntries: tiledEntries,
            floatingEntries: floatingEntries,
            hasBarOccupancy: !tiledEntries.isEmpty || !floatingEntries.isEmpty
        )
    }

    private func scratchpadItems(
        options: WorkspaceBarProjectionOptions,
        focusedToken: WindowToken?
    ) -> [WorkspaceBarScratchpadItem] {
        workspaceManager.occupiedScratchpadIndices().compactMap { index in
            let entries = workspaceManager.scratchpadMembers(in: index).compactMap { token in
                workspaceManager.entry(for: token).flatMap {
                    windowProjector.isExcluded($0, options: options) ? nil : $0
                }
            }
            guard !entries.isEmpty else { return nil }

            let windows = windowProjector.items(
                entries: entries,
                deduplicate: true,
                useLayoutOrder: false,
                focusedToken: focusedToken,
                hiddenAppPIDs: workspaceManager.hiddenAppPIDs
            )
            guard !windows.isEmpty else { return nil }
            let isRevealed = workspaceManager.revealedScratchpadIndex() == index

            return WorkspaceBarScratchpadItem(
                index: index.rawValue,
                label: settings.scratchpadLabel(for: index.rawValue),
                windows: windows,
                isVisible: isRevealed && entries.contains {
                    workspaceManager.hiddenState(for: $0.token) == nil
                        && !workspaceManager.isAppHidden(pid: $0.pid)
                },
                isRevealed: isRevealed
            )
        }
    }

    private func visibilityOrderedEntries(
        _ entries: [WindowState],
        hiddenAppPIDs: Set<pid_t>
    ) -> [WindowState] {
        var visible: [WindowState] = []
        var hidden: [WindowState] = []
        visible.reserveCapacity(entries.count)
        hidden.reserveCapacity(entries.count)
        for entry in entries {
            if hiddenAppPIDs.contains(entry.pid) {
                hidden.append(entry)
            } else {
                visible.append(entry)
            }
        }
        visible.append(contentsOf: hidden)
        return visible
    }
}
