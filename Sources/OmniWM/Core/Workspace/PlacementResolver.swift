// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

enum WorkspacePlacementRung: String, Sendable {
    case existingEntry = "existing_entry"
    case structuralReplacement = "structural_replacement"
    case trackedParent = "tracked_parent"
    case sameAppSibling = "same_app_sibling"
    case workspaceRule = "workspace_rule"
    case pendingFocusContext = "pending_focus_context"
    case focusedContext = "focused_context"
    case nativeSpace = "native_space"
    case floatingSpawn = "floating_spawn"
    case liveManagedFocus = "live_managed_focus"
    case frame = "frame"
    case axFrame = "ax_frame"
    case interactionMonitor = "interaction_monitor"
    case fallbackWorkspace = "fallback_workspace"
    case defaultWorkspace = "default_workspace"
}

struct WorkspacePlacementResolution: Equatable {
    let workspaceId: WorkspaceDescriptor.ID
    let rung: WorkspacePlacementRung
}

@MainActor
final class PlacementResolver {
    private struct WorkspacePlacementTarget {
        let workspaceId: WorkspaceDescriptor.ID?
        let monitorId: Monitor.ID?
        let isAuthoritative: Bool
        let rung: WorkspacePlacementRung
    }

    private let workspaceManager: WorkspaceManager

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    func monitorForInteraction() -> Monitor? {
        if let interactionMonitorId = workspaceManager.interactionMonitorId,
           let monitor = workspaceManager.monitor(byId: interactionMonitorId)
        {
            return monitor
        }
        if let focusedToken = workspaceManager.focusedToken,
           let workspaceId = workspaceManager.workspace(for: focusedToken),
           let monitor = workspaceManager.monitor(for: workspaceId)
        {
            return monitor
        }
        return workspaceManager.monitors.first
    }

    func resolveWorkspacePlacement(
        workspaceName: String?,
        axRef: AXWindowRef,
        pid: pid_t?,
        parentWindowId: UInt32?,
        inheritTrackedParentWorkspace: Bool,
        preferSameAppSiblingWorkspace: Bool,
        structuralReplacementWorkspaceId: WorkspaceDescriptor.ID?,
        restrictWorkspaceRuleToPlacementMonitor: Bool,
        createPlacementContext: WindowCreatePlacementContext?,
        windowFrame: CGRect?,
        existingEntry: WindowState?,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?,
        context: WindowRuleReevaluationContext
    ) -> WorkspacePlacementResolution {
        if context == .automatic, let existingEntry {
            return WorkspacePlacementResolution(workspaceId: existingEntry.workspaceId, rung: .existingEntry)
        }

        if existingEntry == nil,
           let structuralReplacementWorkspaceId,
           workspaceManager.descriptor(for: structuralReplacementWorkspaceId) != nil
        {
            return WorkspacePlacementResolution(
                workspaceId: structuralReplacementWorkspaceId,
                rung: .structuralReplacement
            )
        }

        if existingEntry == nil,
           inheritTrackedParentWorkspace,
           let parentWorkspaceId = workspaceForTrackedParentWindow(parentWindowId: parentWindowId, pid: pid)
        {
            return WorkspacePlacementResolution(workspaceId: parentWorkspaceId, rung: .trackedParent)
        }

        let placementTarget = createPlacementTarget(
            axRef: axRef,
            pid: pid,
            createPlacementContext: createPlacementContext,
            windowFrame: windowFrame,
            fallbackWorkspaceId: fallbackWorkspaceId,
            preferManagedFocusPlacement: existingEntry == nil && restrictWorkspaceRuleToPlacementMonitor
        )

        if context == .automatic,
           existingEntry == nil,
           preferSameAppSiblingWorkspace,
           let pid,
           let siblingWorkspaceId = workspaceForNewSiblingWindow(
               pid: pid,
               fallbackWorkspaceId: fallbackWorkspaceId,
               targetMonitorId: placementTarget.isAuthoritative ? placementTarget.monitorId : nil
           )
        {
            return WorkspacePlacementResolution(workspaceId: siblingWorkspaceId, rung: .sameAppSibling)
        }

        if let workspaceName,
           let workspaceId = workspaceManager.workspaceId(for: workspaceName, createIfMissing: false),
           existingEntry != nil ||
           !restrictWorkspaceRuleToPlacementMonitor ||
           shouldApplyWorkspaceRule(workspaceId, placementTarget: placementTarget)
        {
            return WorkspacePlacementResolution(workspaceId: workspaceId, rung: .workspaceRule)
        }

        if let existingEntry {
            return WorkspacePlacementResolution(workspaceId: existingEntry.workspaceId, rung: .existingEntry)
        }

        return defaultWorkspacePlacement(placementTarget: placementTarget)
    }

    private func workspaceForTrackedParentWindow(
        parentWindowId: UInt32?,
        pid _: pid_t?
    ) -> WorkspaceDescriptor.ID? {
        guard let parentWindowId, parentWindowId != 0 else { return nil }
        return workspaceManager.entry(forWindowId: Int(parentWindowId))?.workspaceId
    }

    private func workspaceForNewSiblingWindow(
        pid: pid_t,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?,
        targetMonitorId: Monitor.ID?
    ) -> WorkspaceDescriptor.ID? {
        let entries = workspaceManager.entries(forPid: pid)
        guard let firstEntry = entries.first else { return nil }

        if let focusedToken = workspaceManager.focusedToken,
           let focusedEntry = entries.first(where: { $0.token == focusedToken }),
           workspace(focusedEntry.workspaceId, isOn: targetMonitorId)
        {
            return focusedEntry.workspaceId
        }

        if let fallbackWorkspaceId,
           entries.contains(where: { $0.workspaceId == fallbackWorkspaceId }),
           workspace(fallbackWorkspaceId, isOn: targetMonitorId)
        {
            return fallbackWorkspaceId
        }

        let workspaceId = firstEntry.workspaceId
        guard entries.dropFirst().allSatisfy({ $0.workspaceId == workspaceId }),
              workspace(workspaceId, isOn: targetMonitorId)
        else {
            return nil
        }
        return workspaceId
    }

    private func workspace(
        _ workspaceId: WorkspaceDescriptor.ID,
        isOn targetMonitorId: Monitor.ID?
    ) -> Bool {
        guard let targetMonitorId else { return true }
        return workspaceManager.monitorId(for: workspaceId) == targetMonitorId
    }

    func floatingSpawnMonitorId(pid: pid_t) -> Monitor.ID? {
        let tiled = workspaceManager.entries(forPid: pid).filter { $0.mode == .tiling }
        guard !tiled.isEmpty else { return nil }

        if let focused = workspaceManager.focusedToken,
           let entry = tiled.first(where: { $0.token == focused }),
           let monitorId = workspaceManager.monitorId(for: entry.workspaceId)
        {
            return monitorId
        }

        if let recent = workspaceManager.lastTiledFocusedToken,
           let entry = tiled.first(where: { $0.token == recent }),
           let monitorId = workspaceManager.monitorId(for: entry.workspaceId)
        {
            return monitorId
        }

        let monitors = Set(tiled.compactMap { workspaceManager.monitorId(for: $0.workspaceId) })
        return monitors.count == 1 ? monitors.first : nil
    }

    private func shouldApplyWorkspaceRule(
        _ workspaceId: WorkspaceDescriptor.ID,
        placementTarget: WorkspacePlacementTarget
    ) -> Bool {
        guard placementTarget.isAuthoritative,
              let targetMonitorId = placementTarget.monitorId,
              let workspaceMonitorId = workspaceManager.monitorId(for: workspaceId)
        else {
            return true
        }
        return workspaceMonitorId == targetMonitorId
    }

    private func defaultWorkspacePlacement(
        placementTarget: WorkspacePlacementTarget
    ) -> WorkspacePlacementResolution {
        if let workspaceId = placementTarget.workspaceId {
            return WorkspacePlacementResolution(workspaceId: workspaceId, rung: placementTarget.rung)
        }

        if let monitor = monitorForInteraction(),
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        {
            return WorkspacePlacementResolution(workspaceId: workspace.id, rung: .defaultWorkspace)
        }
        if let workspaceId = workspaceManager.primaryWorkspace()?.id ?? workspaceManager.workspaces.first?.id {
            return WorkspacePlacementResolution(workspaceId: workspaceId, rung: .defaultWorkspace)
        }
        if let createdWorkspaceId = workspaceManager.workspaceId(for: "1", createIfMissing: false) {
            return WorkspacePlacementResolution(workspaceId: createdWorkspaceId, rung: .defaultWorkspace)
        }
        fatal("resolveWorkspaceForNewWindow: no workspaces exist")
    }

    private func createPlacementTarget(
        axRef: AXWindowRef,
        pid: pid_t?,
        createPlacementContext: WindowCreatePlacementContext?,
        windowFrame: CGRect?,
        fallbackWorkspaceId: WorkspaceDescriptor.ID?,
        preferManagedFocusPlacement: Bool
    ) -> WorkspacePlacementTarget {
        if preferManagedFocusPlacement {
            if let target = managedFocusPlacementTarget(
                createPlacementContext?.pendingFocusedWorkspaceId,
                createPlacementContext?.pendingFocusedMonitorId,
                rung: .pendingFocusContext
            ) {
                return target
            }

            if let target = managedFocusPlacementTarget(
                createPlacementContext?.focusedWorkspaceId,
                createPlacementContext?.focusedMonitorId,
                rung: .focusedContext
            ) {
                return target
            }
        }

        if let monitorId = createPlacementContext?.nativeSpaceMonitorId,
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitorId)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                monitorId: monitorId,
                isAuthoritative: true,
                rung: .nativeSpace
            )
        }

        if !preferManagedFocusPlacement,
           let pid,
           let monitorId = floatingSpawnMonitorId(pid: pid),
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitorId)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                monitorId: monitorId,
                isAuthoritative: true,
                rung: .floatingSpawn
            )
        }

        if preferManagedFocusPlacement,
           let target = liveManagedFocusPlacementTarget()
        {
            return target
        }

        if let monitor = monitorForPlacementFrame(windowFrame),
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                monitorId: monitor.id,
                isAuthoritative: true,
                rung: .frame
            )
        }

        if workspaceManager.monitors.count > 1,
           let monitor = monitorForPlacementFrame(AXWindowService.framePreferFast(axRef)),
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitor.id)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                monitorId: monitor.id,
                isAuthoritative: true,
                rung: .axFrame
            )
        }

        if !preferManagedFocusPlacement {
            if let target = managedFocusPlacementTarget(
                createPlacementContext?.pendingFocusedWorkspaceId,
                createPlacementContext?.pendingFocusedMonitorId,
                rung: .pendingFocusContext
            ) {
                return target
            }

            if let target = managedFocusPlacementTarget(
                createPlacementContext?.focusedWorkspaceId,
                createPlacementContext?.focusedMonitorId,
                rung: .focusedContext
            ) {
                return target
            }
        }

        if let monitorId = createPlacementContext?.interactionMonitorId,
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitorId)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                monitorId: monitorId,
                isAuthoritative: true,
                rung: .interactionMonitor
            )
        }

        if let fallbackWorkspaceId,
           workspaceManager.descriptor(for: fallbackWorkspaceId) != nil
        {
            return WorkspacePlacementTarget(
                workspaceId: fallbackWorkspaceId,
                monitorId: workspaceManager.monitorId(for: fallbackWorkspaceId),
                isAuthoritative: false,
                rung: .fallbackWorkspace
            )
        }

        return WorkspacePlacementTarget(
            workspaceId: nil,
            monitorId: nil,
            isAuthoritative: false,
            rung: .defaultWorkspace
        )
    }

    private func liveManagedFocusPlacementTarget() -> WorkspacePlacementTarget? {
        guard !workspaceManager.isNonManagedFocusActive else { return nil }
        for token in [workspaceManager.focusedToken, workspaceManager.lastTiledFocusedToken] {
            guard let token,
                  let entry = workspaceManager.entry(for: token),
                  let target = managedFocusPlacementTarget(entry.workspaceId, nil, rung: .liveManagedFocus)
            else {
                continue
            }
            return target
        }
        return nil
    }

    private func managedFocusPlacementTarget(
        _ workspaceId: WorkspaceDescriptor.ID?,
        _ monitorId: Monitor.ID?,
        rung: WorkspacePlacementRung
    ) -> WorkspacePlacementTarget? {
        if let workspaceId,
           workspaceManager.descriptor(for: workspaceId) != nil
        {
            let resolvedMonitorId = workspaceManager.monitorId(for: workspaceId) ?? monitorId
            return WorkspacePlacementTarget(
                workspaceId: workspaceId,
                monitorId: resolvedMonitorId,
                isAuthoritative: true,
                rung: rung
            )
        }

        if let monitorId,
           let workspace = workspaceManager.activeWorkspaceOrFirst(on: monitorId)
        {
            return WorkspacePlacementTarget(
                workspaceId: workspace.id,
                monitorId: monitorId,
                isAuthoritative: true,
                rung: rung
            )
        }

        return nil
    }

    private func monitorForPlacementFrame(_ frame: CGRect?) -> Monitor? {
        guard let frame, !frame.isNull, !frame.isEmpty else { return nil }
        return frame.center.monitorApproximation(in: workspaceManager.monitors)
    }
}
