// SPDX-License-Identifier: GPL-2.0-only
import CoreGraphics
import Foundation

struct OutputId: Hashable, Codable {
    struct OrderedResolution {
        let reboundOutputs: [OutputId]
        let resolvedMonitorIds: [Monitor.ID]
        let claimedMonitorIds: Set<Monitor.ID>
        let resolvedSlotIndices: Set<Int>
    }

    let displayId: CGDirectDisplayID

    let name: String

    init(displayId: CGDirectDisplayID, name: String) {
        self.displayId = displayId
        self.name = name
    }

    init(from monitor: Monitor) {
        displayId = monitor.displayId
        name = monitor.name
    }

    func resolveMonitor(in monitors: [Monitor]) -> Monitor? {
        monitors.first(where: { $0.displayId == displayId })
    }

    func rebound(in monitors: [Monitor]) -> OutputId? {
        if let exact = resolveMonitor(in: monitors) {
            return OutputId(from: exact)
        }

        let nameMatches = monitors.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard nameMatches.count == 1 else { return nil }
        return OutputId(from: nameMatches[0])
    }

    static func resolveOrderedPreservingUnresolved(
        _ outputs: [OutputId],
        in monitors: [Monitor]
    ) -> OrderedResolution {
        let monitorsByDisplayId = Dictionary(uniqueKeysWithValues: monitors.map { ($0.displayId, $0) })
        var claimedMonitorIds: Set<Monitor.ID> = []
        var resolvedMonitorIds: [Monitor.ID] = []
        var reboundOutputs: [OutputId] = []
        var resolvedSlotIndices: Set<Int> = []

        reboundOutputs.reserveCapacity(outputs.count)
        resolvedMonitorIds.reserveCapacity(outputs.count)

        for (index, output) in outputs.enumerated() {
            if let exact = monitorsByDisplayId[output.displayId],
               claimedMonitorIds.insert(exact.id).inserted
            {
                reboundOutputs.append(OutputId(from: exact))
                resolvedMonitorIds.append(exact.id)
                resolvedSlotIndices.insert(index)
                continue
            }

            let nameMatches = monitors.filter {
                !claimedMonitorIds.contains($0.id) &&
                    $0.name.caseInsensitiveCompare(output.name) == .orderedSame
            }
            if nameMatches.count == 1,
               let fallback = nameMatches.first,
               claimedMonitorIds.insert(fallback.id).inserted
            {
                reboundOutputs.append(OutputId(from: fallback))
                resolvedMonitorIds.append(fallback.id)
                resolvedSlotIndices.insert(index)
                continue
            }

            reboundOutputs.append(output)
        }

        return OrderedResolution(
            reboundOutputs: reboundOutputs,
            resolvedMonitorIds: resolvedMonitorIds,
            claimedMonitorIds: claimedMonitorIds,
            resolvedSlotIndices: resolvedSlotIndices
        )
    }
}
