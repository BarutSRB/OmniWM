// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
struct FullRescanStartState {
    let seq: UInt64
    let hadNativeFullscreenLifecycleContext: Bool
    let entries: [WindowState]
    let preservingPIDsByWindowId: [Int: pid_t]

    init(controller: WMController) {
        seq = controller.workspaceManager.worldSeq
        hadNativeFullscreenLifecycleContext = controller.workspaceManager.hasNativeFullscreenLifecycleContext
        entries = controller.workspaceManager.allEntries()
        preservingPIDsByWindowId = Dictionary(uniqueKeysWithValues: entries.map { ($0.windowId, $0.pid) })
    }
}
