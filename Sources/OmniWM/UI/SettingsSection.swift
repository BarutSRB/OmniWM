// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case niri
    case dwindle
    case monitors
    case workspaces
    case borders
    case bar
    case hotkeys
    case quakeTerminal

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
        case .hotkeys: "Hotkeys"
        case .quakeTerminal: "Quake Terminal"
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
        case .hotkeys: "keyboard"
        case .quakeTerminal: "terminal"
        }
    }
}
