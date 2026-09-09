// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

struct NiriInteractionContext {
    let workspaceId: WorkspaceDescriptor.ID
    let motion: MotionSnapshot
    let workingFrame: CGRect
    let gaps: CGFloat
    let orientation: Monitor.Orientation
}
