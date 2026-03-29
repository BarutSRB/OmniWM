import Foundation

@MainActor
enum WorkspaceEntryOrdering {
    private struct SortKey {
        let group: Int
        let primary: Int
        let secondary: Int
    }

    static func orderedEntries(
        _ entries: [WindowModel.Entry],
        in workspaceId: WorkspaceDescriptor.ID,
        engine: NiriLayoutEngine?
    ) -> [WindowModel.Entry] {
        guard let orderMap = orderMap(for: workspaceId, engine: engine) else {
            return entries
        }

        let fallbackOrder = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.handle.id, $0.offset) })

        return entries.sorted { lhs, rhs in
            let lhsKey = orderMap[lhs.handle.id] ?? SortKey(group: 2, primary: Int.max, secondary: Int.max)
            let rhsKey = orderMap[rhs.handle.id] ?? SortKey(group: 2, primary: Int.max, secondary: Int.max)

            if lhsKey.group != rhsKey.group { return lhsKey.group < rhsKey.group }
            if lhsKey.primary != rhsKey.primary { return lhsKey.primary < rhsKey.primary }
            if lhsKey.secondary != rhsKey.secondary { return lhsKey.secondary < rhsKey.secondary }

            let lhsFallback = fallbackOrder[lhs.handle.id] ?? 0
            let rhsFallback = fallbackOrder[rhs.handle.id] ?? 0
            return lhsFallback < rhsFallback
        }
    }

    private static func orderMap(
        for workspaceId: WorkspaceDescriptor.ID,
        engine: NiriLayoutEngine?
    ) -> [WindowToken: SortKey]? {
        guard let engine else { return nil }

        var order: [WindowToken: SortKey] = [:]
        let columns = engine.columns(in: workspaceId)

        for (columnIndex, column) in columns.enumerated() {
            for (rowIndex, window) in column.windowNodes.enumerated() {
                order[window.handle.id] = SortKey(group: 0, primary: columnIndex, secondary: rowIndex)
            }
        }

        return order
    }
}
