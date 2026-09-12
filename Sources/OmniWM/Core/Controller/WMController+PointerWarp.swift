// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    func shouldUseMouseWarp(for monitors: [Monitor]? = nil) -> Bool {
        let effectiveMonitors = monitors ?? workspaceManager.monitors
        return effectiveMonitors.count > 1
    }

    func resetMouseWarpTransientState() {
        mouseWarpHandler.resetTransientState()
    }

    func screen(for monitorId: Monitor.ID) -> NSScreen? {
        guard let monitor = workspaceManager.monitor(byId: monitorId) else { return nil }
        return NSScreen.screens.first(where: { $0.displayId == monitor.displayId })
    }

    func moveMouseToWindow(_ handle: WindowHandle, preferredFrame: CGRect? = nil) {
        moveMouseToWindow(handle.id, preferredFrame: preferredFrame)
    }

    func moveMouseToWindow(_ token: WindowToken, preferredFrame: CGRect? = nil) {
        guard !axEventHandler.suppressesMouseWarp(for: token) else {
            MouseTrace.record("focus-warp suppressed (pointer-intent) token=\(token)")
            return
        }
        guard let entry = workspaceManager.entry(for: token) else { return }
        guard let frame = preferredFrame ?? AXWindowService.framePreferFast(entry.axRef) else { return }

        let center = frame.center

        guard NSScreen.screens.contains(where: { $0.frame.contains(center) }) else {
            MouseTrace.record("focus-warp suppressed (off-screen) token=\(token) center=\(TraceFormat.point(center))")
            return
        }

        let mouse = currentMouseLocation()
        guard !frame.contains(mouse) else {
            MouseTrace.record(
                "focus-warp suppressed (cursor-inside) token=\(token) mouse=\(TraceFormat.point(mouse))"
            )
            return
        }

        MouseTrace.record("focus-warp token=\(token) center=\(TraceFormat.point(center))")
        warpMouseCursorPosition(ScreenCoordinateSpace.toWindowServer(point: center))
        mouseWarpHandler.noteProgrammaticCursorMove(to: center)
    }
}
