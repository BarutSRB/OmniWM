// SPDX-License-Identifier: GPL-2.0-only
import CoreGraphics
import Foundation

enum WindowLifecyclePhase: String, Codable, Equatable {
    case discovered
    case admitted
    case tiled
    case floating
    case hidden
    case offscreen
    case restoring
    case replacing
    case nativeFullscreen
    case destroyed
}

struct ObservedWindowState: Equatable {
    var frame: CGRect?
    var workspaceId: WorkspaceDescriptor.ID?
    var monitorId: Monitor.ID?
    var isVisible: Bool
    var isFocused: Bool
    var hasAXReference: Bool
    var isNativeFullscreen: Bool

    static func initial(
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?
    ) -> ObservedWindowState {
        ObservedWindowState(
            frame: nil,
            workspaceId: workspaceId,
            monitorId: monitorId,
            isVisible: true,
            isFocused: false,
            hasAXReference: true,
            isNativeFullscreen: false
        )
    }
}

struct DesiredWindowState: Equatable {
    var workspaceId: WorkspaceDescriptor.ID?
    var monitorId: Monitor.ID?
    var disposition: TrackedWindowMode?
    var floatingFrame: CGRect?
    var rescueEligible: Bool

    static func initial(
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        disposition: TrackedWindowMode
    ) -> DesiredWindowState {
        DesiredWindowState(
            workspaceId: workspaceId,
            monitorId: monitorId,
            disposition: disposition,
            floatingFrame: nil,
            rescueEligible: disposition == .floating
        )
    }

    var summary: String {
        var parts: [String] = []
        if let workspaceId {
            parts.append("workspace=\(workspaceId.uuidString)")
        }
        if let disposition {
            parts.append("mode=\(disposition)")
        }
        if rescueEligible {
            parts.append("rescue=true")
        }
        return parts.joined(separator: ",")
    }
}

struct DisplayFingerprint: Hashable, Equatable, Codable {
    let displayId: CGDirectDisplayID
    let name: String
    let anchorPoint: CGPoint
    let frameSize: CGSize

    init(monitor: Monitor) {
        displayId = monitor.displayId
        name = monitor.name
        anchorPoint = monitor.workspaceAnchorPoint
        frameSize = monitor.frame.size
    }
}

struct TopologyProfile: Hashable, Equatable, Codable {
    let displays: [DisplayFingerprint]

    init(monitors: [Monitor]) {
        displays = Monitor.sortedByPosition(monitors).map(DisplayFingerprint.init)
    }
}

struct RestoreIntent: Equatable {
    let topologyProfile: TopologyProfile
    var workspaceId: WorkspaceDescriptor.ID
    var preferredMonitor: DisplayFingerprint?
    var floatingFrame: CGRect?
    var normalizedFloatingOrigin: CGPoint?
    var restoreToFloating: Bool
    var rescueEligible: Bool
}

struct ReplacementCorrelation: Equatable {
    enum Reason: String, Equatable {
        case managedReplacement
        case nativeFullscreen
        case manualRekey
    }

    var previousToken: WindowToken?
    var nextToken: WindowToken?
    var reason: Reason
    var recordedAt: Date
}

struct PendingManagedFocusSnapshot: Equatable {
    var token: WindowToken?
    var workspaceId: WorkspaceDescriptor.ID?
    var monitorId: Monitor.ID?

    static let empty = PendingManagedFocusSnapshot(
        token: nil,
        workspaceId: nil,
        monitorId: nil
    )
}

struct FocusSessionSnapshot: Equatable {
    var focusedToken: WindowToken?
    var pendingManagedFocus: PendingManagedFocusSnapshot
    var focusLease: FocusPolicyLease?
    var isNonManagedFocusActive: Bool
    var isAppFullscreenActive: Bool
    var interactionMonitorId: Monitor.ID?
    var previousInteractionMonitorId: Monitor.ID?
}

struct ReconcileWindowSnapshot: Equatable {
    let token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let mode: TrackedWindowMode
    let lifecyclePhase: WindowLifecyclePhase
    let observedState: ObservedWindowState
    let desiredState: DesiredWindowState
    let restoreIntent: RestoreIntent?
    let replacementCorrelation: ReplacementCorrelation?
}

struct ReconcileSnapshot: Equatable {
    let topologyProfile: TopologyProfile
    let focusSession: FocusSessionSnapshot
    let windows: [ReconcileWindowSnapshot]

    var focusedToken: WindowToken? { focusSession.focusedToken }
    var interactionMonitorId: Monitor.ID? { focusSession.interactionMonitorId }
    var previousInteractionMonitorId: Monitor.ID? { focusSession.previousInteractionMonitorId }
}
