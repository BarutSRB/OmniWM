import AppKit

struct BorderConfig: Equatable {
    var enabled: Bool
    var width: CGFloat
    var color: NSColor

    init(enabled: Bool = false, width: CGFloat = 4.0, color: NSColor = .systemBlue) {
        self.enabled = enabled
        self.width = width
        self.color = color
    }

    @MainActor static func from(settings: SettingsStore) -> BorderConfig {
        let color = NSColor(
            red: CGFloat(settings.borderColorRed),
            green: CGFloat(settings.borderColorGreen),
            blue: CGFloat(settings.borderColorBlue),
            alpha: CGFloat(settings.borderColorAlpha)
        )
        return BorderConfig(
            enabled: settings.bordersEnabled,
            width: CGFloat(settings.borderWidth),
            color: color
        )
    }
}
