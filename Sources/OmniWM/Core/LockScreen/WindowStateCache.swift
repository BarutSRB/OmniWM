import CoreGraphics
import Foundation

@MainActor
final class WindowStateCache {
    private var cache: FrozenWorld = .empty

    func captureState(
        workspaceManager: WorkspaceManager,
        niriEngine: NiriLayoutEngine?
    ) {
        guard let engine = niriEngine else { return }

        let allEntries = workspaceManager.allEntries()
        guard !allEntries.isEmpty else { return }

        let currentWindowIds = Set(allEntries.map(\.windowId))

        if currentWindowIds.isSubset(of: cache.windowIds) {
            return
        }

        var frozenWorkspaces: [FrozenWorkspace] = []
        var frozenWindows: [Int: FrozenWindow] = [:]

        for workspace in workspaceManager.workspaces {
            let wsId = workspace.id

            var frozenColumns: [FrozenColumn] = []
            let columns = engine.columns(in: wsId)

            for (colIdx, column) in columns.enumerated() {
                var windowIds: [Int] = []

                for (winIdx, windowNode) in column.windowNodes.enumerated() {
                    guard let entry = workspaceManager.entry(for: windowNode.handle) else { continue }

                    windowIds.append(entry.windowId)

                    let frozenWindow = FrozenWindow(
                        windowId: entry.windowId,
                        pid: entry.handle.pid,
                        workspaceId: wsId,
                        parentKind: entry.parentKind,
                        columnIndex: colIdx,
                        windowIndexInColumn: winIdx,
                        size: windowNode.size,
                        height: FrozenWindowHeight(from: windowNode.height),
                        width: FrozenColumnWidth(from: column.width),
                        sizingMode: FrozenSizingMode(from: windowNode.sizingMode)
                    )
                    frozenWindows[entry.windowId] = frozenWindow
                }

                let frozenCol = FrozenColumn(
                    index: colIdx,
                    width: FrozenColumnWidth(from: column.width),
                    displayMode: FrozenColumnDisplay(from: column.displayMode),
                    activeTileIdx: column.activeTileIdx,
                    isFullWidth: column.isFullWidth,
                    windowIds: windowIds
                )
                frozenColumns.append(frozenCol)
            }

            let viewportState = workspaceManager.niriViewportState(for: wsId)

            let frozenWs = FrozenWorkspace(
                workspaceId: wsId,
                columns: frozenColumns,
                viewportState: FrozenViewportState(from: viewportState)
            )
            frozenWorkspaces.append(frozenWs)
        }

        var frozenMonitors: [FrozenMonitor] = []
        for monitor in workspaceManager.monitors {
            if let activeWs = workspaceManager.activeWorkspace(on: monitor.id) {
                frozenMonitors.append(FrozenMonitor(
                    displayId: monitor.id.displayId,
                    visibleWorkspaceId: activeWs.id
                ))
            }
        }

        cache = FrozenWorld(
            workspaces: frozenWorkspaces,
            monitors: frozenMonitors,
            windows: frozenWindows,
            timestamp: Date()
        )
    }

    func containsWindow(_ windowId: Int) -> Bool {
        cache.windows[windowId] != nil
    }

    func frozenWindow(_ windowId: Int) -> FrozenWindow? {
        cache.windows[windowId]
    }

    func reset() {
        cache = .empty
    }

    var hasCache: Bool {
        !cache.isEmpty
    }

    var frozenWorld: FrozenWorld {
        cache
    }

    var cachedWindowIds: Set<Int> {
        cache.windowIds
    }

    func restoreViewportState(for workspaceId: WorkspaceDescriptor.ID, workspaceManager: WorkspaceManager) {
        if let frozenWs = cache.workspaces.first(where: { $0.workspaceId == workspaceId }) {
            workspaceManager.updateNiriViewportState(frozenWs.viewportState.toViewportState(), for: workspaceId)
        }
    }

    func frozenWorkspaceId(for windowId: Int) -> WorkspaceDescriptor.ID? {
        cache.windows[windowId]?.workspaceId
    }
}
