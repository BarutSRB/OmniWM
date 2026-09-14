// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

struct FullRescanMutationContext {
    let controller: WMController
    let enumerationSnapshot: AXManager.FullRescanEnumerationSnapshot
    let scope: RescanScope
    let focusedWorkspaceId: WorkspaceDescriptor.ID?
    let screenFrames: [CGRect]
}

struct FullRescanProgress {
    var affectedWorkspaceIds: Set<WorkspaceDescriptor.ID>
    var observedTopLevelInventoryTokens: Set<WindowToken> = []
    var seenKeys: Set<WindowToken> = []
    var decisionBasedRemovals: [WindowToken] = []
}
