// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct DwindleTraversalPosition {
    let node: DwindleNode
    let rect: CGRect
    let boundaryEdges: ResizeEdge
}

struct DwindleTreeProjection {
    let tilingArea: CGRect
    let excludedTokens: Set<WindowToken>
}

struct DwindleNavigationSearch {
    let current: DwindleNode
    let currentFrame: CGRect
    let direction: Direction
    let innerGap: CGFloat
    let projection: DwindleTreeProjection
}

enum DwindleProjectedBranches {
    case none
    case single(DwindleTraversalPosition)
    case split(DwindleTraversalPosition, DwindleTraversalPosition)
}
