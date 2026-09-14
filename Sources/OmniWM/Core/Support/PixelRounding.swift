// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension CGFloat {
    func roundedToPhysicalPixel(scale: CGFloat) -> CGFloat {
        (self * scale).rounded() / scale
    }
}

extension CGPoint {
    func roundedToPhysicalPixels(scale: CGFloat) -> CGPoint {
        CGPoint(
            x: x.roundedToPhysicalPixel(scale: scale),
            y: y.roundedToPhysicalPixel(scale: scale)
        )
    }
}

extension CGSize {
    func roundedToPhysicalPixels(scale: CGFloat) -> CGSize {
        CGSize(
            width: width.roundedToPhysicalPixel(scale: scale),
            height: height.roundedToPhysicalPixel(scale: scale)
        )
    }
}

extension CGRect {
    func roundedToPhysicalPixels(scale: CGFloat) -> CGRect {
        CGRect(
            origin: origin.roundedToPhysicalPixels(scale: scale),
            size: size.roundedToPhysicalPixels(scale: scale)
        )
    }
}
