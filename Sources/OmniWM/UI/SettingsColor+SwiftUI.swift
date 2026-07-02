// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

extension SettingsColor {
    init?(color: Color, preservesAlpha: Bool = true) {
        self.init(nsColor: NSColor(color), preservesAlpha: preservesAlpha)
    }

    init?(nsColor: NSColor, preservesAlpha: Bool = true) {
        guard let converted = nsColor.usingColorSpace(.deviceRGB) else { return nil }
        self.init(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent),
            alpha: preservesAlpha ? Double(converted.alphaComponent) : 1
        )
    }

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}
