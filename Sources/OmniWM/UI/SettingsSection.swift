import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case niri
    case dwindle
    case monitors
    case workspaces
    case borders
    case bar
    case hiddenBar
    case menu
    case hotkeys

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general: "General"
        case .niri: "Niri"
        case .dwindle: "Dwindle"
        case .monitors: "Monitors"
        case .workspaces: "Workspaces"
        case .borders: "Borders"
        case .bar: "Bar"
        case .hiddenBar: "Hidden Bar"
        case .menu: "Menu"
        case .hotkeys: "Hotkeys"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .niri: "scroll"
        case .dwindle: "square.split.2x2"
        case .monitors: "display"
        case .workspaces: "rectangle.3.group"
        case .borders: "square.dashed"
        case .bar: "menubar.rectangle"
        case .hiddenBar: "menubar.arrow.up.rectangle"
        case .menu: "filemenu.and.selection"
        case .hotkeys: "keyboard"
        }
    }
}
