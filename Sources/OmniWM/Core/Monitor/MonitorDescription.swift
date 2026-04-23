// SPDX-License-Identifier: GPL-2.0-only
import Foundation

enum MonitorDescription: Equatable {
    case main
    case secondary
    case output(OutputId)

    func resolveMonitor(sortedMonitors: [Monitor]) -> Monitor? {
        switch self {
        case .main:
            return sortedMonitors.first(where: { $0.isMain }) ?? sortedMonitors.first
        case .secondary:
            guard sortedMonitors.count >= 2 else { return nil }
            if let main = sortedMonitors.first(where: { $0.isMain }),
               let secondary = sortedMonitors.first(where: { $0.id != main.id })
            {
                return secondary
            }
            return sortedMonitors.dropFirst().first
        case let .output(output):
            return output.resolveMonitor(in: sortedMonitors)
        }
    }
}
