// SPDX-License-Identifier: GPL-2.0-only
import Foundation

// One platform/effect instruction produced by the authoritative transaction
// path and consumed by `WMEffectRunner`.
//
// Effects are side-effect-only: they do not directly mutate durable WM state
// inside the runtime's state model. State mutations routed into existing
// `WorkspaceManager` APIs are a transitional compatibility step for Phase 01
// Milestone A; later phases narrow the interface further so the transaction
// executor owns the durable projection directly (see
// `docs/RELIABILITY-MIGRATION.md`).
//
// Every effect carries an `EffectEpoch` so the runner can reject confirmations
// that reference a superseded effect. Plans carry the originating
// `TransactionEpoch`; effect epochs are monotonic across plans.
enum WMEffect: Equatable {
    case hideKeyboardFocusBorder(
        reason: String,
        epoch: EffectEpoch
    )
    case saveWorkspaceViewports(
        workspaceIds: [WorkspaceDescriptor.ID],
        epoch: EffectEpoch
    )
    case activateTargetWorkspace(
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID,
        epoch: EffectEpoch
    )
    case setInteractionMonitor(
        monitorId: Monitor.ID,
        epoch: EffectEpoch
    )
    case syncMonitorsToNiri(epoch: EffectEpoch)
    case stopScrollAnimation(
        monitorId: Monitor.ID,
        epoch: EffectEpoch
    )
    case applyWorkspaceSessionPatch(
        workspaceId: WorkspaceDescriptor.ID,
        rememberedFocusToken: WindowToken?,
        epoch: EffectEpoch
    )
    case commitWorkspaceTransition(
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        postAction: PostWorkspaceTransitionAction,
        epoch: EffectEpoch
    )

    // Declarative post-commit follow-up for `.commitWorkspaceTransition`.
    // The runner translates this into the layout-refresh `postLayout`
    // closure so the plan itself remains closure-free and inspectable by
    // transcript tests.
    enum PostWorkspaceTransitionAction: Equatable {
        case none
        case focusWindow(WindowToken)
        case clearManagedFocusAfterEmptyWorkspaceTransition
    }

    var epoch: EffectEpoch {
        switch self {
        case let .hideKeyboardFocusBorder(_, epoch),
             let .saveWorkspaceViewports(_, epoch),
             let .activateTargetWorkspace(_, _, epoch),
             let .setInteractionMonitor(_, epoch),
             let .syncMonitorsToNiri(epoch),
             let .stopScrollAnimation(_, epoch),
             let .applyWorkspaceSessionPatch(_, _, epoch),
             let .commitWorkspaceTransition(_, _, epoch):
            epoch
        }
    }

    var kind: String {
        switch self {
        case .hideKeyboardFocusBorder: "hide_keyboard_focus_border"
        case .saveWorkspaceViewports: "save_workspace_viewports"
        case .activateTargetWorkspace: "activate_target_workspace"
        case .setInteractionMonitor: "set_interaction_monitor"
        case .syncMonitorsToNiri: "sync_monitors_to_niri"
        case .stopScrollAnimation: "stop_scroll_animation"
        case .applyWorkspaceSessionPatch: "apply_workspace_session_patch"
        case .commitWorkspaceTransition: "commit_workspace_transition"
        }
    }
}
