// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct WorkspaceBarProjectionOptions: Equatable {
    let deduplicateAppIcons: Bool
    let hideEmptyWorkspaces: Bool
    let showFloatingWindows: Bool
    let excludedBundleIDs: Set<String>

    func excludes(bundleId: String?) -> Bool {
        guard !excludedBundleIDs.isEmpty, let bundleId else { return false }
        if excludedBundleIDs.contains(bundleId) { return true }
        return excludedBundleIDs.contains {
            $0.caseInsensitiveCompare(bundleId) == .orderedSame
        }
    }
}

extension ResolvedBarSettings {
    var projectionOptions: WorkspaceBarProjectionOptions {
        WorkspaceBarProjectionOptions(
            deduplicateAppIcons: deduplicateAppIcons,
            hideEmptyWorkspaces: hideEmptyWorkspaces,
            showFloatingWindows: showFloatingWindows,
            excludedBundleIDs: excludedBundleIDs
        )
    }
}
