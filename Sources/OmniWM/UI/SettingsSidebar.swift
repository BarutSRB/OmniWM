// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import SwiftUI

struct SettingsSidebar: View {
    @Binding var selection: SettingsSection

    var body: some View {
        List(selection: $selection) {
            ForEach(SettingsSectionGroup.allCases) { group in
                Section(group.rawValue) {
                    ForEach(group.sections) { section in
                        Label(section.displayName, systemImage: section.icon)
                            .tag(section)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Settings")
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
    }
}
