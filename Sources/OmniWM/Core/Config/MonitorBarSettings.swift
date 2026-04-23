// SPDX-License-Identifier: GPL-2.0-only
import CoreGraphics
import Foundation

struct MonitorBarSettings: MonitorSettingsType {
    let id: UUID
    var monitorName: String
    var monitorDisplayId: CGDirectDisplayID?

    var enabled: Bool?
    var showLabels: Bool?
    var showFloatingWindows: Bool?
    var deduplicateAppIcons: Bool?
    var hideEmptyWorkspaces: Bool?
    var reserveLayoutSpace: Bool?
    var notchAware: Bool?
    var position: WorkspaceBarPosition?
    var windowLevel: WorkspaceBarWindowLevel?
    var height: Double?
    var backgroundOpacity: Double?
    var xOffset: Double?
    var yOffset: Double?

    init(
        id: UUID = UUID(),
        monitorName: String,
        monitorDisplayId: CGDirectDisplayID? = nil,
        enabled: Bool? = nil,
        showLabels: Bool? = nil,
        showFloatingWindows: Bool? = nil,
        deduplicateAppIcons: Bool? = nil,
        hideEmptyWorkspaces: Bool? = nil,
        reserveLayoutSpace: Bool? = nil,
        notchAware: Bool? = nil,
        position: WorkspaceBarPosition? = nil,
        windowLevel: WorkspaceBarWindowLevel? = nil,
        height: Double? = nil,
        backgroundOpacity: Double? = nil,
        xOffset: Double? = nil,
        yOffset: Double? = nil
    ) {
        self.id = id
        self.monitorName = monitorName
        self.monitorDisplayId = monitorDisplayId
        self.enabled = enabled
        self.showLabels = showLabels
        self.showFloatingWindows = showFloatingWindows
        self.deduplicateAppIcons = deduplicateAppIcons
        self.hideEmptyWorkspaces = hideEmptyWorkspaces
        self.reserveLayoutSpace = reserveLayoutSpace
        self.notchAware = notchAware
        self.position = position
        self.windowLevel = windowLevel
        self.height = height
        self.backgroundOpacity = backgroundOpacity
        self.xOffset = xOffset
        self.yOffset = yOffset
    }

    private enum CodingKeys: String, CodingKey {
        case id, monitorName, monitorDisplayId, enabled, showLabels, showFloatingWindows, deduplicateAppIcons
        case hideEmptyWorkspaces, reserveLayoutSpace, notchAware, position, windowLevel
        case height, backgroundOpacity, xOffset, yOffset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        monitorName = try container.decode(String.self, forKey: .monitorName)
        monitorDisplayId = try container.decodeIfPresent(CGDirectDisplayID.self, forKey: .monitorDisplayId)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        showLabels = try container.decodeIfPresent(Bool.self, forKey: .showLabels)
        showFloatingWindows = try container.decodeIfPresent(Bool.self, forKey: .showFloatingWindows)
        deduplicateAppIcons = try container.decodeIfPresent(Bool.self, forKey: .deduplicateAppIcons)
        hideEmptyWorkspaces = try container.decodeIfPresent(Bool.self, forKey: .hideEmptyWorkspaces)
        reserveLayoutSpace = try container.decodeIfPresent(Bool.self, forKey: .reserveLayoutSpace)
        notchAware = try container.decodeIfPresent(Bool.self, forKey: .notchAware)
        position = try container.decodeIfPresent(String.self, forKey: .position)
            .flatMap { WorkspaceBarPosition(rawValue: $0) }
        windowLevel = try container.decodeIfPresent(String.self, forKey: .windowLevel)
            .flatMap { WorkspaceBarWindowLevel(rawValue: $0) }
        height = try container.decodeIfPresent(Double.self, forKey: .height)
        backgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity)
        xOffset = try container.decodeIfPresent(Double.self, forKey: .xOffset)
        yOffset = try container.decodeIfPresent(Double.self, forKey: .yOffset)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(monitorName, forKey: .monitorName)
        try container.encodeIfPresent(monitorDisplayId, forKey: .monitorDisplayId)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encodeIfPresent(showLabels, forKey: .showLabels)
        try container.encodeIfPresent(showFloatingWindows, forKey: .showFloatingWindows)
        try container.encodeIfPresent(deduplicateAppIcons, forKey: .deduplicateAppIcons)
        try container.encodeIfPresent(hideEmptyWorkspaces, forKey: .hideEmptyWorkspaces)
        try container.encodeIfPresent(reserveLayoutSpace, forKey: .reserveLayoutSpace)
        try container.encodeIfPresent(notchAware, forKey: .notchAware)
        try container.encodeIfPresent(position?.rawValue, forKey: .position)
        try container.encodeIfPresent(windowLevel?.rawValue, forKey: .windowLevel)
        try container.encodeIfPresent(height, forKey: .height)
        try container.encodeIfPresent(backgroundOpacity, forKey: .backgroundOpacity)
        try container.encodeIfPresent(xOffset, forKey: .xOffset)
        try container.encodeIfPresent(yOffset, forKey: .yOffset)
    }
}

struct ResolvedBarSettings {
    let enabled: Bool
    let showLabels: Bool
    let showFloatingWindows: Bool
    let deduplicateAppIcons: Bool
    let hideEmptyWorkspaces: Bool
    let reserveLayoutSpace: Bool
    let notchAware: Bool
    let position: WorkspaceBarPosition
    let windowLevel: WorkspaceBarWindowLevel
    let height: Double
    let backgroundOpacity: Double
    let xOffset: Double
    let yOffset: Double
    let accentColorRed: Double
    let accentColorGreen: Double
    let accentColorBlue: Double
    let accentColorAlpha: Double
    let textColorRed: Double
    let textColorGreen: Double
    let textColorBlue: Double
    let textColorAlpha: Double
    let labelFontSize: Double
}
