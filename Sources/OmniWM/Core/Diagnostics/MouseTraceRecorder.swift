// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum MouseTrace {
    struct Record: Sendable {
        let timestamp: Date
        let detail: String
    }

    static let shared = SessionTraceRecorder<Record>(
        sectionTitle: "Mouse Trace",
        capacity: 512
    ) { record in
        "\(record.timestamp.ISO8601Format()) \(record.detail)"
    }

    static func record(_ detail: @autoclosure () -> String) {
        guard shared.isActive else { return }
        shared.record(Record(timestamp: Date(), detail: detail()))
    }
}
