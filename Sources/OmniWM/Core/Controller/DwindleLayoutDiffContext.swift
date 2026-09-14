// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

struct DwindleLayoutDiffContext {
    let engine: DwindleLayoutEngine
    let workspaceId: WorkspaceDescriptor.ID
    let preferredHideSide: HideSide
    let canRestoreHiddenWorkspaceWindows: Bool
    let scale: CGFloat
    let reassertHidden: Bool
    let pendingParkWindowIds: Set<Int>
    let animationTime: TimeInterval?
}
