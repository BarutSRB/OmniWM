// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import OmniWMIPC

@MainActor
enum IPCQuerySelection {
    static func matchesWorkspaceSelector(
        workspaceId: WorkspaceDescriptor.ID,
        candidate: String,
        controller: WMController
    ) -> Bool {
        guard let descriptor = controller.workspaceManager.descriptor(for: workspaceId) else { return false }
        if descriptor.id.uuidString == candidate {
            return true
        }
        if descriptor.name.localizedCaseInsensitiveCompare(candidate) == .orderedSame {
            return true
        }
        let displayName = controller.settings.workspaces.displayName(for: descriptor.name)
        return displayName.localizedCaseInsensitiveCompare(candidate) == .orderedSame
    }

    static func matchesDisplaySelector(monitor: Monitor?, candidate: String) -> Bool {
        guard let monitor else { return false }
        if IPCDisplayRef.identifier(monitor.id) == candidate {
            return true
        }
        if String(monitor.id.displayId) == candidate {
            return true
        }
        return monitor.name.localizedCaseInsensitiveCompare(candidate) == .orderedSame
    }

    static func requestedFieldSet(from request: IPCQueryRequest) -> Set<String>? {
        guard !request.fields.isEmpty else { return nil }
        return Set(request.fields)
    }

    static func include(_ field: String, in fields: Set<String>?) -> Bool {
        guard let fields else { return true }
        return fields.contains(field)
    }

    static func orderedWorkspaces(controller: WMController) -> [WorkspaceDescriptor] {
        let orderedMonitors = Monitor.sortedByPosition(controller.workspaceManager.monitors)
        var orderedWorkspaces: [WorkspaceDescriptor] = []
        var seenWorkspaceIds: Set<WorkspaceDescriptor.ID> = []

        for monitor in orderedMonitors {
            for workspace in controller.workspaceManager.workspaces(on: monitor.id) {
                guard seenWorkspaceIds.insert(workspace.id).inserted else { continue }
                orderedWorkspaces.append(workspace)
            }
        }

        for workspace in controller.workspaceManager.workspaces where seenWorkspaceIds.insert(workspace.id).inserted {
            orderedWorkspaces.append(workspace)
        }

        return orderedWorkspaces
    }

    static func validate(_ query: IPCQueryRequest, sessionToken: String) -> IPCErrorCode? {
        guard let descriptor = IPCAutomationManifest.queryDescriptor(for: query.name) else {
            return .invalidArguments
        }

        let supportedSelectors = Set(descriptor.selectors.map(\.name))
        for selector in query.selectors.providedSelectorNames where !supportedSelectors.contains(selector) {
            return .invalidArguments
        }

        guard flagsAreValid(query.selectors) else { return .invalidArguments }

        if !query.fields.isEmpty {
            let allowedFields = Set(descriptor.fields)
            guard !allowedFields.isEmpty, query.fields.allSatisfy(allowedFields.contains) else {
                return .invalidArguments
            }
        }

        if let windowSelector = query.selectors.window, supportedSelectors.contains(.window) {
            switch IPCWindowOpaqueID.validate(windowSelector, expectingSessionToken: sessionToken) {
            case .valid:
                break
            case .stale:
                return .staleWindowId
            case .invalid:
                return .invalidArguments
            }
        }

        return nil
    }

    private static func flagsAreValid(_ selectors: IPCQuerySelectors) -> Bool {
        if let focused = selectors.focused, focused != true { return false }
        if let visible = selectors.visible, visible != true { return false }
        if let floating = selectors.floating, floating != true { return false }
        if let scratchpad = selectors.scratchpad, scratchpad != true { return false }
        if let current = selectors.current, current != true { return false }
        if let main = selectors.main, main != true { return false }
        return true
    }
}
