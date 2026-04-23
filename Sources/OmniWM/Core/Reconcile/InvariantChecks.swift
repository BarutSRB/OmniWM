// SPDX-License-Identifier: GPL-2.0-only
import Foundation

enum InvariantChecks {
    static func validate(snapshot: ReconcileSnapshot) -> [ReconcileInvariantViolation] {
        var violations: [ReconcileInvariantViolation] = []
        let liveTokens = Set(snapshot.windows.map(\.token))
        let liveMonitorIds = Set(snapshot.topologyProfile.displays.map { Monitor.ID(displayId: $0.displayId) })

        if let focusedToken = snapshot.focusedToken,
           !liveTokens.contains(focusedToken)
        {
            violations.append(
                .init(
                    code: "focused_token_missing",
                    message: "Focused token \(focusedToken) is missing from the runtime snapshot."
                )
            )
        }

        for window in snapshot.windows {
            if let observedWorkspaceId = window.observedState.workspaceId,
               observedWorkspaceId != window.workspaceId
            {
                violations.append(
                    .init(
                        code: "observed_workspace_mismatch",
                        message: "Observed workspace \(observedWorkspaceId.uuidString) does not match entry workspace \(window.workspaceId.uuidString) for \(window.token)."
                    )
                )
            }

            if let desiredWorkspaceId = window.desiredState.workspaceId,
               desiredWorkspaceId != window.workspaceId
            {
                violations.append(
                    .init(
                        code: "desired_workspace_mismatch",
                        message: "Desired workspace \(desiredWorkspaceId.uuidString) does not match entry workspace \(window.workspaceId.uuidString) for \(window.token)."
                    )
                )
            }

            if let restoreIntent = window.restoreIntent,
               restoreIntent.workspaceId != window.workspaceId
            {
                violations.append(
                    .init(
                        code: "restore_workspace_mismatch",
                        message: "Restore intent workspace \(restoreIntent.workspaceId.uuidString) does not match entry workspace \(window.workspaceId.uuidString) for \(window.token)."
                    )
                )
            }

            if let observedMonitorId = window.observedState.monitorId,
               !liveMonitorIds.contains(observedMonitorId)
            {
                violations.append(
                    .init(
                        code: "observed_monitor_missing",
                        message: "Observed monitor \(observedMonitorId) is missing from the topology for \(window.token)."
                    )
                )
            }

            if let desiredMonitorId = window.desiredState.monitorId,
               !liveMonitorIds.contains(desiredMonitorId)
            {
                violations.append(
                    .init(
                        code: "desired_monitor_missing",
                        message: "Desired monitor \(desiredMonitorId) is missing from the topology for \(window.token)."
                    )
                )
            }

            if let desiredDisposition = window.desiredState.disposition,
               desiredDisposition != window.mode,
               window.lifecyclePhase != .restoring,
               window.lifecyclePhase != .replacing,
               window.lifecyclePhase != .destroyed
            {
                violations.append(
                    .init(
                        code: "desired_mode_mismatch",
                        message: "Desired mode \(desiredDisposition) does not match entry mode \(window.mode) for \(window.token)."
                    )
                )
            }

            switch window.lifecyclePhase {
            case .floating where window.mode != .floating:
                violations.append(
                    .init(
                        code: "floating_phase_mode_mismatch",
                        message: "Floating lifecycle phase must carry floating mode for \(window.token)."
                    )
                )
            case .tiled where window.mode != .tiling:
                violations.append(
                    .init(
                        code: "tiled_phase_mode_mismatch",
                        message: "Tiled lifecycle phase must carry tiling mode for \(window.token)."
                    )
                )
            case .destroyed where snapshot.focusedToken == window.token:
                violations.append(
                    .init(
                        code: "destroyed_window_focused",
                        message: "Destroyed window \(window.token) is still marked focused."
                    )
                )
            default:
                break
            }
        }

        return violations
    }
}
