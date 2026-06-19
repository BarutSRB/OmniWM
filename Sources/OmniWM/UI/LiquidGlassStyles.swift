// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import SwiftUI

struct GlassButtonStyle: ButtonStyle {
    var isProminent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .omniGlassEffect(in: Capsule(), prominent: isProminent)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static var glass: GlassButtonStyle {
        GlassButtonStyle()
    }

    static var glassProminent: GlassButtonStyle {
        GlassButtonStyle(isProminent: true)
    }
}
