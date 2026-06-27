// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import os

enum FallbackCategory: String, CaseIterable, Sendable {
    case skylight
    case ax
    case input
    case capture
    case monitor
    case system
}

final class FallbackFiringRecorder: @unchecked Sendable {
    static let shared = FallbackFiringRecorder()

    private let counts = OSAllocatedUnfairLock(initialState: [String: Int]())

    func note(_ category: FallbackCategory, _ key: String, _ amount: Int = 1) {
        guard amount > 0 else { return }
        counts.withLock { $0["\(category.rawValue)/\(key)", default: 0] += amount }
    }

    func dump() -> String {
        let snapshot = counts.withLock { $0 }
        guard !snapshot.isEmpty else { return "none — no fallback/failure has fired since launch" }
        var lines: [String] = []
        for category in FallbackCategory.allCases {
            let entries = snapshot
                .filter { $0.key.hasPrefix("\(category.rawValue)/") }
                .sorted { $0.key < $1.key }
            guard !entries.isEmpty else { continue }
            lines.append("[\(category.rawValue)]")
            for (key, value) in entries {
                lines.append("  \(key.dropFirst(category.rawValue.count + 1))=\(value)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
