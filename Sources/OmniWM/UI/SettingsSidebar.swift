// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI

struct SettingsSidebar: View {
    @Binding var selection: SettingsSection

    var body: some View {
        List(SettingsSection.allCases, selection: $selection) { section in
            Label(section.displayName, systemImage: section.icon)
                .tag(section)
        }
        .listStyle(.sidebar)
        .navigationTitle("OmniWM")
    }
}
