// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

class NiriRoot: NiriContainer {
    let workspaceId: WorkspaceDescriptor.ID

    private var nodeIndex: [NodeId: NiriNode]?
    private var _cachedColumns: [NiriContainer]?
    private var _cachedAllWindows: [NiriWindow]?
    private var _cachedWindowIdSet: Set<WindowToken>?

    init(workspaceId: WorkspaceDescriptor.ID) {
        self.workspaceId = workspaceId
        super.init()
    }

    override func invalidateChildrenCache() {
        _cachedColumns = nil
        _cachedAllWindows = nil
        _cachedWindowIdSet = nil
        super.invalidateChildrenCache()
    }

    var columns: [NiriContainer] {
        if let cached = _cachedColumns { return cached }
        let result = children.compactMap { $0 as? NiriContainer }
        _cachedColumns = result
        return result
    }

    var allWindows: [NiriWindow] {
        if let cached = _cachedAllWindows { return cached }
        let result = columns.flatMap(\.windowNodes)
        _cachedAllWindows = result
        return result
    }

    var windowIdSet: Set<WindowToken> {
        if let cached = _cachedWindowIdSet { return cached }
        let result = Set(allWindows.map(\.token))
        _cachedWindowIdSet = result
        return result
    }

    private func buildNodeIndex() -> [NodeId: NiriNode] {
        var index: [NodeId: NiriNode] = [:]
        func addToIndex(_ node: NiriNode) {
            index[node.id] = node
            for child in node.children {
                addToIndex(child)
            }
        }
        addToIndex(self)
        return index
    }

    func findNode(by id: NodeId) -> NiriNode? {
        if nodeIndex == nil {
            nodeIndex = buildNodeIndex()
        }
        return nodeIndex?[id]
    }

    func registerNode(_ node: NiriNode) {
        nodeIndex?[node.id] = node
        for child in node.children {
            registerNode(child)
        }
    }

    func unregisterNode(_ node: NiriNode) {
        nodeIndex?.removeValue(forKey: node.id)
        for child in node.children {
            unregisterNode(child)
        }
    }
}
