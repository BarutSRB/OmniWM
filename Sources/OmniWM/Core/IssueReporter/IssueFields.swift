// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

enum IssueCategory: String, CaseIterable, Identifiable {
    case unspecified
    case layout
    case focus
    case multiMonitor
    case placement
    case crash
    case performance
    case visual

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .unspecified: "Unspecified"
        case .layout: "Tiling layout (Niri / Dwindle)"
        case .focus: "Focus / focus-follows-mouse"
        case .multiMonitor: "Multi-monitor / workspaces"
        case .placement: "Window placement or sizing"
        case .crash: "Crash"
        case .performance: "Performance / animation"
        case .visual: "Visual (borders, bar, overview)"
        }
    }
}

enum IssueRegression: String, CaseIterable, Identifiable {
    case unknown
    case no
    case yes

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .unknown: "Unknown"
        case .no: "No — it never worked"
        case .yes: "Yes — it used to work"
        }
    }
}

extension LayoutType {
    var normalizedForReport: LayoutType {
        self == .defaultLayout ? .niri : self
    }

    static var reportChoices: [LayoutType] {
        [.niri, .dwindle]
    }
}

struct IssueComposition {
    var category: IssueCategory = .unspecified
    var actual = ""
    var expected = ""
    var repro = ""
    var affectedApps = ""
    var layout: LayoutType = .niri
    var regression: IssueRegression = .unknown
    var regressionVersion = ""
}
