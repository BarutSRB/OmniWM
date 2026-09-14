// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

struct NiriInteractionContext {
    let workspaceId: WorkspaceDescriptor.ID
    let motion: MotionSnapshot
    let workingFrame: CGRect
    let gaps: CGFloat
    let orientation: Monitor.Orientation

    var sizingGeometry: NiriSizingGeometry {
        NiriSizingGeometry(workingFrame: workingFrame, gaps: gaps, orientation: orientation)
    }

    func oriented(_ orientation: Monitor.Orientation) -> NiriInteractionContext {
        NiriInteractionContext(
            workspaceId: workspaceId,
            motion: motion,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation
        )
    }
}

struct NiriWorkspaceDestination {
    let workspaceId: WorkspaceDescriptor.ID
    let orientation: Monitor.Orientation
}
