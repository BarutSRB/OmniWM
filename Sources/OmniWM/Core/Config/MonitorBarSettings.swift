import Foundation

struct MonitorBarSettings: Codable, Identifiable, Equatable {
    let id: UUID
    var monitorName: String

    var enabled: Bool?
    var showLabels: Bool?
    var deduplicateAppIcons: Bool?
    var hideEmptyWorkspaces: Bool?
    var notchAware: Bool?
    var position: String?
    var windowLevel: String?
    var height: Double?
    var backgroundOpacity: Double?
    var xOffset: Double?
    var yOffset: Double?

    init(
        id: UUID = UUID(),
        monitorName: String,
        enabled: Bool? = nil,
        showLabels: Bool? = nil,
        deduplicateAppIcons: Bool? = nil,
        hideEmptyWorkspaces: Bool? = nil,
        notchAware: Bool? = nil,
        position: String? = nil,
        windowLevel: String? = nil,
        height: Double? = nil,
        backgroundOpacity: Double? = nil,
        xOffset: Double? = nil,
        yOffset: Double? = nil
    ) {
        self.id = id
        self.monitorName = monitorName
        self.enabled = enabled
        self.showLabels = showLabels
        self.deduplicateAppIcons = deduplicateAppIcons
        self.hideEmptyWorkspaces = hideEmptyWorkspaces
        self.notchAware = notchAware
        self.position = position
        self.windowLevel = windowLevel
        self.height = height
        self.backgroundOpacity = backgroundOpacity
        self.xOffset = xOffset
        self.yOffset = yOffset
    }

    var isUsingAllGlobalDefaults: Bool {
        enabled == nil &&
            showLabels == nil &&
            deduplicateAppIcons == nil &&
            hideEmptyWorkspaces == nil &&
            notchAware == nil &&
            position == nil &&
            windowLevel == nil &&
            height == nil &&
            backgroundOpacity == nil &&
            xOffset == nil &&
            yOffset == nil
    }

    mutating func resetToGlobalDefaults() {
        enabled = nil
        showLabels = nil
        deduplicateAppIcons = nil
        hideEmptyWorkspaces = nil
        notchAware = nil
        position = nil
        windowLevel = nil
        height = nil
        backgroundOpacity = nil
        xOffset = nil
        yOffset = nil
    }
}

struct ResolvedBarSettings {
    let enabled: Bool
    let showLabels: Bool
    let deduplicateAppIcons: Bool
    let hideEmptyWorkspaces: Bool
    let notchAware: Bool
    let position: WorkspaceBarPosition
    let windowLevel: WorkspaceBarWindowLevel
    let height: Double
    let backgroundOpacity: Double
    let xOffset: Double
    let yOffset: Double
}
