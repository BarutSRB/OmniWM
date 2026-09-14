// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

@MainActor
struct WorkspaceBarIslandPanel {
    let panel: WorkspaceBarPanel
    let hostingView: NSHostingView<WorkspaceBarView>
    var slice: WorkspaceBarIslandSlice
    var showsSystemStatsButton: Bool
    var lastAppliedFrame: NSRect?

    init(panel: WorkspaceBarPanel, rootView: WorkspaceBarView, resolved: ResolvedBarSettings) {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        let appearance = NSApplication.shared.appearance
        panel.appearance = appearance
        hostingView.appearance = appearance
        panel.level = resolved.windowLevel.nsWindowLevel
        self.panel = panel
        self.hostingView = hostingView
        slice = rootView.slice
        showsSystemStatsButton = rootView.showsSystemStatsButton
        lastAppliedFrame = nil
    }

    mutating func applyFrame(
        _ frame: NSRect,
        using frameApplier: (WorkspaceBarPanel, NSRect) -> Void
    ) {
        guard lastAppliedFrame != frame else { return }
        frameApplier(panel, frame)
        lastAppliedFrame = frame
    }
}
