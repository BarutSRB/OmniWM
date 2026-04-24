// SPDX-License-Identifier: GPL-2.0-only
import Foundation

// Handler-originated command submitted into the authoritative transaction
// path via `WMRuntime.submit(command:)`. Distinct from observation-flavored
// `WMEvent` cases, which describe things the OS has already reported.
//
// Commands are translated by the runtime into a transaction record plus a
// `WMEffectPlan`. The runtime's effect runner applies the plan in order,
// stamped with the transaction's epoch.
//
// Only subsystems that have been migrated to the transaction entrypoint
// should construct `WMCommand` values. Phase 01 Milestone A scope:
// workspace-switch paths only (see `docs/RELIABILITY-MIGRATION.md`).
enum WMCommand: Equatable {
    case workspaceSwitch(WorkspaceSwitchCommand)
}

extension WMCommand {
    enum WorkspaceSwitchCommand: Equatable {
        // Explicit switch by raw workspace identifier (e.g. "1", "2", ...).
        case explicit(rawWorkspaceID: String)
        // Relative switch along the workspace ordering.
        case relative(isNext: Bool, wrapAround: Bool)
    }
}

extension WMCommand {
    var summary: String {
        switch self {
        case let .workspaceSwitch(.explicit(rawId)):
            "workspace_switch_explicit raw=\(rawId)"
        case let .workspaceSwitch(.relative(isNext, wrapAround)):
            "workspace_switch_relative next=\(isNext) wrap=\(wrapAround)"
        }
    }
}
