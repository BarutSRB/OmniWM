// SPDX-License-Identifier: GPL-2.0-only
import Foundation

@testable import OmniWM

// In-memory `WMEffectPlatform` used by transaction/effect-runner tests
// and the early replay runner. Records every invocation as a typed event
// so assertions can describe the expected effect sequence without
// depending on live controller state.
@MainActor
final class RecordingEffectPlatform: WMEffectPlatform {
    enum Event: Equatable {
        case hideKeyboardFocusBorder(reason: String)
        case saveWorkspaceViewport(workspaceId: WorkspaceDescriptor.ID)
        case activateTargetWorkspace(
            workspaceId: WorkspaceDescriptor.ID,
            monitorId: Monitor.ID
        )
        case setInteractionMonitor(monitorId: Monitor.ID)
        case syncMonitorsToNiri
        case stopScrollAnimation(monitorId: Monitor.ID)
        case applyWorkspaceSessionPatch(
            workspaceId: WorkspaceDescriptor.ID,
            rememberedFocusToken: WindowToken?
        )
        case commitWorkspaceTransition(
            affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>
        )
        case focusWindow(token: WindowToken)
        case clearManagedFocusAfterEmptyWorkspaceTransition
    }

    private(set) var events: [Event] = []

    // Controls the `activateTargetWorkspace` return value. Defaults to
    // success.
    var activateTargetWorkspaceResult: Bool = true

    // When true (default) the platform calls the post-layout closure
    // synchronously at the end of `commitWorkspaceTransition`. Tests
    // wanting to simulate asynchronous/out-of-order post-layout
    // delivery can set this to false and invoke `runPendingPostActions`
    // themselves.
    var synchronousPostActions: Bool = true
    private var pendingPostActions: [@MainActor () -> Void] = []

    func hideKeyboardFocusBorder(reason: String) {
        events.append(.hideKeyboardFocusBorder(reason: reason))
    }

    func saveWorkspaceViewport(for workspaceId: WorkspaceDescriptor.ID) {
        events.append(.saveWorkspaceViewport(workspaceId: workspaceId))
    }

    @discardableResult
    func activateTargetWorkspace(
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID
    ) -> Bool {
        events.append(.activateTargetWorkspace(
            workspaceId: workspaceId,
            monitorId: monitorId
        ))
        return activateTargetWorkspaceResult
    }

    func setInteractionMonitor(monitorId: Monitor.ID) {
        events.append(.setInteractionMonitor(monitorId: monitorId))
    }

    func syncMonitorsToNiri() {
        events.append(.syncMonitorsToNiri)
    }

    func stopScrollAnimation(monitorId: Monitor.ID) {
        events.append(.stopScrollAnimation(monitorId: monitorId))
    }

    func applyWorkspaceSessionPatch(
        workspaceId: WorkspaceDescriptor.ID,
        rememberedFocusToken: WindowToken?
    ) {
        events.append(.applyWorkspaceSessionPatch(
            workspaceId: workspaceId,
            rememberedFocusToken: rememberedFocusToken
        ))
    }

    func commitWorkspaceTransition(
        affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        postAction: @escaping @MainActor () -> Void
    ) {
        events.append(.commitWorkspaceTransition(
            affectedWorkspaceIds: affectedWorkspaceIds
        ))
        if synchronousPostActions {
            postAction()
        } else {
            pendingPostActions.append(postAction)
        }
    }

    func focusWindow(_ token: WindowToken) {
        events.append(.focusWindow(token: token))
    }

    func clearManagedFocusAfterEmptyWorkspaceTransition() {
        events.append(.clearManagedFocusAfterEmptyWorkspaceTransition)
    }

    // Drain and execute any post-layout closures queued when
    // `synchronousPostActions` was false. Closures execute in insertion
    // order to match the real `LayoutRefreshController` post-layout
    // delivery order.
    func runPendingPostActions() {
        let drained = pendingPostActions
        pendingPostActions.removeAll(keepingCapacity: true)
        for action in drained {
            action()
        }
    }

    var pendingPostActionCount: Int { pendingPostActions.count }
}
