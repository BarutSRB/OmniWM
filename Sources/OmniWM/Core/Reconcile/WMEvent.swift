import CoreGraphics
import Foundation

enum WMEventSource: String, Equatable {
    case ax
    case workspaceManager
    case service
    case command
    case mouse
    case focusPolicy
}

enum NativeFullscreenLayoutChange: Equatable {
    case suspended(LayoutReason)
    case restored

    var isNativeFullscreenActive: Bool {
        self == .suspended(.nativeFullscreen)
    }
}

enum WMEvent: Equatable {
    case windowAdmitted(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        mode: TrackedWindowMode,
        axRef: AXWindowRef,
        ruleEffects: ManagedWindowRuleEffects,
        managedReplacementMetadata: ManagedReplacementMetadata?,
        source: WMEventSource
    )
    case windowRekeyed(
        from: WindowToken,
        to: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        reason: ReplacementCorrelation.Reason,
        newAXRef: AXWindowRef,
        managedReplacementMetadata: ManagedReplacementMetadata?,
        source: WMEventSource
    )
    case windowRemoved(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID?,
        source: WMEventSource
    )
    case workspaceAssigned(
        token: WindowToken,
        from: WorkspaceDescriptor.ID?,
        to: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        source: WMEventSource
    )
    case windowModeChanged(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        mode: TrackedWindowMode,
        source: WMEventSource
    )
    case floatingGeometryUpdated(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        referenceMonitorId: Monitor.ID?,
        frame: CGRect,
        normalizedOrigin: CGPoint?,
        restoreToFloating: Bool,
        source: WMEventSource
    )
    case floatingStateChanged(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        state: WindowModel.FloatingState?,
        source: WMEventSource
    )
    case manualLayoutOverrideChanged(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        layoutOverride: ManualWindowOverride?,
        source: WMEventSource
    )
    case niriPlacementsResolved(
        placements: [WindowToken: PersistedNiriPlacement],
        source: WMEventSource
    )
    case hiddenStateChanged(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        hiddenState: WindowModel.HiddenState?,
        source: WMEventSource
    )
    case nativeFullscreenTransition(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        change: NativeFullscreenLayoutChange,
        source: WMEventSource
    )
    case managedReplacementMetadataChanged(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        metadata: ManagedReplacementMetadata?,
        source: WMEventSource
    )
    case topologyChanged(
        displays: [DisplayFingerprint],
        source: WMEventSource
    )
    case activeSpaceChanged(source: WMEventSource)
    case focusLeaseChanged(
        lease: FocusPolicyLease?,
        source: WMEventSource
    )
    case managedFocusRequested(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        requestId: UInt64,
        source: WMEventSource
    )
    case managedFocusConfirmed(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        appFullscreen: Bool,
        requestId: UInt64?,
        source: WMEventSource
    )
    case managedFocusCancelled(
        token: WindowToken?,
        workspaceId: WorkspaceDescriptor.ID?,
        requestId: UInt64?,
        source: WMEventSource
    )
    case nonManagedFocusChanged(
        active: Bool,
        appFullscreen: Bool,
        preserveFocusedToken: Bool,
        preservePendingManagedFocus: Bool,
        source: WMEventSource
    )
    case focusRemembered(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode,
        source: WMEventSource
    )
    case focusForgotten(
        workspaceIds: Set<WorkspaceDescriptor.ID>,
        source: WMEventSource
    )
    case nonManagedFocusTargetChanged(
        target: WindowToken?,
        source: WMEventSource
    )
    case suppressedFocusChanged(
        token: WindowToken?,
        source: WMEventSource
    )
    case workspaceFocusCleared(
        workspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource
    )
    case nativeFullscreenPlaceholderSelected(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource
    )
    case interactionMonitorChanged(
        monitorId: Monitor.ID?,
        previousMonitorId: Monitor.ID?,
        source: WMEventSource
    )
    case viewportChanged(
        workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        source: WMEventSource
    )
    case viewportCommitted(
        workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        baseSelectionRevision: UInt64?,
        source: WMEventSource
    )
    case viewportForgotten(
        workspaceIds: Set<WorkspaceDescriptor.ID>,
        source: WMEventSource
    )
    case selectionChanged(
        workspaceId: WorkspaceDescriptor.ID,
        nodeId: NodeId,
        source: WMEventSource
    )
    case scratchpadChanged(
        token: WindowToken?,
        source: WMEventSource
    )
    case systemSleep(source: WMEventSource)
    case systemWake(source: WMEventSource)

    var token: WindowToken? {
        switch self {
        case let .windowAdmitted(token, _, _, _, _, _, _, _),
             let .windowRemoved(token, _, _),
             let .workspaceAssigned(token, _, _, _, _),
             let .windowModeChanged(token, _, _, _, _),
             let .floatingGeometryUpdated(token, _, _, _, _, _, _),
             let .floatingStateChanged(token, _, _, _),
             let .manualLayoutOverrideChanged(token, _, _, _),
             let .hiddenStateChanged(token, _, _, _, _),
             let .nativeFullscreenTransition(token, _, _, _, _),
             let .managedReplacementMetadataChanged(token, _, _, _, _),
             let .managedFocusRequested(token, _, _, _, _),
             let .managedFocusConfirmed(token, _, _, _, _, _):
            token
        case let .windowRekeyed(_, to, _, _, _, _, _, _):
            to
        case let .managedFocusCancelled(token, _, _, _):
            token
        case .activeSpaceChanged,
             .focusForgotten,
             .focusLeaseChanged,
             .focusRemembered,
             .interactionMonitorChanged,
             .nativeFullscreenPlaceholderSelected,
             .niriPlacementsResolved,
             .nonManagedFocusChanged,
             .nonManagedFocusTargetChanged,
             .scratchpadChanged,
             .selectionChanged,
             .suppressedFocusChanged,
             .systemSleep,
             .systemWake,
             .topologyChanged,
             .viewportChanged,
             .viewportCommitted,
             .viewportForgotten,
             .workspaceFocusCleared:
            nil
        }
    }

    var source: WMEventSource {
        switch self {
        case let .windowAdmitted(_, _, _, _, _, _, _, source),
             let .windowRekeyed(_, _, _, _, _, _, _, source),
             let .windowRemoved(_, _, source),
             let .workspaceAssigned(_, _, _, _, source),
             let .windowModeChanged(_, _, _, _, source),
             let .floatingGeometryUpdated(_, _, _, _, _, _, source),
             let .floatingStateChanged(_, _, _, source),
             let .manualLayoutOverrideChanged(_, _, _, source),
             let .niriPlacementsResolved(_, source),
             let .hiddenStateChanged(_, _, _, _, source),
             let .nativeFullscreenTransition(_, _, _, _, source),
             let .managedReplacementMetadataChanged(_, _, _, _, source),
             let .topologyChanged(_, source),
             let .activeSpaceChanged(source),
             let .focusLeaseChanged(_, source),
             let .managedFocusRequested(_, _, _, _, source),
             let .managedFocusConfirmed(_, _, _, _, _, source),
             let .managedFocusCancelled(_, _, _, source),
             let .nonManagedFocusChanged(_, _, _, _, source),
             let .focusRemembered(_, _, _, source),
             let .focusForgotten(_, source),
             let .nonManagedFocusTargetChanged(_, source),
             let .suppressedFocusChanged(_, source),
             let .workspaceFocusCleared(_, source),
             let .nativeFullscreenPlaceholderSelected(_, _, source),
             let .interactionMonitorChanged(_, _, source),
             let .viewportChanged(_, _, source),
             let .viewportCommitted(_, _, _, source),
             let .viewportForgotten(_, source),
             let .selectionChanged(_, _, source),
             let .scratchpadChanged(_, source),
             let .systemSleep(source),
             let .systemWake(source):
            source
        }
    }

    var summary: String {
        switch self {
        case let .windowAdmitted(token, workspaceId, _, mode, _, _, _, _):
            "window_admitted token=\(token) workspace=\(workspaceId.uuidString) mode=\(mode)"
        case let .windowRekeyed(from, to, workspaceId, _, reason, _, _, _):
            "window_rekeyed from=\(from) to=\(to) workspace=\(workspaceId.uuidString) reason=\(reason.rawValue)"
        case let .windowRemoved(token, workspaceId, _):
            "window_removed token=\(token) workspace=\(workspaceId?.uuidString ?? "nil")"
        case let .workspaceAssigned(token, from, to, _, _):
            "workspace_assigned token=\(token) from=\(from?.uuidString ?? "nil") to=\(to.uuidString)"
        case let .windowModeChanged(token, workspaceId, _, mode, _):
            "window_mode_changed token=\(token) workspace=\(workspaceId.uuidString) mode=\(mode)"
        case let .floatingGeometryUpdated(token, workspaceId, _, frame, _, restoreToFloating, _):
            "floating_geometry_updated token=\(token) workspace=\(workspaceId.uuidString) frame=\(frame.debugDescription) restore=\(restoreToFloating)"
        case let .floatingStateChanged(token, workspaceId, state, _):
            "floating_state_changed token=\(token) workspace=\(workspaceId.uuidString) state=\(state != nil)"
        case let .manualLayoutOverrideChanged(token, workspaceId, layoutOverride, _):
            "manual_layout_override_changed token=\(token) workspace=\(workspaceId.uuidString) override=\(layoutOverride.map(\.rawValue) ?? "nil")"
        case let .niriPlacementsResolved(placements, _):
            "niri_placements_resolved count=\(placements.count)"
        case let .hiddenStateChanged(token, workspaceId, _, hiddenState, _):
            "hidden_state_changed token=\(token) workspace=\(workspaceId.uuidString) hidden=\(hiddenState != nil)"
        case let .nativeFullscreenTransition(token, workspaceId, _, change, _):
            "native_fullscreen token=\(token) workspace=\(workspaceId.uuidString) active=\(change.isNativeFullscreenActive)"
        case let .managedReplacementMetadataChanged(token, workspaceId, monitorId, _, _):
            "managed_replacement_metadata_changed token=\(token) workspace=\(workspaceId.uuidString) monitor=\(String(describing: monitorId))"
        case let .topologyChanged(displays, _):
            "topology_changed displays=\(displays.count)"
        case .activeSpaceChanged:
            "active_space_changed"
        case let .focusLeaseChanged(lease, _):
            "focus_lease_changed owner=\(lease?.owner.rawValue ?? "nil") reason=\(lease?.reason ?? "")"
        case let .managedFocusRequested(token, workspaceId, monitorId, requestId, _):
            "managed_focus_requested token=\(token) workspace=\(workspaceId.uuidString) monitor=\(String(describing: monitorId)) request=\(requestId)"
        case let .managedFocusConfirmed(token, workspaceId, monitorId, appFullscreen, requestId, _):
            "managed_focus_confirmed token=\(token) workspace=\(workspaceId.uuidString) monitor=\(String(describing: monitorId)) fullscreen=\(appFullscreen) request=\(requestId.map { String($0) } ?? "nil")"
        case let .managedFocusCancelled(token, workspaceId, requestId, _):
            "managed_focus_cancelled token=\(token.map(String.init(describing:)) ?? "nil") workspace=\(workspaceId?.uuidString ?? "nil") request=\(requestId.map { String($0) } ?? "nil")"
        case let .nonManagedFocusChanged(active, appFullscreen, preserveFocusedToken, preservePendingManagedFocus, _):
            "non_managed_focus_changed active=\(active) fullscreen=\(appFullscreen) preserve=\(preserveFocusedToken) preserve_pending=\(preservePendingManagedFocus)"
        case let .focusRemembered(token, workspaceId, mode, _):
            "focus_remembered token=\(token) workspace=\(workspaceId.uuidString) mode=\(mode)"
        case let .focusForgotten(workspaceIds, _):
            "focus_forgotten workspaces=\(workspaceIds.count)"
        case let .nonManagedFocusTargetChanged(target, _):
            "non_managed_focus_target_changed target=\(target.map(String.init(describing:)) ?? "nil")"
        case let .suppressedFocusChanged(token, _):
            "suppressed_focus_changed token=\(token.map(String.init(describing:)) ?? "nil")"
        case let .workspaceFocusCleared(workspaceId, _):
            "workspace_focus_cleared workspace=\(workspaceId.uuidString)"
        case let .nativeFullscreenPlaceholderSelected(token, workspaceId, _):
            "native_fullscreen_placeholder_selected token=\(token) workspace=\(workspaceId.uuidString)"
        case let .interactionMonitorChanged(monitorId, previousMonitorId, _):
            "interaction_monitor_changed monitor=\(String(describing: monitorId)) previous=\(String(describing: previousMonitorId))"
        case let .viewportChanged(workspaceId, state, _):
            "viewport_changed workspace=\(workspaceId.uuidString) selected=\(state.selectedNodeId.map(String.init(describing:)) ?? "nil") column=\(state.activeColumnIndex) target=\(state.viewOffsetPixels.target())"
        case let .viewportCommitted(workspaceId, state, baseSelectionRevision, _):
            "viewport_committed workspace=\(workspaceId.uuidString) selected=\(state.selectedNodeId.map(String.init(describing:)) ?? "nil") column=\(state.activeColumnIndex) base_revision=\(baseSelectionRevision.map { String($0) } ?? "nil")"
        case let .viewportForgotten(workspaceIds, _):
            "viewport_forgotten workspaces=\(workspaceIds.count)"
        case let .selectionChanged(workspaceId, nodeId, _):
            "selection_changed workspace=\(workspaceId.uuidString) node=\(nodeId)"
        case let .scratchpadChanged(token, _):
            "scratchpad_changed token=\(token.map(String.init(describing:)) ?? "nil")"
        case .systemSleep:
            "system_sleep"
        case .systemWake:
            "system_wake"
        }
    }
}
