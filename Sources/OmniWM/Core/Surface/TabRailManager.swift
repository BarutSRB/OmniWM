// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

@MainActor
final class TabRailManager {
    typealias SelectionHandler = (TabRailInfo, Int, WindowToken?) -> Void

    static let tabIndicatorWidth: CGFloat = TabRailMetrics.totalWidth

    var onSelect: SelectionHandler?

    private var railWindows: [TabRailKey: TabRailWindow] = [:]
    private var railInfos: [TabRailKey: TabRailInfo] = [:]

    func updateRails(_ infos: [TabRailInfo], forceOrdering: Bool = false) {
        var desiredKeys = Set<TabRailKey>()
        desiredKeys.reserveCapacity(infos.count)
        for info in infos where info.tabCount > 0 {
            desiredKeys.insert(info.key)
            railInfos[info.key] = info
            if railWindows[info.key] != nil || Self.isRenderable(visibleTileFrame: info.visibleTileFrame) {
                updateRail(info, forceOrdering: forceOrdering)
            }
        }

        let staleWindowKeys = railWindows.keys.filter { !desiredKeys.contains($0) }
        for key in staleWindowKeys {
            railWindows.removeValue(forKey: key)?.close()
        }
        let staleInfoKeys = railInfos.keys.filter { !desiredKeys.contains($0) }
        for key in staleInfoKeys {
            railInfos.removeValue(forKey: key)
        }
    }

    func applyAnimationGeometry(
        _ commands: [TabRailGeometryCommand],
        in workspaceId: WorkspaceDescriptor.ID? = nil
    ) {
        for command in commands {
            if let workspaceId, command.key.workspaceId != workspaceId {
                continue
            }
            if let window = railWindows[command.key] {
                window.updateAnimationGeometry(command)
                continue
            }
            guard Self.isRenderable(visibleTileFrame: command.visibleTileFrame),
                  let info = railInfos[command.key]
            else {
                continue
            }
            let presentedInfo = TabRailInfo(
                workspaceId: info.workspaceId,
                owner: info.owner,
                plannedSeq: info.plannedSeq,
                tileFrame: command.tileFrame,
                visibleTileFrame: command.visibleTileFrame,
                tabCount: info.tabCount,
                activeVisualIndex: info.activeVisualIndex,
                activeWindowId: info.activeWindowId,
                tabs: info.tabs
            )
            railInfos[command.key] = presentedInfo
            updateRail(presentedInfo, forceOrdering: false)
        }
    }

    func existingWindow(for key: TabRailKey) -> NSWindow? {
        railWindows[key]
    }

    private func updateRail(_ info: TabRailInfo, forceOrdering: Bool) {
        let key = info.key
        let window = railWindows[key] ?? {
            let window = TabRailWindow(owner: info.owner, workspaceId: info.workspaceId)
            window.onSelect = { [weak self] info, visualIndex, token in
                self?.onSelect?(info, visualIndex, token)
            }
            railWindows[key] = window
            return window
        }()
        window.update(info: info, forceOrdering: forceOrdering)
    }

    func removeAll() {
        for (_, window) in railWindows {
            window.close()
        }
        railWindows.removeAll()
        railInfos.removeAll()
    }

    static func isRenderable(visibleTileFrame: CGRect) -> Bool {
        !visibleTileFrame.isNull
            && visibleTileFrame.width >= TabRailMetrics.minVisibleIntersection
            && visibleTileFrame.height >= TabRailMetrics.minVisibleIntersection
    }
}
