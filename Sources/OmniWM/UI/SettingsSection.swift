// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case diagnostics
    case niri
    case dwindle
    case monitors
    case workspaces
    case borders
    case bar
    case hiddenBar
    case hotkeys
    case mouseTrackpad
    case quakeTerminal
    case reportIssue

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .general: "General"
        case .diagnostics: "Troubleshooting"
        case .niri: "Niri Layout"
        case .dwindle: "Dwindle Layout"
        case .monitors: "Monitors"
        case .workspaces: "Workspaces"
        case .borders: "Borders"
        case .bar: "Workspace Bar"
        case .hiddenBar: "Hidden Bar"
        case .hotkeys: "Hotkeys"
        case .mouseTrackpad: "Mouse & Trackpad"
        case .quakeTerminal: "Quake Terminal"
        case .reportIssue: "Report an Issue"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .diagnostics: "stethoscope"
        case .niri: "scroll"
        case .dwindle: "square.split.2x2"
        case .monitors: "display"
        case .workspaces: "rectangle.3.group"
        case .borders: "square.dashed"
        case .bar: "menubar.rectangle"
        case .hiddenBar: "eye.slash"
        case .hotkeys: "keyboard"
        case .mouseTrackpad: "computermouse"
        case .quakeTerminal: "terminal"
        case .reportIssue: "ladybug"
        }
    }
}

enum SettingsSectionGroup: String, CaseIterable, Identifiable {
    case basics = "Basics"
    case layouts = "Layouts"
    case workspace = "Workspace"
    case input = "Input"
    case help = "Help"

    var id: String {
        rawValue
    }

    var sections: [SettingsSection] {
        switch self {
        case .basics:
            [.general]
        case .layouts:
            [.niri, .dwindle, .monitors]
        case .workspace:
            [.workspaces, .borders, .bar, .hiddenBar]
        case .input:
            [.hotkeys, .mouseTrackpad, .quakeTerminal]
        case .help:
            [.reportIssue, .diagnostics]
        }
    }
}
