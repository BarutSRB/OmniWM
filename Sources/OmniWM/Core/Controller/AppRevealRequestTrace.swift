// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
struct AppRevealRequestTrace {
    let handle: WindowHandle
    let destination: AppRevealFocusDestination

    func reject(
        _ reason: AppVisibilityTrace.Reason,
        workspaceId: WorkspaceDescriptor.ID? = nil,
        generation: UInt64? = nil
    ) -> Bool {
        AppVisibilityTrace.record(
            .reveal,
            pid: handle.id.pid,
            outcome: .rejected,
            windowId: handle.id.windowId,
            workspaceId: workspaceId,
            generation: generation,
            destination: destination.traceDestination,
            reason: reason
        )
        return false
    }
}
