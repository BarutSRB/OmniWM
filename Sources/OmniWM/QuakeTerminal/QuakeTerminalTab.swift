// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

@MainActor
struct QuakeTerminalTab: Identifiable {
    let id = UUID()
    let splitContainer: QuakeSplitContainer
    var title: String = "Terminal"

    var focusedSurfaceView: GhosttySurfaceView? {
        splitContainer.focusedView
    }
}
