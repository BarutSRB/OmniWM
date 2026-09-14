// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

struct ManagedReplacementCandidateFacts {
    let bundleId: String?
    let mode: TrackedWindowMode
    let facts: WindowRuleFacts
}

struct CapturedWindowServerInventory {
    let infoByWindowId: [Int: WindowServerInfo]
    let authoritativeWindowIds: Set<Int>?
    let authoritativePIDs: Set<pid_t>?

    init(
        infoByWindowId: [Int: WindowServerInfo],
        authoritativeWindowIds: Set<Int>? = nil,
        authoritativePIDs: Set<pid_t>? = nil
    ) {
        self.infoByWindowId = infoByWindowId
        self.authoritativeWindowIds = authoritativeWindowIds
        self.authoritativePIDs = authoritativePIDs
    }
}

extension AXEventHandler {
    enum StructuralReplacementMatchSource {
        case pendingDestroy
        case liveInvisible
    }

    struct StructuralReplacementMatch {
        let token: WindowToken
        let workspaceId: WorkspaceDescriptor.ID
        let source: StructuralReplacementMatchSource
    }
}
