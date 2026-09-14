// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics

struct NiriViewportGeometry {
    let gap: CGFloat
    let viewportSpan: CGFloat
    let orientation: Monitor.Orientation
    let workingArea: CGRect?
    let viewFrame: CGRect?
    let scale: CGFloat

    init(
        gap: CGFloat,
        viewportSpan: CGFloat,
        orientation: Monitor.Orientation,
        workingArea: CGRect? = nil,
        viewFrame: CGRect? = nil,
        scale: CGFloat = 2.0
    ) {
        self.gap = gap
        self.viewportSpan = viewportSpan
        self.orientation = orientation
        self.workingArea = workingArea
        self.viewFrame = viewFrame
        self.scale = scale
    }
}
