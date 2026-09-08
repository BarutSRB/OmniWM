// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

/// User-defined preference order for monitor roles. The highest-ranked connected display is
/// OmniWM's Main monitor, the next is Secondary, the third is Tertiary. When the ranking is empty,
/// roles follow the macOS main display and the arrangement order, exactly as before the ranking existed.
enum MonitorRanking {
    /// Connected monitors in role order: ranked entries that resolve to a connected display first,
    /// in ranking order, followed by every remaining monitor in the default order.
    static func roleOrder(ranking: [OutputId], sortedMonitors: [Monitor]) -> [Monitor] {
        var ordered: [Monitor] = []
        for entry in ranking {
            guard let monitor = resolve(entry, in: sortedMonitors),
                  !ordered.contains(where: { $0.id == monitor.id })
            else { continue }
            ordered.append(monitor)
        }
        for monitor in defaultOrder(sortedMonitors) where !ordered.contains(where: { $0.id == monitor.id }) {
            ordered.append(monitor)
        }
        return ordered
    }

    /// The order used when no ranking applies: the macOS main display first, then arrangement order.
    static func defaultOrder(_ sortedMonitors: [Monitor]) -> [Monitor] {
        guard let main = sortedMonitors.first(where: \.isMain) else { return sortedMonitors }
        return [main] + sortedMonitors.filter { $0.id != main.id }
    }

    /// Resolves a ranking entry by display identity first, then by a unique case-insensitive name
    /// match so hand-written entries with only a name still work.
    static func resolve(_ entry: OutputId, in monitors: [Monitor]) -> Monitor? {
        if let monitor = entry.resolveMonitor(in: monitors) {
            return monitor
        }
        let byName = monitors.filter { Monitor.namesMatch($0.name, entry.name) }
        return byName.count == 1 ? byName[0] : nil
    }

    static func isConnected(_ entry: OutputId, monitors: [Monitor]) -> Bool {
        resolve(entry, in: monitors) != nil
    }

    /// Trims names, drops blank entries, and removes duplicates while keeping the first occurrence.
    static func normalized(_ ranking: [OutputId]) -> [OutputId] {
        var result: [OutputId] = []
        for entry in ranking {
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let normalizedEntry = OutputId(displayUUID: entry.displayUUID, displayId: entry.displayId, name: name)
            guard !result.contains(where: { duplicates($0, normalizedEntry) }) else { continue }
            result.append(normalizedEntry)
        }
        return result
    }

    /// Connected monitors that no ranking entry resolves to, in arrangement order.
    static func addable(connected monitors: [Monitor], ranking: [OutputId]) -> [OutputId] {
        let rankedIds = Set(ranking.compactMap { resolve($0, in: monitors)?.id })
        return Monitor.sortedByPosition(monitors)
            .filter { !rankedIds.contains($0.id) }
            .map(OutputId.init(from:))
    }

    static func roleName(forRank index: Int) -> String {
        switch index {
        case 0: "Main"
        case 1: "Secondary"
        case 2: "Tertiary"
        default: "Rank \(index + 1)"
        }
    }

    static func moving<Element>(_ items: [Element], from index: Int, by offset: Int) -> [Element] {
        let target = index + offset
        guard items.indices.contains(index), items.indices.contains(target), index != target else { return items }
        var result = items
        result.swapAt(index, target)
        return result
    }

    static func removing<Element>(_ items: [Element], at index: Int) -> [Element] {
        guard items.indices.contains(index) else { return items }
        var result = items
        result.remove(at: index)
        return result
    }

    /// Two entries are duplicates when they share a display UUID, or when either lacks a UUID and
    /// their names match. Two displays of the same model with distinct UUIDs are kept apart.
    private static func duplicates(_ lhs: OutputId, _ rhs: OutputId) -> Bool {
        if let lhsUUID = lhs.displayUUID, let rhsUUID = rhs.displayUUID {
            return lhsUUID == rhsUUID
        }
        return Monitor.namesMatch(lhs.name, rhs.name)
    }
}
