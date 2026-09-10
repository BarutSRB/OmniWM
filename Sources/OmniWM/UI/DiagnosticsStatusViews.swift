// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
import SwiftUI

struct DiagnosticsStatusLabel: View {
    let status: DiagnosticsActionStatus

    @ViewBuilder
    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case let .success(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case let .failure(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

struct DiagnosticsRecordingProgress: View {
    let startedAt: Date?

    @ViewBuilder
    var body: some View {
        if let startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = elapsed(since: startedAt, now: context.date)
                HStack(spacing: 8) {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.red)
                    Text("Recording \(elapsed)")
                        .font(.callout.monospacedDigit())
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Recording in progress")
                .accessibilityValue(elapsed)
            }
        }
    }

    private func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
