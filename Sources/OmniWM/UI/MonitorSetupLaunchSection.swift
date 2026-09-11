// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

struct MonitorSetupLaunchSection: View {
    let isComplete: Bool
    let onOpen: () -> Void

    var body: some View {
        Section("Guided Setup") {
            HStack(alignment: .center, spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isComplete
                            ? "Multi-monitor setup is complete"
                            : "Set up multiple displays")
                            .fontWeight(.medium)
                        Text(
                            isComplete
                                ? "Run the guide again after moving, replacing, or adding a display."
                                : "Follow four guided steps for display placement, workspace homes, and Mouse Warp."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: isComplete
                        ? "checkmark.circle.fill"
                        : "sparkles")
                        .foregroundStyle(
                            isComplete ? Color.green : Color.accentColor
                        )
                }

                Spacer()

                Button("Run Monitor Setup…", action: onOpen)
            }
        }
    }
}
