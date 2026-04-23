// SPDX-License-Identifier: GPL-2.0-only
import AppKit

enum AppearanceMode: String, CaseIterable, Codable {
    case automatic
    case light
    case dark

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    @MainActor
    func apply() {
        switch self {
        case .automatic:
            NSApplication.shared.appearance = nil
        case .light:
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
