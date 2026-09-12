// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Carbon
import Foundation
import QuartzCore
import ScreenCaptureKit

@MainActor
final class OverviewSnapshot {
    private weak var wmController: WMController?
    private let facts: OverviewWindowFacts
    private(set) var workspaces: [OverviewWorkspaceLayoutItem] = []
    private(set) var windows: [WindowHandle: OverviewWindowLayoutData] = [:]
    private(set) var niriSnapshotsByWorkspace: [WorkspaceDescriptor.ID: NiriOverviewWorkspaceSnapshot] = [:]
    private(set) var groupCountByHandle: [WindowHandle: Int] = [:]

    init(wmController: WMController, facts: OverviewWindowFacts) {
        self.wmController = wmController
        self.facts = facts
    }

    var windowIds: [Int] {
        windows.values.map(\.token.windowId).sorted()
    }

    func reset() {
        workspaces = []
        windows = [:]
        niriSnapshotsByWorkspace = [:]
        groupCountByHandle = [:]
    }

    func remove(_ handle: WindowHandle) -> OverviewWindowLayoutData? {
        windows.removeValue(forKey: handle)
    }

    func refresh(affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>) {
        guard let wmController else { return }
        let workspaceManager = wmController.workspaceManager
        refreshWorkspaces(affectedWorkspaceIds: affectedWorkspaceIds, workspaceManager: workspaceManager)
        let projections = refreshEngineProjections(
            affectedWorkspaceIds: affectedWorkspaceIds,
            wmController: wmController
        )
        refreshCachedWindows(engineFrames: projections.frames)
        for workspaceId in projections.niriWorkspaceIds {
            reconcileNiriOverviewProjection(
                workspaceId: workspaceId,
                frames: projections.frames
            )
        }

        for (workspaceId, projection) in projections.dwindleProjections {
            reconcileDwindleOverviewProjection(
                projection,
                workspaceId: workspaceId
            )
        }

        groupCountByHandle = groupCountByHandle.filter {
            windows[$0.key] != nil
        }
    }

    private func refreshWorkspaces(
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        workspaceManager: WorkspaceManager
    ) {
        guard let wmController else { return }
        var workspaces: [OverviewWorkspaceLayoutItem] = []
        for monitor in workspaceManager.monitors {
            let activeWorkspaceId = workspaceManager.activeWorkspace(on: monitor.id)?.id
            for workspace in workspaceManager.workspaces(on: monitor.id) {
                workspaces.append(OverviewWorkspaceLayoutItem(
                    id: workspace.id,
                    name: wmController.settings.workspaces.displayName(for: workspace.name),
                    isActive: workspace.id == activeWorkspaceId
                ))
            }
        }
        self.workspaces = workspaces

        let staleGroupHandles = groupCountByHandle.keys.filter { handle in
            windows[handle].map { affectedWorkspaceIds.contains($0.workspaceId) } == true
        }
        for handle in staleGroupHandles {
            groupCountByHandle.removeValue(forKey: handle)
        }
    }

    private struct EngineProjections {
        var frames: [WindowToken: CGRect]
        var niriWorkspaceIds: Set<WorkspaceDescriptor.ID>
        var dwindleProjections: [WorkspaceDescriptor.ID: DwindleOverviewWorkspaceProjection]
    }

    private func refreshEngineProjections(
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        wmController: WMController
    ) -> EngineProjections {
        let workspaceManager = wmController.workspaceManager
        var engineFrames: [WindowToken: CGRect] = [:]
        var niriWorkspaceIds: Set<WorkspaceDescriptor.ID> = []
        var dwindleProjections: [WorkspaceDescriptor.ID: DwindleOverviewWorkspaceProjection] = [:]
        for workspaceId in affectedWorkspaceIds {
            switch workspaceManager.activeLayoutKind(for: workspaceId) {
            case .niri:
                niriWorkspaceIds.insert(workspaceId)
                if let frames = wmController.niriEngine?.captureWindowFrames(in: workspaceId) {
                    engineFrames.merge(frames) { _, new in new }
                }
                if let snapshot = wmController.niriEngine?.overviewSnapshot(for: workspaceId),
                   let filteredSnapshot = facts.cachedNiriSnapshot(snapshot)
                {
                    niriSnapshotsByWorkspace[workspaceId] = filteredSnapshot
                } else {
                    niriSnapshotsByWorkspace.removeValue(forKey: workspaceId)
                }
            case .dwindle:
                if let projection = dwindleOverviewProjection(for: workspaceId) {
                    dwindleProjections[workspaceId] = projection
                    engineFrames.merge(projection.frames) { _, new in new }
                }
                niriSnapshotsByWorkspace.removeValue(forKey: workspaceId)
            }
        }

        return EngineProjections(
            frames: engineFrames,
            niriWorkspaceIds: niriWorkspaceIds,
            dwindleProjections: dwindleProjections
        )
    }

    private func refreshCachedWindows(engineFrames: [WindowToken: CGRect]) {
        var staleHandles: [WindowHandle] = []
        for (handle, data) in windows {
            guard let entry = facts.visibleManagedEntry(for: handle) else {
                staleHandles.append(handle)
                continue
            }
            let frame = engineFrames[entry.token] ?? data.frame
            if entry.token != data.token || entry.workspaceId != data.workspaceId || frame != data.frame {
                windows[handle] = OverviewWindowLayoutData(
                    token: entry.token,
                    workspaceId: entry.workspaceId,
                    title: data.title,
                    appName: data.appName,
                    appIcon: data.appIcon,
                    frame: frame
                )
            }
        }
        for handle in staleHandles {
            windows.removeValue(forKey: handle)
            groupCountByHandle.removeValue(forKey: handle)
        }
    }

    func build() {
        guard let wmController else { return }
        let workspaceManager = wmController.workspaceManager

        var workspaces: [OverviewWorkspaceLayoutItem] = []
        var windowData: [WindowHandle: OverviewWindowLayoutData] = [:]
        var groupCountByHandle: [WindowHandle: Int] = [:]

        for monitor in workspaceManager.monitors {
            let activeWs = workspaceManager.activeWorkspace(on: monitor.id)

            for ws in workspaceManager.workspaces(on: monitor.id) {
                workspaces.append(OverviewWorkspaceLayoutItem(
                    id: ws.id,
                    name: wmController.settings.workspaces.displayName(for: ws.name),
                    isActive: ws.id == activeWs?.id
                ))

                let dwindleProjection = dwindleOverviewProjection(for: ws.id)

                for entry in workspaceManager.entries(in: ws.id) {
                    guard facts.isOverviewEligible(entry, workspaceManager: workspaceManager),
                          dwindleProjection?.includes(entry.token) != false,
                          let handle = workspaceManager.handle(for: entry.token)
                    else {
                        continue
                    }

                    windowData[handle] = facts.makeOverviewWindowData(
                        for: entry,
                        preferredFrame: dwindleProjection?.frames[entry.token],
                        appInfoCache: wmController.appInfoCache
                    )
                    if let count = dwindleProjection?.groupCountByToken[entry.token], count > 1 {
                        groupCountByHandle[handle] = count
                    }
                }
            }
        }

        self.workspaces = workspaces
        windows = windowData
        self.groupCountByHandle = groupCountByHandle
        niriSnapshotsByWorkspace = buildNiriOverviewSnapshots()
    }
}

extension OverviewSnapshot {
    private func dwindleOverviewProjection(
        for workspaceId: WorkspaceDescriptor.ID
    ) -> DwindleOverviewWorkspaceProjection? {
        guard let wmController,
              wmController.workspaceManager.activeLayoutKind(for: workspaceId) == .dwindle,
              let engine = wmController.dwindleEngine
        else {
            return nil
        }
        let eligibleTokens = Set(
            wmController.workspaceManager.entries(in: workspaceId).lazy
                .filter { self.facts.isOverviewEligible($0, workspaceManager: wmController.workspaceManager) }
                .map(\.token)
        )
        return DwindleOverviewWorkspaceProjection(
            engine: engine,
            workspaceId: workspaceId,
            eligibleTokens: eligibleTokens
        )
    }

    private func reconcileDwindleOverviewProjection(
        _ projection: DwindleOverviewWorkspaceProjection,
        workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let wmController else { return }
        let workspaceManager = wmController.workspaceManager
        var desiredHandles: Set<WindowHandle> = []

        for entry in workspaceManager.entries(in: workspaceId) {
            guard facts.isOverviewEligible(entry, workspaceManager: workspaceManager),
                  projection.includes(entry.token),
                  let handle = workspaceManager.handle(for: entry.token)
            else {
                continue
            }

            desiredHandles.insert(handle)
            let frame = projection.frames[entry.token]
                ?? windows[handle]?.frame
                ?? facts.windowFrame(entry)
                ?? .zero
            if let data = windows[handle] {
                if data.token != entry.token || data.workspaceId != workspaceId || data.frame != frame {
                    windows[handle] = OverviewWindowLayoutData(
                        token: entry.token,
                        workspaceId: workspaceId,
                        title: data.title,
                        appName: data.appName,
                        appIcon: data.appIcon,
                        frame: frame
                    )
                }
            } else {
                windows[handle] = facts.makeOverviewWindowData(
                    for: entry,
                    preferredFrame: frame,
                    appInfoCache: wmController.appInfoCache
                )
            }

            if let count = projection.groupCountByToken[entry.token], count > 1 {
                groupCountByHandle[handle] = count
            }
        }

        let staleHandles = windows.compactMap { handle, data in
            data.workspaceId == workspaceId && !desiredHandles.contains(handle) ? handle : nil
        }
        for handle in staleHandles {
            windows.removeValue(forKey: handle)
            groupCountByHandle.removeValue(forKey: handle)
        }
    }

    private func reconcileNiriOverviewProjection(
        workspaceId: WorkspaceDescriptor.ID,
        frames: [WindowToken: CGRect]
    ) {
        guard let wmController else { return }
        let workspaceManager = wmController.workspaceManager
        var desiredHandles: Set<WindowHandle> = []

        for entry in workspaceManager.entries(in: workspaceId) {
            guard facts.isOverviewEligible(entry, workspaceManager: workspaceManager),
                  let handle = workspaceManager.handle(for: entry.token)
            else {
                continue
            }

            desiredHandles.insert(handle)
            let frame = frames[entry.token]
                ?? windows[handle]?.frame
                ?? facts.windowFrame(entry)
                ?? .zero
            if let data = windows[handle] {
                if data.token != entry.token || data.workspaceId != workspaceId || data.frame != frame {
                    windows[handle] = OverviewWindowLayoutData(
                        token: entry.token,
                        workspaceId: workspaceId,
                        title: data.title,
                        appName: data.appName,
                        appIcon: data.appIcon,
                        frame: frame
                    )
                }
            } else {
                windows[handle] = facts.makeOverviewWindowData(
                    for: entry,
                    preferredFrame: frame,
                    appInfoCache: wmController.appInfoCache
                )
            }
        }

        let staleHandles = windows.compactMap { handle, data in
            data.workspaceId == workspaceId && !desiredHandles.contains(handle) ? handle : nil
        }
        for handle in staleHandles {
            windows.removeValue(forKey: handle)
            groupCountByHandle.removeValue(forKey: handle)
        }
    }

    private func buildNiriOverviewSnapshots() -> [WorkspaceDescriptor.ID: NiriOverviewWorkspaceSnapshot] {
        guard let engine = wmController?.niriEngine else { return [:] }

        var snapshots: [WorkspaceDescriptor.ID: NiriOverviewWorkspaceSnapshot] = [:]
        snapshots.reserveCapacity(workspaces.count)

        for workspace in workspaces {
            guard facts.isNiriLayout(workspaceId: workspace.id),
                  let snapshot = engine.overviewSnapshot(for: workspace.id),
                  let filteredSnapshot = facts.cachedNiriSnapshot(snapshot)
            else {
                continue
            }
            snapshots[workspace.id] = filteredSnapshot
        }

        return snapshots
    }
}
