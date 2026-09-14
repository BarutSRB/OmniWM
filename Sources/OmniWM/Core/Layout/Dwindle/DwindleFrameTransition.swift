// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct DwindleFrameTransition {
    let oldFrames: [WindowToken: CGRect]
    let previousTargetFrames: [WindowToken: CGRect]
    let newFrames: [WindowToken: CGRect]
}
