// SPDX-License-Identifier: GPL-2.0-only
import COmniWMKernels
import Foundation
import OmniWMIPC

@MainActor
enum WorkspaceNavigationKernel {
    enum Operation: Equatable {
        case focusMonitorCyclic
        case focusMonitorLast
        case swapWorkspaceWithMonitor
        case switchWorkspaceExplicit
        case switchWorkspaceRelative
        case focusWorkspaceAnywhere
        case workspaceBackAndForth
        case moveWindowAdjacent
        case moveWindowExplicit
        case moveColumnAdjacent
        case moveColumnExplicit
        case moveWindowToWorkspaceOnMonitor
        case moveWindowHandle

        var rawValue: UInt32 {
            switch self {
            case .focusMonitorCyclic: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_FOCUS_MONITOR_CYCLIC)
            case .focusMonitorLast: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_FOCUS_MONITOR_LAST)
            case .swapWorkspaceWithMonitor: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_SWAP_WORKSPACE_WITH_MONITOR)
            case .switchWorkspaceExplicit: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_SWITCH_WORKSPACE_EXPLICIT)
            case .switchWorkspaceRelative: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_SWITCH_WORKSPACE_RELATIVE)
            case .focusWorkspaceAnywhere: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_FOCUS_WORKSPACE_ANYWHERE)
            case .workspaceBackAndForth: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_WORKSPACE_BACK_AND_FORTH)
            case .moveWindowAdjacent: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_WINDOW_ADJACENT)
            case .moveWindowExplicit: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_WINDOW_EXPLICIT)
            case .moveColumnAdjacent: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_COLUMN_ADJACENT)
            case .moveColumnExplicit: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_COLUMN_EXPLICIT)
            case .moveWindowToWorkspaceOnMonitor: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_WINDOW_TO_WORKSPACE_ON_MONITOR)
            case .moveWindowHandle: UInt32(OMNIWM_WORKSPACE_NAV_OPERATION_MOVE_WINDOW_HANDLE)
            }
        }
    }

    enum Outcome: Equatable {
        case noop
        case execute
        case invalidTarget
        case blocked

        init?(kernelRawValue: UInt32) {
            switch kernelRawValue {
            case UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_NOOP): self = .noop
            case UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_EXECUTE): self = .execute
            case UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_INVALID_TARGET): self = .invalidTarget
            case UInt32(OMNIWM_WORKSPACE_NAV_OUTCOME_BLOCKED): self = .blocked
            default: return nil
            }
        }
    }

    enum FocusAction: Equatable {
        case none
        case workspaceHandoff
        case resolveTargetIfPresent
        case subject
        case recoverSource
        case clearManagedFocus

        init?(kernelRawValue: UInt32) {
            switch kernelRawValue {
            case UInt32(OMNIWM_WORKSPACE_NAV_FOCUS_NONE): self = .none
            case UInt32(OMNIWM_WORKSPACE_NAV_FOCUS_WORKSPACE_HANDOFF): self = .workspaceHandoff
            case UInt32(OMNIWM_WORKSPACE_NAV_FOCUS_RESOLVE_TARGET_IF_PRESENT): self = .resolveTargetIfPresent
            case UInt32(OMNIWM_WORKSPACE_NAV_FOCUS_SUBJECT): self = .subject
            case UInt32(OMNIWM_WORKSPACE_NAV_FOCUS_RECOVER_SOURCE): self = .recoverSource
            case UInt32(OMNIWM_WORKSPACE_NAV_FOCUS_CLEAR_MANAGED_FOCUS): self = .clearManagedFocus
            default: return nil
            }
        }
    }

    enum Subject: Equatable {
        case none
        case window(WindowToken)
        case column(WindowToken)
    }

    struct Intent: Equatable {
        var operation: Operation
        var direction: Direction = .right
        var currentWorkspaceId: WorkspaceDescriptor.ID?
        var sourceWorkspaceId: WorkspaceDescriptor.ID?
        var targetWorkspaceId: WorkspaceDescriptor.ID?
        var currentMonitorId: Monitor.ID?
        var previousMonitorId: Monitor.ID?
        var subjectToken: WindowToken?
        var focusedToken: WindowToken?
        var wrapAround = false
        var followFocus = false
    }

    struct Plan: Equatable {
        var outcome: Outcome
        var subject: Subject
        var focusAction: FocusAction
        var resolvedFocusToken: WindowToken?
        var sourceWorkspaceId: WorkspaceDescriptor.ID?
        var targetWorkspaceId: WorkspaceDescriptor.ID?
        var materializeTargetWorkspaceRawID: String?
        var sourceMonitorId: Monitor.ID?
        var targetMonitorId: Monitor.ID?
        var saveWorkspaceIds: [WorkspaceDescriptor.ID]
        var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>
        var affectedMonitorIds: [Monitor.ID]
        var shouldActivateTargetWorkspace: Bool
        var shouldSetInteractionMonitor: Bool
        var shouldSyncMonitorsToNiri: Bool
        var shouldHideFocusBorder: Bool
        var shouldCommitWorkspaceTransition: Bool
    }

    private struct FocusSessionSnapshot {
        let pendingManagedTiledToken: WindowToken?
        let pendingManagedTiledWorkspaceId: WorkspaceDescriptor.ID?
        let confirmedTiledToken: WindowToken?
        let confirmedTiledWorkspaceId: WorkspaceDescriptor.ID?
        let confirmedFloatingToken: WindowToken?
        let confirmedFloatingWorkspaceId: WorkspaceDescriptor.ID?
        let isNonManagedFocusActive: Bool
        let isAppFullscreenActive: Bool
    }

    private struct WorkspaceFocusSnapshot {
        let rememberedTiledToken: WindowToken?
        let firstTiledToken: WindowToken?
        let rememberedFloatingToken: WindowToken?
        let firstFloatingToken: WindowToken?
    }

    private struct ColumnSubjectSnapshot {
        let activeToken: WindowToken?
        let selectedToken: WindowToken?
    }

    struct Input {
        struct MonitorSnapshot: Equatable {
            var monitorId: Monitor.ID
            var frameMinX: CGFloat
            var frameMaxY: CGFloat
            var centerX: CGFloat
            var centerY: CGFloat
            var activeWorkspaceId: WorkspaceDescriptor.ID?
            var previousWorkspaceId: WorkspaceDescriptor.ID?
        }

        struct WorkspaceSnapshot: Equatable {
            enum LayoutKind: Equatable {
                case defaultLayout
                case niri
                case dwindle
            }

            var workspaceId: WorkspaceDescriptor.ID
            var monitorId: Monitor.ID?
            var layoutKind: LayoutKind
            var rememberedTiledFocusToken: WindowToken?
            var firstTiledFocusToken: WindowToken?
            var rememberedFloatingFocusToken: WindowToken?
            var firstFloatingFocusToken: WindowToken?
        }

        struct FocusSessionSnapshot: Equatable {
            var pendingManagedTiledFocusToken: WindowToken? = nil
            var pendingManagedTiledFocusWorkspaceId: WorkspaceDescriptor.ID? = nil
            var confirmedTiledFocusToken: WindowToken? = nil
            var confirmedTiledFocusWorkspaceId: WorkspaceDescriptor.ID? = nil
            var confirmedFloatingFocusToken: WindowToken? = nil
            var confirmedFloatingFocusWorkspaceId: WorkspaceDescriptor.ID? = nil
            var isNonManagedFocusActive = false
            var isAppFullscreenActive = false
        }

        var intent: Intent
        var adjacentFallbackWorkspaceNumber: UInt32?
        var activeColumnSubjectToken: WindowToken?
        var selectedColumnSubjectToken: WindowToken?
        var focus: FocusSessionSnapshot
        var monitors: [MonitorSnapshot]
        var workspaces: [WorkspaceSnapshot]

        @MainActor
        static func capture(
            controller: WMController,
            intent: Intent
        ) -> Input {
            let manager = controller.workspaceManager

            let monitors = manager.monitors.map { monitor in
                MonitorSnapshot(
                    monitorId: monitor.id,
                    frameMinX: monitor.frame.minX,
                    frameMaxY: monitor.frame.maxY,
                    centerX: monitor.frame.midX,
                    centerY: monitor.frame.midY,
                    activeWorkspaceId: manager.activeWorkspace(on: monitor.id)?.id,
                    previousWorkspaceId: manager.previousWorkspace(on: monitor.id)?.id
                )
            }

            let workspaces = manager.workspaces.map { workspace in
                let focusSnapshot = workspaceFocusSnapshot(manager: manager, workspaceId: workspace.id)
                return WorkspaceSnapshot(
                    workspaceId: workspace.id,
                    monitorId: manager.monitorId(for: workspace.id),
                    layoutKind: layoutKind(controller.settings.layoutType(for: workspace.name)),
                    rememberedTiledFocusToken: focusSnapshot.rememberedTiledToken,
                    firstTiledFocusToken: focusSnapshot.firstTiledToken,
                    rememberedFloatingFocusToken: focusSnapshot.rememberedFloatingToken,
                    firstFloatingFocusToken: focusSnapshot.firstFloatingToken
                )
            }

            let focus = focusSessionSnapshot(manager: manager)
            let sourceWorkspaceId = intent.sourceWorkspaceId
            return Input(
                intent: intent,
                adjacentFallbackWorkspaceNumber: WorkspaceNavigationKernel.adjacentFallbackWorkspaceNumber(
                    controller: controller,
                    intent: intent
                ),
                activeColumnSubjectToken: sourceWorkspaceId.flatMap {
                    WorkspaceNavigationKernel.activeColumnSubjectToken(controller: controller, workspaceId: $0)
                },
                selectedColumnSubjectToken: sourceWorkspaceId.flatMap {
                    WorkspaceNavigationKernel.selectedColumnSubjectToken(controller: controller, workspaceId: $0)
                },
                focus: .init(
                    pendingManagedTiledFocusToken: focus.pendingManagedTiledToken,
                    pendingManagedTiledFocusWorkspaceId: focus.pendingManagedTiledWorkspaceId,
                    confirmedTiledFocusToken: focus.confirmedTiledToken,
                    confirmedTiledFocusWorkspaceId: focus.confirmedTiledWorkspaceId,
                    confirmedFloatingFocusToken: focus.confirmedFloatingToken,
                    confirmedFloatingFocusWorkspaceId: focus.confirmedFloatingWorkspaceId,
                    isNonManagedFocusActive: focus.isNonManagedFocusActive,
                    isAppFullscreenActive: focus.isAppFullscreenActive
                ),
                monitors: monitors,
                workspaces: workspaces
            )
        }
    }

    static func plan(
        controller: WMController,
        intent: Intent
    ) -> Plan {
        plan(.capture(controller: controller, intent: intent))
    }

    static func plan(_ input: Input) -> Plan {
        let intent = input.intent
        var rawMonitors = ContiguousArray<omniwm_workspace_navigation_monitor>()
        rawMonitors.reserveCapacity(input.monitors.count)
        for monitor in input.monitors {
            rawMonitors.append(
                omniwm_workspace_navigation_monitor(
                    monitor_id: monitor.monitorId.displayId,
                    frame_min_x: monitor.frameMinX,
                    frame_max_y: monitor.frameMaxY,
                    center_x: monitor.centerX,
                    center_y: monitor.centerY,
                    active_workspace_id: monitor.activeWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
                    previous_workspace_id: monitor.previousWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
                    has_active_workspace_id: monitor.activeWorkspaceId == nil ? 0 : 1,
                    has_previous_workspace_id: monitor.previousWorkspaceId == nil ? 0 : 1
                )
            )
        }

        var rawWorkspaces = ContiguousArray<omniwm_workspace_navigation_workspace>()
        rawWorkspaces.reserveCapacity(input.workspaces.count)
        for workspace in input.workspaces {
            rawWorkspaces.append(
                omniwm_workspace_navigation_workspace(
                    workspace_id: encode(uuid: workspace.workspaceId),
                    monitor_id: workspace.monitorId?.displayId ?? 0,
                    layout_kind: rawLayoutKind(workspace.layoutKind),
                    remembered_tiled_focus_token: workspace.rememberedTiledFocusToken.map(encode(token:)) ?? zeroToken(),
                    first_tiled_focus_token: workspace.firstTiledFocusToken.map(encode(token:)) ?? zeroToken(),
                    remembered_floating_focus_token: workspace.rememberedFloatingFocusToken.map(encode(token:)) ?? zeroToken(),
                    first_floating_focus_token: workspace.firstFloatingFocusToken.map(encode(token:)) ?? zeroToken(),
                    has_monitor_id: workspace.monitorId == nil ? 0 : 1,
                    has_remembered_tiled_focus_token: workspace.rememberedTiledFocusToken == nil ? 0 : 1,
                    has_first_tiled_focus_token: workspace.firstTiledFocusToken == nil ? 0 : 1,
                    has_remembered_floating_focus_token: workspace.rememberedFloatingFocusToken == nil ? 0 : 1,
                    has_first_floating_focus_token: workspace.firstFloatingFocusToken == nil ? 0 : 1
                )
            )
        }

        var rawInput = omniwm_workspace_navigation_input(
            operation: intent.operation.rawValue,
            direction: rawDirection(intent.direction),
            current_workspace_id: intent.currentWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
            source_workspace_id: intent.sourceWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
            target_workspace_id: intent.targetWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
            adjacent_fallback_workspace_number: input.adjacentFallbackWorkspaceNumber ?? 0,
            current_monitor_id: intent.currentMonitorId?.displayId ?? 0,
            previous_monitor_id: intent.previousMonitorId?.displayId ?? 0,
            subject_token: intent.subjectToken.map(encode(token:)) ?? zeroToken(),
            focused_token: intent.focusedToken.map(encode(token:)) ?? zeroToken(),
            pending_managed_tiled_focus_token: input.focus.pendingManagedTiledFocusToken.map(encode(token:)) ?? zeroToken(),
            pending_managed_tiled_focus_workspace_id: input.focus.pendingManagedTiledFocusWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
            confirmed_tiled_focus_token: input.focus.confirmedTiledFocusToken.map(encode(token:)) ?? zeroToken(),
            confirmed_tiled_focus_workspace_id: input.focus.confirmedTiledFocusWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
            confirmed_floating_focus_token: input.focus.confirmedFloatingFocusToken.map(encode(token:)) ?? zeroToken(),
            confirmed_floating_focus_workspace_id: input.focus.confirmedFloatingFocusWorkspaceId.map(encode(uuid:)) ?? zeroUUID(),
            active_column_subject_token: input.activeColumnSubjectToken.map(encode(token:)) ?? zeroToken(),
            selected_column_subject_token: input.selectedColumnSubjectToken.map(encode(token:)) ?? zeroToken(),
            has_current_workspace_id: intent.currentWorkspaceId == nil ? 0 : 1,
            has_source_workspace_id: intent.sourceWorkspaceId == nil ? 0 : 1,
            has_target_workspace_id: intent.targetWorkspaceId == nil ? 0 : 1,
            has_adjacent_fallback_workspace_number: input.adjacentFallbackWorkspaceNumber == nil ? 0 : 1,
            has_current_monitor_id: intent.currentMonitorId == nil ? 0 : 1,
            has_previous_monitor_id: intent.previousMonitorId == nil ? 0 : 1,
            has_subject_token: intent.subjectToken == nil ? 0 : 1,
            has_focused_token: intent.focusedToken == nil ? 0 : 1,
            has_pending_managed_tiled_focus_token: input.focus.pendingManagedTiledFocusToken == nil ? 0 : 1,
            has_pending_managed_tiled_focus_workspace_id: input.focus.pendingManagedTiledFocusWorkspaceId == nil ? 0 : 1,
            has_confirmed_tiled_focus_token: input.focus.confirmedTiledFocusToken == nil ? 0 : 1,
            has_confirmed_tiled_focus_workspace_id: input.focus.confirmedTiledFocusWorkspaceId == nil ? 0 : 1,
            has_confirmed_floating_focus_token: input.focus.confirmedFloatingFocusToken == nil ? 0 : 1,
            has_confirmed_floating_focus_workspace_id: input.focus.confirmedFloatingFocusWorkspaceId == nil ? 0 : 1,
            has_active_column_subject_token: input.activeColumnSubjectToken == nil ? 0 : 1,
            has_selected_column_subject_token: input.selectedColumnSubjectToken == nil ? 0 : 1,
            is_non_managed_focus_active: input.focus.isNonManagedFocusActive ? 1 : 0,
            is_app_fullscreen_active: input.focus.isAppFullscreenActive ? 1 : 0,
            wrap_around: intent.wrapAround ? 1 : 0,
            follow_focus: intent.followFocus ? 1 : 0
        )

        var saveWorkspaceIds = ContiguousArray(repeating: zeroUUID(), count: 4)
        var affectedWorkspaceIds = ContiguousArray(repeating: zeroUUID(), count: 4)
        var affectedMonitorIds = ContiguousArray(repeating: UInt32.zero, count: 4)

        func grownUUIDBuffer(
            current: ContiguousArray<omniwm_uuid>,
            requiredCount: Int
        ) -> ContiguousArray<omniwm_uuid> {
            let nextCount = max(requiredCount, max(current.count, 1) * 2)
            return ContiguousArray(repeating: zeroUUID(), count: nextCount)
        }

        func grownMonitorBuffer(
            current: ContiguousArray<UInt32>,
            requiredCount: Int
        ) -> ContiguousArray<UInt32> {
            let nextCount = max(requiredCount, max(current.count, 1) * 2)
            return ContiguousArray(repeating: UInt32.zero, count: nextCount)
        }

        while true {
            var rawOutput = omniwm_workspace_navigation_output(
                outcome: 0,
                subject_kind: 0,
                focus_action: 0,
                source_workspace_id: zeroUUID(),
                target_workspace_id: zeroUUID(),
                target_workspace_materialization_number: 0,
                source_monitor_id: 0,
                target_monitor_id: 0,
                subject_token: zeroToken(),
                resolved_focus_token: zeroToken(),
                save_workspace_ids: nil,
                save_workspace_capacity: saveWorkspaceIds.count,
                save_workspace_count: 0,
                affected_workspace_ids: nil,
                affected_workspace_capacity: affectedWorkspaceIds.count,
                affected_workspace_count: 0,
                affected_monitor_ids: nil,
                affected_monitor_capacity: affectedMonitorIds.count,
                affected_monitor_count: 0,
                has_source_workspace_id: 0,
                has_target_workspace_id: 0,
                has_source_monitor_id: 0,
                has_target_monitor_id: 0,
                has_subject_token: 0,
                has_resolved_focus_token: 0,
                should_materialize_target_workspace: 0,
                should_activate_target_workspace: 0,
                should_set_interaction_monitor: 0,
                should_sync_monitors_to_niri: 0,
                should_hide_focus_border: 0,
                should_commit_workspace_transition: 0
            )

            let status = rawMonitors.withUnsafeBufferPointer { monitorBuffer in
                rawWorkspaces.withUnsafeBufferPointer { workspaceBuffer in
                    saveWorkspaceIds.withUnsafeMutableBufferPointer { saveBuffer in
                        affectedWorkspaceIds.withUnsafeMutableBufferPointer { affectedWorkspaceBuffer in
                            affectedMonitorIds.withUnsafeMutableBufferPointer { affectedMonitorBuffer in
                                rawOutput.save_workspace_ids = saveBuffer.baseAddress
                                rawOutput.affected_workspace_ids = affectedWorkspaceBuffer.baseAddress
                                rawOutput.affected_monitor_ids = affectedMonitorBuffer.baseAddress
                                return withUnsafeMutablePointer(to: &rawInput) { inputPointer in
                                    withUnsafeMutablePointer(to: &rawOutput) { outputPointer in
                                        omniwm_workspace_navigation_plan(
                                            inputPointer,
                                            monitorBuffer.baseAddress,
                                            monitorBuffer.count,
                                            workspaceBuffer.baseAddress,
                                            workspaceBuffer.count,
                                            outputPointer
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if status == OMNIWM_KERNELS_STATUS_BUFFER_TOO_SMALL {
                if rawOutput.save_workspace_count > saveWorkspaceIds.count {
                    saveWorkspaceIds = grownUUIDBuffer(
                        current: saveWorkspaceIds,
                        requiredCount: rawOutput.save_workspace_count
                    )
                }
                if rawOutput.affected_workspace_count > affectedWorkspaceIds.count {
                    affectedWorkspaceIds = grownUUIDBuffer(
                        current: affectedWorkspaceIds,
                        requiredCount: rawOutput.affected_workspace_count
                    )
                }
                if rawOutput.affected_monitor_count > affectedMonitorIds.count {
                    affectedMonitorIds = grownMonitorBuffer(
                        current: affectedMonitorIds,
                        requiredCount: rawOutput.affected_monitor_count
                    )
                }
                continue
            }

            precondition(
                status == OMNIWM_KERNELS_STATUS_OK,
                "omniwm_workspace_navigation_plan returned \(status)"
            )

            return decode(
                rawOutput: rawOutput,
                saveWorkspaceIds: Array(saveWorkspaceIds.prefix(rawOutput.save_workspace_count)),
                affectedWorkspaceIds: Array(affectedWorkspaceIds.prefix(rawOutput.affected_workspace_count)),
                affectedMonitorIds: Array(affectedMonitorIds.prefix(rawOutput.affected_monitor_count))
            )
        }
    }

    private static func decode(
        rawOutput: omniwm_workspace_navigation_output,
        saveWorkspaceIds: [omniwm_uuid],
        affectedWorkspaceIds: [omniwm_uuid],
        affectedMonitorIds: [UInt32]
    ) -> Plan {
        let subject = decodeSubject(from: rawOutput)

        return Plan(
            outcome: KernelContract.require(
                Outcome(kernelRawValue: rawOutput.outcome),
                "Unknown workspace navigation outcome \(rawOutput.outcome)"
            ),
            subject: subject,
            focusAction: KernelContract.require(
                FocusAction(kernelRawValue: rawOutput.focus_action),
                "Unknown workspace navigation focus action \(rawOutput.focus_action)"
            ),
            resolvedFocusToken: rawOutput.has_resolved_focus_token == 0 ? nil : decode(token: rawOutput.resolved_focus_token),
            sourceWorkspaceId: rawOutput.has_source_workspace_id == 0 ? nil : decode(uuid: rawOutput.source_workspace_id),
            targetWorkspaceId: rawOutput.has_target_workspace_id == 0 ? nil : decode(uuid: rawOutput.target_workspace_id),
            materializeTargetWorkspaceRawID: rawOutput.should_materialize_target_workspace == 0
                ? nil
                : WorkspaceIDPolicy.rawID(from: Int(rawOutput.target_workspace_materialization_number)),
            sourceMonitorId: rawOutput.has_source_monitor_id == 0 ? nil : Monitor.ID(displayId: rawOutput.source_monitor_id),
            targetMonitorId: rawOutput.has_target_monitor_id == 0 ? nil : Monitor.ID(displayId: rawOutput.target_monitor_id),
            saveWorkspaceIds: saveWorkspaceIds.map(decode(uuid:)),
            affectedWorkspaceIds: Set(affectedWorkspaceIds.map(decode(uuid:))),
            affectedMonitorIds: affectedMonitorIds.map { Monitor.ID(displayId: $0) },
            shouldActivateTargetWorkspace: rawOutput.should_activate_target_workspace != 0,
            shouldSetInteractionMonitor: rawOutput.should_set_interaction_monitor != 0,
            shouldSyncMonitorsToNiri: rawOutput.should_sync_monitors_to_niri != 0,
            shouldHideFocusBorder: rawOutput.should_hide_focus_border != 0,
            shouldCommitWorkspaceTransition: rawOutput.should_commit_workspace_transition != 0
        )
    }

    private static func decodeSubject(from rawOutput: omniwm_workspace_navigation_output) -> Subject {
        guard rawOutput.has_subject_token != 0 else {
            return .none
        }

        switch rawOutput.subject_kind {
        case UInt32(OMNIWM_WORKSPACE_NAV_SUBJECT_NONE):
            return .none
        case UInt32(OMNIWM_WORKSPACE_NAV_SUBJECT_WINDOW):
            return .window(decode(token: rawOutput.subject_token))
        case UInt32(OMNIWM_WORKSPACE_NAV_SUBJECT_COLUMN):
            return .column(decode(token: rawOutput.subject_token))
        default:
            return KernelContract.require(
                nil as Subject?,
                "Unknown workspace navigation subject kind \(rawOutput.subject_kind)"
            )
        }
    }

    private static func focusSessionSnapshot(
        manager: WorkspaceManager
    ) -> FocusSessionSnapshot {
        let pendingManagedTiled: (WindowToken, WorkspaceDescriptor.ID)?
        if let token = manager.pendingFocusedToken,
           let workspaceId = manager.pendingFocusedWorkspaceId,
           eligibleFocusCandidate(
               manager: manager,
               token: token,
               workspaceId: workspaceId,
               mode: .tiling
           ) != nil
        {
            pendingManagedTiled = (token, workspaceId)
        } else {
            pendingManagedTiled = nil
        }

        let confirmedManagedFocus: (WindowToken, WorkspaceDescriptor.ID, TrackedWindowMode)?
        if let token = manager.focusedToken,
           let entry = manager.entry(for: token),
           isFocusResolutionEligible(
               entry,
               in: entry.workspaceId,
               mode: entry.mode
           )
        {
            confirmedManagedFocus = (token, entry.workspaceId, entry.mode)
        } else {
            confirmedManagedFocus = nil
        }

        let confirmedTiledToken: WindowToken?
        let confirmedTiledWorkspaceId: WorkspaceDescriptor.ID?
        let confirmedFloatingToken: WindowToken?
        let confirmedFloatingWorkspaceId: WorkspaceDescriptor.ID?
        if let confirmedManagedFocus {
            switch confirmedManagedFocus.2 {
            case .tiling:
                confirmedTiledToken = confirmedManagedFocus.0
                confirmedTiledWorkspaceId = confirmedManagedFocus.1
                confirmedFloatingToken = nil
                confirmedFloatingWorkspaceId = nil
            case .floating:
                confirmedTiledToken = nil
                confirmedTiledWorkspaceId = nil
                confirmedFloatingToken = confirmedManagedFocus.0
                confirmedFloatingWorkspaceId = confirmedManagedFocus.1
            }
        } else {
            confirmedTiledToken = nil
            confirmedTiledWorkspaceId = nil
            confirmedFloatingToken = nil
            confirmedFloatingWorkspaceId = nil
        }

        return FocusSessionSnapshot(
            pendingManagedTiledToken: pendingManagedTiled?.0,
            pendingManagedTiledWorkspaceId: pendingManagedTiled?.1,
            confirmedTiledToken: confirmedTiledToken,
            confirmedTiledWorkspaceId: confirmedTiledWorkspaceId,
            confirmedFloatingToken: confirmedFloatingToken,
            confirmedFloatingWorkspaceId: confirmedFloatingWorkspaceId,
            isNonManagedFocusActive: manager.isNonManagedFocusActive,
            isAppFullscreenActive: manager.isAppFullscreenActive
        )
    }

    private static func workspaceFocusSnapshot(
        manager: WorkspaceManager,
        workspaceId: WorkspaceDescriptor.ID
    ) -> WorkspaceFocusSnapshot {
        WorkspaceFocusSnapshot(
            rememberedTiledToken: eligibleFocusCandidate(
                manager: manager,
                token: manager.lastFocusedToken(in: workspaceId),
                workspaceId: workspaceId,
                mode: .tiling
            ),
            firstTiledToken: firstEligibleFocusToken(
                manager: manager,
                workspaceId: workspaceId,
                mode: .tiling
            ),
            rememberedFloatingToken: eligibleFocusCandidate(
                manager: manager,
                token: manager.lastFloatingFocusedToken(in: workspaceId),
                workspaceId: workspaceId,
                mode: .floating
            ),
            firstFloatingToken: firstEligibleFocusToken(
                manager: manager,
                workspaceId: workspaceId,
                mode: .floating
            )
        )
    }

    private static func columnSubjectSnapshot(
        controller: WMController,
        workspaceId: WorkspaceDescriptor.ID?
    ) -> ColumnSubjectSnapshot {
        guard let workspaceId else {
            return ColumnSubjectSnapshot(activeToken: nil, selectedToken: nil)
        }

        return ColumnSubjectSnapshot(
            activeToken: activeColumnSubjectToken(
                controller: controller,
                workspaceId: workspaceId
            ),
            selectedToken: selectedColumnSubjectToken(
                controller: controller,
                workspaceId: workspaceId
            )
        )
    }

    private static func activeColumnSubjectToken(
        controller: WMController,
        workspaceId: WorkspaceDescriptor.ID
    ) -> WindowToken? {
        guard let engine = controller.niriEngine else { return nil }
        let columns = engine.columns(in: workspaceId)
        guard !columns.isEmpty else { return nil }
        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        let clampedIndex = min(max(state.activeColumnIndex, 0), columns.count - 1)
        let column = columns[clampedIndex]
        return column.activeWindow?.token ?? column.windowNodes.first?.token
    }

    private static func selectedColumnSubjectToken(
        controller: WMController,
        workspaceId: WorkspaceDescriptor.ID
    ) -> WindowToken? {
        guard let engine = controller.niriEngine else { return nil }
        let state = controller.workspaceManager.niriViewportState(for: workspaceId)
        guard let selectedNodeId = state.selectedNodeId,
              let node = engine.findNode(by: selectedNodeId) as? NiriWindow
        else {
            return nil
        }
        return node.token
    }

    private static func eligibleFocusCandidate(
        manager: WorkspaceManager,
        token: WindowToken?,
        workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode
    ) -> WindowToken? {
        guard let token,
              let entry = manager.entry(for: token),
              isFocusResolutionEligible(entry, in: workspaceId, mode: mode)
        else {
            return nil
        }
        return token
    }

    private static func firstEligibleFocusToken(
        manager: WorkspaceManager,
        workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode
    ) -> WindowToken? {
        let entries: [WindowModel.Entry]
        switch mode {
        case .tiling:
            entries = manager.tiledEntries(in: workspaceId)
        case .floating:
            entries = manager.floatingEntries(in: workspaceId)
        }
        return entries.first {
            isFocusResolutionEligible($0, in: workspaceId, mode: mode)
        }?.token
    }

    private static func isFocusResolutionEligible(
        _ entry: WindowModel.Entry,
        in workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode
    ) -> Bool {
        guard entry.workspaceId == workspaceId,
              entry.mode == mode
        else {
            return false
        }

        guard entry.hiddenProportionalPosition != nil else {
            return true
        }

        if case .workspaceInactive = entry.hiddenReason {
            return true
        }

        return false
    }

    private static func adjacentFallbackWorkspaceNumber(
        controller: WMController,
        intent: Intent
    ) -> UInt32? {
        guard intent.operation == .moveWindowAdjacent || intent.operation == .moveColumnAdjacent,
              let sourceWorkspaceId = intent.sourceWorkspaceId,
              let currentWorkspaceName = controller.workspaceManager.descriptor(for: sourceWorkspaceId)?.name,
              let currentWorkspaceNumber = WorkspaceIDPolicy.workspaceNumber(from: currentWorkspaceName)
        else {
            return nil
        }

        let candidateNumber = intent.direction == .down
            ? currentWorkspaceNumber + 1
            : currentWorkspaceNumber - 1
        guard let candidateRawID = WorkspaceIDPolicy.rawID(from: candidateNumber) else {
            return nil
        }

        let configuredWorkspaceNames = Set(controller.settings.workspaceConfigurations.map(\.name))
        guard configuredWorkspaceNames.contains(candidateRawID),
              controller.workspaceManager.workspaceId(named: candidateRawID) == nil
        else {
            return nil
        }

        return UInt32(exactly: candidateNumber)
    }

    private static func rawDirection(_ direction: Direction) -> UInt32 {
        switch direction {
        case .left: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_LEFT)
        case .right: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_RIGHT)
        case .up: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_UP)
        case .down: UInt32(OMNIWM_NIRI_TOPOLOGY_DIRECTION_DOWN)
        }
    }

    private static func layoutKind(_ layoutType: LayoutType) -> Input.WorkspaceSnapshot.LayoutKind {
        switch layoutType {
        case .defaultLayout: .defaultLayout
        case .niri: .niri
        case .dwindle: .dwindle
        }
    }

    private static func rawLayoutKind(_ layoutKind: Input.WorkspaceSnapshot.LayoutKind) -> UInt32 {
        switch layoutKind {
        case .defaultLayout: UInt32(OMNIWM_WORKSPACE_NAV_LAYOUT_DEFAULT)
        case .niri: UInt32(OMNIWM_WORKSPACE_NAV_LAYOUT_NIRI)
        case .dwindle: UInt32(OMNIWM_WORKSPACE_NAV_LAYOUT_DWINDLE)
        }
    }

    private static func encode(uuid: UUID) -> omniwm_uuid {
        let bytes = Array(withUnsafeBytes(of: uuid.uuid) { $0 })
        let high = bytes[0 ..< 8].reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
        let low = bytes[8 ..< 16].reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
        return omniwm_uuid(high: high, low: low)
    }

    private static func decode(uuid: omniwm_uuid) -> UUID {
        let b0 = UInt8((uuid.high >> 56) & 0xff)
        let b1 = UInt8((uuid.high >> 48) & 0xff)
        let b2 = UInt8((uuid.high >> 40) & 0xff)
        let b3 = UInt8((uuid.high >> 32) & 0xff)
        let b4 = UInt8((uuid.high >> 24) & 0xff)
        let b5 = UInt8((uuid.high >> 16) & 0xff)
        let b6 = UInt8((uuid.high >> 8) & 0xff)
        let b7 = UInt8(uuid.high & 0xff)
        let b8 = UInt8((uuid.low >> 56) & 0xff)
        let b9 = UInt8((uuid.low >> 48) & 0xff)
        let b10 = UInt8((uuid.low >> 40) & 0xff)
        let b11 = UInt8((uuid.low >> 32) & 0xff)
        let b12 = UInt8((uuid.low >> 24) & 0xff)
        let b13 = UInt8((uuid.low >> 16) & 0xff)
        let b14 = UInt8((uuid.low >> 8) & 0xff)
        let b15 = UInt8(uuid.low & 0xff)
        return UUID(uuid: (b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15))
    }

    private static func zeroUUID() -> omniwm_uuid {
        omniwm_uuid(high: 0, low: 0)
    }

    private static func encode(token: WindowToken) -> omniwm_window_token {
        omniwm_window_token(pid: token.pid, window_id: Int64(token.windowId))
    }

    private static func decode(token: omniwm_window_token) -> WindowToken {
        WindowToken(pid: token.pid, windowId: Int(token.window_id))
    }

    private static func zeroToken() -> omniwm_window_token {
        omniwm_window_token(pid: 0, window_id: 0)
    }
}
