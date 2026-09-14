// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

struct WindowCreatePlacementContext: Equatable {
    let nativeSpaceMonitorId: Monitor.ID?
    let pendingFocusedWorkspaceId: WorkspaceDescriptor.ID?
    let pendingFocusedMonitorId: Monitor.ID?
    let focusedWorkspaceId: WorkspaceDescriptor.ID?
    let focusedMonitorId: Monitor.ID?
    let interactionWorkspaceId: WorkspaceDescriptor.ID?
    let interactionMonitorId: Monitor.ID?
    let createdAt: Date
}
