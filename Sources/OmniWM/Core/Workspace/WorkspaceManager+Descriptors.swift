// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    var workspaces: [WorkspaceDescriptor] {
        sortedWorkspaces()
    }

    func descriptor(for id: WorkspaceDescriptor.ID) -> WorkspaceDescriptor? {
        workspaceCatalog.descriptor(for: id)
    }

    func workspaceId(for name: String, createIfMissing: Bool) -> WorkspaceDescriptor.ID? {
        if let existing = workspaceCatalog.workspaceId(named: name) {
            return existing
        }
        guard createIfMissing else { return nil }
        guard configuredWorkspaceNameSet().contains(name) else { return nil }
        return createWorkspace(named: name)
    }

    func workspaceId(named name: String) -> WorkspaceDescriptor.ID? {
        workspaceCatalog.workspaceId(named: name)
    }

    func createDynamicWorkspace(
        named name: String,
        on monitorId: Monitor.ID
    ) -> WorkspaceDescriptor? {
        if let existingId = workspaceCatalog.workspaceId(named: name) {
            return descriptor(for: existingId)
        }
        guard let monitor = monitor(byId: monitorId),
              let workspaceId = createWorkspace(
                  named: name,
                  assignedMonitorPoint: monitor.workspaceAnchorPoint,
                  requiresConfiguration: false
              )
        else {
            return nil
        }
        return descriptor(for: workspaceId)
    }
}
