// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

enum MonitorDescription: Equatable {
    case main
    case secondary
    case tertiary
    case output(OutputId)

    /// Resolves the description against the connected monitors. `ranking` is the user's monitor
    /// ranking from Settings; when empty, Main is the macOS main display and Secondary and
    /// Tertiary are the next displays in arrangement order.
    func resolveMonitor(sortedMonitors: [Monitor], ranking: [OutputId] = []) -> Monitor? {
        switch self {
        case .main:
            return rankedMonitor(0, sortedMonitors: sortedMonitors, ranking: ranking)
        case .secondary:
            return rankedMonitor(1, sortedMonitors: sortedMonitors, ranking: ranking)
        case .tertiary:
            return rankedMonitor(2, sortedMonitors: sortedMonitors, ranking: ranking)
        case let .output(output):
            return output.resolveMonitor(in: sortedMonitors)
        }
    }

    private func rankedMonitor(_ rank: Int, sortedMonitors: [Monitor], ranking: [OutputId]) -> Monitor? {
        let order = MonitorRanking.roleOrder(ranking: ranking, sortedMonitors: sortedMonitors)
        guard order.indices.contains(rank) else { return nil }
        return order[rank]
    }
}
