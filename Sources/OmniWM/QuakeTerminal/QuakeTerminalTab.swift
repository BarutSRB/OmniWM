// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import GhosttyKit

@MainActor
struct QuakeTerminalTab: Identifiable {
    let id = UUID()
    let splitContainer: QuakeSplitContainer
    var title: String = "Terminal"

    var focusedSurface: ghostty_surface_t? {
        splitContainer.focusedView?.ghosttySurface
    }

    var focusedSurfaceView: GhosttySurfaceView? {
        splitContainer.focusedView
    }

    func allSurfaces() -> [(ghostty_surface_t, GhosttySurfaceView)] {
        splitContainer.allSurfaceViews().compactMap { view in
            guard let surface = view.ghosttySurface else { return nil }
            return (surface, view)
        }
    }
}
