// SPDX-License-Identifier: GPL-2.0-only
import Foundation

struct WorkspaceBarProjectionOptions: Equatable {
    let deduplicateAppIcons: Bool
    let hideEmptyWorkspaces: Bool
    let showFloatingWindows: Bool
}

extension ResolvedBarSettings {
    var projectionOptions: WorkspaceBarProjectionOptions {
        WorkspaceBarProjectionOptions(
            deduplicateAppIcons: deduplicateAppIcons,
            hideEmptyWorkspaces: hideEmptyWorkspaces,
            showFloatingWindows: showFloatingWindows
        )
    }
}
