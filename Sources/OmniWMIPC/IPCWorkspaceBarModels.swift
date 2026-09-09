// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

public struct IPCWorkspaceBarWindow: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let isFocused: Bool

    public init(id: String, title: String, isFocused: Bool) {
        self.id = id
        self.title = title
        self.isFocused = isFocused
    }
}

public struct IPCWorkspaceBarApp: Codable, Equatable, Sendable {
    public let id: String
    public let appName: String
    public let bundleId: String?
    public let isFocused: Bool
    public let windowCount: Int
    public let allWindows: [IPCWorkspaceBarWindow]

    public init(
        id: String,
        appName: String,
        bundleId: String?,
        isFocused: Bool,
        windowCount: Int,
        allWindows: [IPCWorkspaceBarWindow]
    ) {
        self.id = id
        self.appName = appName
        self.bundleId = bundleId
        self.isFocused = isFocused
        self.windowCount = windowCount
        self.allWindows = allWindows
    }
}

public struct IPCWorkspaceBarScratchpad: Codable, Equatable, Sendable {
    public let index: Int
    public let label: String?
    public let windows: [IPCWorkspaceBarApp]
    public let isVisible: Bool

    public init(index: Int, label: String?, windows: [IPCWorkspaceBarApp], isVisible: Bool) {
        self.index = index
        self.label = label
        self.windows = windows
        self.isVisible = isVisible
    }
}

public struct IPCWorkspaceBarWorkspace: Codable, Equatable, Sendable {
    public let id: String
    public let rawName: String
    public let displayName: String
    public let number: Int?
    public let isFocused: Bool
    public let windows: [IPCWorkspaceBarApp]

    public init(
        id: String,
        rawName: String,
        displayName: String,
        number: Int?,
        isFocused: Bool,
        windows: [IPCWorkspaceBarApp]
    ) {
        self.id = id
        self.rawName = rawName
        self.displayName = displayName
        self.number = number
        self.isFocused = isFocused
        self.windows = windows
    }
}

public struct IPCWorkspaceBarMonitor: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let enabled: Bool
    public let isVisible: Bool
    public let showLabels: Bool
    public let backgroundOpacity: Double
    public let barHeight: Double
    public let scratchpads: [IPCWorkspaceBarScratchpad]
    public let workspaces: [IPCWorkspaceBarWorkspace]

    public init(
        id: String,
        name: String,
        enabled: Bool,
        isVisible: Bool,
        showLabels: Bool,
        backgroundOpacity: Double,
        barHeight: Double,
        scratchpads: [IPCWorkspaceBarScratchpad],
        workspaces: [IPCWorkspaceBarWorkspace]
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.isVisible = isVisible
        self.showLabels = showLabels
        self.backgroundOpacity = backgroundOpacity
        self.barHeight = barHeight
        self.scratchpads = scratchpads
        self.workspaces = workspaces
    }
}

public struct IPCWorkspaceBarQueryResult: Codable, Equatable, Sendable {
    public let interactionMonitorId: String?
    public let monitors: [IPCWorkspaceBarMonitor]

    public init(interactionMonitorId: String?, monitors: [IPCWorkspaceBarMonitor]) {
        self.interactionMonitorId = interactionMonitorId
        self.monitors = monitors
    }
}
