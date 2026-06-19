// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct LayoutBuildMetrics {
    private struct Bucket: Hashable {
        let workspaceCount: Int
        let windowRank: Int
    }

    private struct Stat {
        var count = 0
        var totalMicros = 0
        var maxMicros = 0
    }

    private static let windowLabels = ["0", "1-2", "3-5", "6-10", "11-20", "21+"]

    private var statsByBucket: [Bucket: Stat] = [:]
    private(set) var totalBuilds = 0
    private(set) var completedRelayoutCycles = 0

    mutating func recordBuild(seconds: Double, workspaceCount: Int, windowCount: Int) {
        let micros = Int((seconds * 1_000_000).rounded())
        let bucket = Bucket(workspaceCount: workspaceCount, windowRank: Self.windowRank(windowCount))
        var stat = statsByBucket[bucket] ?? Stat()
        stat.count += 1
        stat.totalMicros += micros
        stat.maxMicros = max(stat.maxMicros, micros)
        statsByBucket[bucket] = stat
        totalBuilds += 1
    }

    mutating func recordCompletedCycle() {
        completedRelayoutCycles += 1
    }

    func dump() -> String {
        var lines = [
            "builds=\(totalBuilds) completedCycles=\(completedRelayoutCycles)"
        ]
        guard !statsByBucket.isEmpty else {
            lines.append("no build samples")
            return lines.joined(separator: "\n")
        }
        let sorted = statsByBucket.sorted {
            ($0.key.workspaceCount, $0.key.windowRank) < ($1.key.workspaceCount, $1.key.windowRank)
        }
        for (bucket, stat) in sorted {
            let average = stat.count > 0 ? stat.totalMicros / stat.count : 0
            let windowLabel = Self.windowLabels[bucket.windowRank]
            lines.append(
                "ws=\(bucket.workspaceCount) win=\(windowLabel) n=\(stat.count) avg=\(average)us max=\(stat.maxMicros)us"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func windowRank(_ windowCount: Int) -> Int {
        switch windowCount {
        case 0: return 0
        case 1 ... 2: return 1
        case 3 ... 5: return 2
        case 6 ... 10: return 3
        case 11 ... 20: return 4
        default: return 5
        }
    }
}
