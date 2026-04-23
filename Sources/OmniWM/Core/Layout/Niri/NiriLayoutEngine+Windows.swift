// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Foundation

extension NiriLayoutEngine {
    func updateWindowConstraints(for token: WindowToken, constraints: WindowSizeConstraints) {
        guard let node = tokenToNode[token] else { return }
        node.constraints = constraints.normalized()
    }

    func addWindow(
        token: WindowToken,
        to workspaceId: WorkspaceDescriptor.ID,
        afterSelection selectedNodeId: NodeId?,
        focusedToken: WindowToken? = nil
    ) -> NiriWindow {
        var state = ViewportState()
        state.selectedNodeId = selectedNodeId

        guard let plan = callTopologyKernel(
            operation: .addWindow,
            workspaceId: workspaceId,
            state: state,
            workingFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
            gaps: 0,
            subjectToken: token,
            focusedToken: focusedToken,
            motion: .disabled
        ) else { preconditionFailure("Niri topology kernel failed to add window") }

        applyTopologyPlan(plan, in: workspaceId)
        return findNode(for: token)!
    }

    func removeWindow(token: WindowToken) {
        guard let node = tokenToNode[token] else { return }
        let state = ViewportState()
        guard let root = node.findRoot(),
              let plan = callTopologyKernel(
                  operation: .removeWindow,
                  workspaceId: root.workspaceId,
                  state: state,
                  workingFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
                  gaps: 0,
                  subject: node,
                  motion: .disabled
              )
        else { return }

        applyTopologyPlan(plan, in: root.workspaceId)
    }

    @discardableResult
    func rekeyWindow(from oldToken: WindowToken, to newToken: WindowToken) -> Bool {
        guard oldToken != newToken,
              tokenToNode[newToken] == nil,
              let node = tokenToNode.removeValue(forKey: oldToken)
        else {
            return false
        }

        node.token = newToken
        tokenToNode[newToken] = node

        if let frame = framePool.removeValue(forKey: oldToken) {
            framePool[newToken] = frame
        }
        if let hiddenSide = hiddenPool.removeValue(forKey: oldToken) {
            hiddenPool[newToken] = hiddenSide
        }
        if closingTokens.remove(oldToken) != nil {
            closingTokens.insert(newToken)
        }

        node.invalidateChildrenCache()
        return true
    }

    @discardableResult
    func syncWindows(
        _ tokens: [WindowToken],
        in workspaceId: WorkspaceDescriptor.ID,
        selectedNodeId: NodeId?,
        focusedToken: WindowToken? = nil
    ) -> Set<WindowToken> {
        let root = ensureRoot(for: workspaceId)
        let existingIdSet = root.windowIdSet
        var state = ViewportState()
        state.selectedNodeId = selectedNodeId

        if let plan = callTopologyKernel(
            operation: .syncWindows,
            workspaceId: workspaceId,
            state: state,
            workingFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
            gaps: 0,
            focusedToken: focusedToken,
            desiredTokens: tokens,
            motion: .disabled,
            hasCompletedInitialRefresh: false
        ) {
            applyTopologyPlan(plan, in: workspaceId)
        }

        return existingIdSet.subtracting(Set(tokens))
    }

    func validateSelection(
        _ selectedNodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NodeId? {
        guard let selectedId = selectedNodeId else {
            return columns(in: workspaceId).first?.firstChild()?.id
        }

        guard let root = roots[workspaceId],
              let existingNode = root.findNode(by: selectedId)
        else {
            return columns(in: workspaceId).first?.firstChild()?.id
        }

        return existingNode.id
    }

    func fallbackSelectionOnRemoval(
        removing removingNodeId: NodeId,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> NodeId? {
        topologyFallbackSelectionOnRemoval(removing: removingNodeId, in: workspaceId)
    }

    func updateFocusTimestamp(for nodeId: NodeId) {
        guard let node = findNode(by: nodeId) as? NiriWindow else { return }
        node.lastFocusedTime = Date()
    }

    func updateFocusTimestamp(for token: WindowToken) {
        guard let node = findNode(for: token) else { return }
        node.lastFocusedTime = Date()
    }

    func findMostRecentlyFocusedWindow(
        excluding excludingNodeId: NodeId?,
        in workspaceId: WorkspaceDescriptor.ID? = nil
    ) -> NiriWindow? {
        let allWindows: [NiriWindow] = if let wsId = workspaceId, let root = root(for: wsId) {
            root.allWindows
        } else {
            Array(roots.values.flatMap(\.allWindows))
        }

        let candidates = allWindows.filter { window in
            window.id != excludingNodeId && window.lastFocusedTime != nil
        }

        return candidates.max { ($0.lastFocusedTime ?? .distantPast) < ($1.lastFocusedTime ?? .distantPast) }
    }

}
