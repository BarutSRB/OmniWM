// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
import Foundation
import QuartzCore
import ScreenCaptureKit

@MainActor
final class OverviewWindowFacts {
    private weak var wmController: WMController?
    private let environment: OverviewEnvironment

    init(wmController: WMController, environment: OverviewEnvironment) {
        self.wmController = wmController
        self.environment = environment
    }

    func windowFrame(_ entry: WindowState) -> CGRect? {
        environment.windowFrame(entry)
    }

    func makeOverviewWindowData(
        for entry: WindowState,
        preferredFrame: CGRect?,
        appInfoCache: AppInfoCache
    ) -> OverviewWindowLayoutData {
        let title = environment.windowTitle(entry) ?? ""
        let appInfo = appInfoCache.info(for: entry.pid)
        return OverviewWindowLayoutData(
            token: entry.token,
            workspaceId: entry.workspaceId,
            title: title.isEmpty ? (appInfo?.name ?? "Window") : title,
            appName: appInfo?.name ?? "Unknown",
            appIcon: appInfo?.icon,
            frame: preferredFrame ?? environment.windowFrame(entry) ?? .zero
        )
    }

    func visibleManagedEntry(for handle: WindowHandle) -> WindowState? {
        guard let workspaceManager = wmController?.workspaceManager,
              workspaceManager.handle(for: handle.id) === handle,
              let entry = workspaceManager.entry(for: handle),
              isOverviewEligible(entry, workspaceManager: workspaceManager)
        else {
            return nil
        }
        return entry
    }

    func isOverviewEligible(
        _ entry: WindowState,
        workspaceManager: WorkspaceManager
    ) -> Bool {
        entry.layoutReason == .standard
            && !workspaceManager.isAppHidden(pid: entry.pid)
    }

    func cachedNiriSnapshot(
        _ snapshot: NiriOverviewWorkspaceSnapshot
    ) -> NiriOverviewWorkspaceSnapshot? {
        let columns = snapshot.columns.compactMap { column -> NiriOverviewColumnSnapshot? in
            let tiles = column.tiles.filter { tile in
                guard let workspaceManager = wmController?.workspaceManager,
                      let entry = workspaceManager.entry(for: tile.token)
                else {
                    return false
                }
                return entry.workspaceId == snapshot.workspaceId
                    && isOverviewEligible(entry, workspaceManager: workspaceManager)
            }
            guard !tiles.isEmpty else { return nil }
            return NiriOverviewColumnSnapshot(
                index: 0,
                widthWeight: column.widthWeight,
                preferredWidth: column.preferredWidth,
                tiles: tiles
            )
        }.enumerated().map { index, column in
            NiriOverviewColumnSnapshot(
                index: index,
                widthWeight: column.widthWeight,
                preferredWidth: column.preferredWidth,
                tiles: column.tiles
            )
        }
        guard !columns.isEmpty else { return nil }
        return NiriOverviewWorkspaceSnapshot(workspaceId: snapshot.workspaceId, columns: columns)
    }

    func isNiriLayout(workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let wmController else { return false }
        guard let name = wmController.workspaceManager.descriptor(for: workspaceId)?.name else { return false }
        let layoutType = wmController.settings.workspaces.layoutType(for: name)
        return layoutType != .dwindle
    }
}
