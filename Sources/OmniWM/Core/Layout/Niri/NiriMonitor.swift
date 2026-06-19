// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreGraphics
import Foundation

final class NiriMonitor {
    let id: Monitor.ID

    let displayId: CGDirectDisplayID

    let outputName: String

    private(set) var frame: CGRect

    private(set) var visibleFrame: CGRect

    private(set) var scale: CGFloat

    private(set) var refreshRate: Double

    private(set) var orientation: Monitor.Orientation = .horizontal

    var workspaceRoots: [WorkspaceDescriptor.ID: NiriRoot] = [:]

    var resolvedSettings: ResolvedNiriSettings?

    var workspaceCount: Int {
        workspaceRoots.count
    }

    var hasWorkspaces: Bool {
        !workspaceRoots.isEmpty
    }

    init(monitor: Monitor, orientation: Monitor.Orientation? = nil) {
        id = monitor.id
        displayId = monitor.displayId
        outputName = monitor.name
        frame = monitor.frame
        visibleFrame = monitor.visibleFrame
        self.orientation = orientation ?? monitor.autoOrientation

        if let screen = NSScreen.screens.first(where: { $0.displayId == monitor.displayId }) {
            scale = screen.backingScaleFactor
        } else {
            scale = 2.0
        }
        refreshRate = Monitor.refreshRate(for: monitor.displayId)
    }

    func updateOutputSize(monitor: Monitor, orientation: Monitor.Orientation? = nil) {
        frame = monitor.frame
        visibleFrame = monitor.visibleFrame
        if let orientation {
            self.orientation = orientation
        }

        if let screen = NSScreen.screens.first(where: { $0.displayId == monitor.displayId }) {
            scale = screen.backingScaleFactor
        }
        refreshRate = Monitor.refreshRate(for: monitor.displayId)
    }

    func updateOrientation(_ orientation: Monitor.Orientation) {
        self.orientation = orientation
    }
}

extension NiriMonitor {
    func root(for workspaceId: WorkspaceDescriptor.ID) -> NiriRoot? {
        workspaceRoots[workspaceId]
    }

    func ensureRoot(for workspaceId: WorkspaceDescriptor.ID) -> NiriRoot {
        if let existing = workspaceRoots[workspaceId] {
            return existing
        }

        let root = NiriRoot(workspaceId: workspaceId)
        workspaceRoots[workspaceId] = root
        return root
    }

    func containsWorkspace(_ workspaceId: WorkspaceDescriptor.ID) -> Bool {
        workspaceRoots[workspaceId] != nil
    }
}
