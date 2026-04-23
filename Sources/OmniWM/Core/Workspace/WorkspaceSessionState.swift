// SPDX-License-Identifier: GPL-2.0-only
import Foundation

struct WorkspaceSessionState {
    struct MonitorSession: Equatable {
        var visibleWorkspaceId: WorkspaceDescriptor.ID?
        var previousVisibleWorkspaceId: WorkspaceDescriptor.ID?
    }

    struct WorkspaceSession {
        var niriViewportState: ViewportState?
    }

    struct FocusSession {
        struct PendingManagedFocusRequest {
            var token: WindowToken?
            var workspaceId: WorkspaceDescriptor.ID?
            var monitorId: Monitor.ID?
        }

        var focusedToken: WindowToken?
        var pendingManagedFocus = PendingManagedFocusRequest()
        var lastTiledFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowToken] = [:]
        var lastFloatingFocusedByWorkspace: [WorkspaceDescriptor.ID: WindowToken] = [:]
        var focusLease: FocusPolicyLease?
        var isNonManagedFocusActive = false
        var isAppFullscreenActive = false
    }

    var interactionMonitorId: Monitor.ID?
    var previousInteractionMonitorId: Monitor.ID?
    var monitorSessions: [Monitor.ID: MonitorSession] = [:]
    var workspaceSessions: [WorkspaceDescriptor.ID: WorkspaceSession] = [:]
    var scratchpadToken: WindowToken?
    var focus = FocusSession()
}
