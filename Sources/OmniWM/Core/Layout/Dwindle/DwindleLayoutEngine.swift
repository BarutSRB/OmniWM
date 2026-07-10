// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

private final class DwindleWorkspaceState {
    let root = DwindleNode(kind: .leaf(handle: nil, fullscreen: false))
    var leafByToken: [WindowToken: DwindleNode] = [:]
    var selectedNodeId: DwindleNodeId?
    var preselection: Direction?
}

final class DwindleLayoutEngine {
    private var states: [WorkspaceDescriptor.ID: DwindleWorkspaceState] = [:]
    private var windowConstraints: [WindowToken: WindowSizeConstraints] = [:]

    var settings: DwindleSettings = DwindleSettings()
    private var monitorSettings: [Monitor.ID: ResolvedDwindleSettings] = [:]
    var animationClock: AnimationClock?
    var isMutationSanctioned = true

    var interactiveResize: DwindleInteractiveResize?

    func assertSanctionedMutation(_ operation: StaticString = #function) {
        assert(
            isMutationSanctioned,
            "\(operation) mutated the Dwindle layout tree outside a sanctioned WorldStore scope"
        )
    }

    func updateWindowConstraints(for token: WindowToken, constraints: WindowSizeConstraints) {
        assertSanctionedMutation()
        windowConstraints[token] = constraints.normalized()
    }

    func constraints(for token: WindowToken) -> WindowSizeConstraints {
        windowConstraints[token] ?? .unconstrained
    }

    func updateMonitorSettings(_ resolved: ResolvedDwindleSettings, for monitorId: Monitor.ID) {
        assertSanctionedMutation()
        monitorSettings[monitorId] = resolved
    }

    func cleanupRemovedMonitor(_ monitorId: Monitor.ID) {
        assertSanctionedMutation()
        monitorSettings.removeValue(forKey: monitorId)
    }

    func effectiveSettings(for monitorId: Monitor.ID) -> DwindleSettings {
        guard let resolved = monitorSettings[monitorId] else { return settings }

        var effective = settings
        effective.smartSplit = resolved.smartSplit
        effective.defaultSplitRatio = resolved.defaultSplitRatio
        effective.splitWidthMultiplier = resolved.splitWidthMultiplier
        effective.singleWindowFit = resolved.singleWindowFit
        if !resolved.useGlobalGaps {
            effective.innerGap = resolved.innerGap
        }
        return effective
    }

    var windowMovementAnimationConfig: CubicConfig = .hyprlandDwindle

    func root(for workspaceId: WorkspaceDescriptor.ID) -> DwindleNode? {
        states[workspaceId]?.root
    }

    private func ensureState(for workspaceId: WorkspaceDescriptor.ID) -> DwindleWorkspaceState {
        if let existing = states[workspaceId] {
            return existing
        }
        let state = DwindleWorkspaceState()
        states[workspaceId] = state
        return state
    }

    func removeLayout(for workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        guard let state = states.removeValue(forKey: workspaceId) else { return }
        if interactiveResize?.workspaceId == workspaceId {
            clearInteractiveResize()
        }
        for token in state.leafByToken.keys {
            releaseConstraintsIfUntracked(token)
        }
    }

    private func releaseConstraintsIfUntracked(_ token: WindowToken) {
        guard states.values.allSatisfy({ $0.leafByToken[token] == nil }) else { return }
        windowConstraints.removeValue(forKey: token)
    }

    func containsWindow(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        states[workspaceId]?.leafByToken[token] != nil
    }

    func findNode(for token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> DwindleNode? {
        states[workspaceId]?.leafByToken[token]
    }

    func isWindowFullscreen(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        findNode(for: token, in: workspaceId)?.isFullscreen == true
    }

    func fullscreenTokens(in workspaceId: WorkspaceDescriptor.ID) -> Set<WindowToken> {
        guard let state = states[workspaceId] else { return [] }
        return Set(state.leafByToken.filter { $0.value.isFullscreen }.keys)
    }

    func windowCount(in workspaceId: WorkspaceDescriptor.ID) -> Int {
        states[workspaceId]?.leafByToken.count ?? 0
    }

    func selectedNode(in workspaceId: WorkspaceDescriptor.ID) -> DwindleNode? {
        guard let state = states[workspaceId], let nodeId = state.selectedNodeId else { return nil }
        return findNodeById(nodeId, in: state.root)
    }

    func setSelectedNode(_ node: DwindleNode?, in workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        guard let node else {
            ensureState(for: workspaceId).selectedNodeId = nil
            return
        }
        guard let state = states[workspaceId], findNodeById(node.id, in: state.root) != nil else { return }
        state.selectedNodeId = node.id
    }

    @discardableResult
    func setPreselection(_ direction: Direction?, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        assertSanctionedMutation()
        let state = ensureState(for: workspaceId)
        guard state.preselection != direction else { return false }
        state.preselection = direction
        return true
    }

    func getPreselection(in workspaceId: WorkspaceDescriptor.ID) -> Direction? {
        states[workspaceId]?.preselection
    }

    private func findNodeById(_ nodeId: DwindleNodeId, in root: DwindleNode) -> DwindleNode? {
        if root.id == nodeId { return root }
        for child in root.children {
            if let found = findNodeById(nodeId, in: child) {
                return found
            }
        }
        return nil
    }

    @discardableResult
    func addWindow(
        token: WindowToken,
        to workspaceId: WorkspaceDescriptor.ID,
        activeWindowFrame: CGRect?
    ) -> DwindleNode {
        let state = ensureState(for: workspaceId)

        if let existing = state.leafByToken[token] {
            state.selectedNodeId = existing.id
            return existing
        }

        if case let .leaf(existingHandle, _) = state.root.kind, existingHandle == nil {
            state.root.kind = .leaf(handle: token, fullscreen: false)
            state.leafByToken[token] = state.root
            state.selectedNodeId = state.root.id
            return state.root
        }

        let targetNode: DwindleNode
        if let selected = selectedNode(in: workspaceId), selected.isLeaf {
            targetNode = selected
        } else {
            targetNode = state.root.descendToFirstLeaf()
        }

        let newLeaf = splitLeaf(
            targetNode,
            newWindow: token,
            state: state,
            activeWindowFrame: activeWindowFrame,
            preselectedDirection: state.preselection
        )
        state.preselection = nil

        state.leafByToken[token] = newLeaf
        state.selectedNodeId = newLeaf.id
        return newLeaf
    }

    private func splitLeaf(
        _ leaf: DwindleNode,
        newWindow: WindowToken,
        state: DwindleWorkspaceState,
        activeWindowFrame: CGRect?,
        preselectedDirection: Direction? = nil
    ) -> DwindleNode {
        guard case let .leaf(existingHandle, fullscreen) = leaf.kind else {
            let newLeaf = DwindleNode(kind: .leaf(handle: newWindow, fullscreen: false))
            leaf.appendChild(newLeaf)
            return newLeaf
        }

        let targetRect = leaf.cachedFrame
        let (orientation, newFirst): (DwindleOrientation, Bool)
        if let dir = preselectedDirection {
            orientation = dir.dwindleOrientation
            newFirst = dir == .left || dir == .up
        } else {
            (orientation, newFirst) = planSplit(
                targetRect: targetRect,
                activeWindowFrame: activeWindowFrame
            )
        }

        let existingLeaf = DwindleNode(kind: .leaf(handle: existingHandle, fullscreen: fullscreen))
        let newLeaf = DwindleNode(kind: .leaf(handle: newWindow, fullscreen: false))

        leaf.kind = .split(orientation: orientation, ratio: settings.defaultSplitRatio)

        if newFirst {
            leaf.replaceChildren(first: newLeaf, second: existingLeaf)
        } else {
            leaf.replaceChildren(first: existingLeaf, second: newLeaf)
        }

        if let existingHandle {
            state.leafByToken[existingHandle] = existingLeaf
        }

        return newLeaf
    }

    private func planSplit(
        targetRect: CGRect?,
        activeWindowFrame: CGRect?
    ) -> (orientation: DwindleOrientation, newFirst: Bool) {
        guard settings.smartSplit,
              let targetRect,
              let activeFrame = activeWindowFrame
        else {
            return (aspectOrientation(for: targetRect), false)
        }

        let targetCenter = targetRect.center
        let activeCenter = activeFrame.center

        let deltaX = activeCenter.x - targetCenter.x
        let deltaY = activeCenter.y - targetCenter.y

        let slope: CGFloat
        if abs(deltaX) < 0.001 {
            slope = .infinity
        } else {
            slope = deltaY / deltaX
        }

        let aspect: CGFloat
        if abs(targetRect.width) < 0.001 {
            aspect = .infinity
        } else {
            aspect = targetRect.height / targetRect.width
        }

        if abs(slope) < aspect {
            return (.horizontal, deltaX < 0)
        } else {
            return (.vertical, deltaY < 0)
        }
    }

    private func aspectOrientation(for rect: CGRect?) -> DwindleOrientation {
        guard let rect else { return .horizontal }
        if rect.height * settings.splitWidthMultiplier > rect.width {
            return .vertical
        }
        return .horizontal
    }

    func removeWindow(token: WindowToken, from workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        guard let state = states[workspaceId],
              let leaf = state.leafByToken[token]
        else { return }

        leaf.kind = .leaf(handle: nil, fullscreen: false)
        state.leafByToken.removeValue(forKey: token)
        cleanupAfterRemoval(leaf, state: state)
        if state.leafByToken.isEmpty {
            state.selectedNodeId = nil
        }
        releaseConstraintsIfUntracked(token)
    }

    @discardableResult
    func rekeyWindow(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard oldToken != newToken,
              let state = states[workspaceId],
              state.leafByToken[newToken] == nil,
              let leaf = state.leafByToken[oldToken],
              case let .leaf(_, fullscreen) = leaf.kind
        else {
            return false
        }

        leaf.kind = .leaf(handle: newToken, fullscreen: fullscreen)
        state.leafByToken.removeValue(forKey: oldToken)
        state.leafByToken[newToken] = leaf
        if let constraints = windowConstraints[oldToken] {
            windowConstraints[newToken] = constraints
        }
        releaseConstraintsIfUntracked(oldToken)
        return true
    }

    private func cleanupAfterRemoval(_ node: DwindleNode, state: DwindleWorkspaceState) {
        guard let parent = node.parent, let sibling = node.sibling() else { return }

        let promotedWindows = sibling.collectAllWindows()

        node.detach()

        parent.kind = sibling.kind
        parent.children = sibling.children
        for child in parent.children {
            child.parent = parent
        }

        for window in promotedWindows {
            if let leafNode = findLeafContaining(window, in: parent) {
                state.leafByToken[window] = leafNode
            }
        }

        if state.selectedNodeId == node.id {
            state.selectedNodeId = parent.descendToFirstLeaf().id
        }

        let selectionResolves = state.selectedNodeId.flatMap { findNodeById($0, in: state.root) } != nil
        if !selectionResolves {
            state.selectedNodeId = parent.descendToFirstLeaf().id
        }
    }

    private func findLeafContaining(_ handle: WindowToken, in root: DwindleNode) -> DwindleNode? {
        if case let .leaf(h, _) = root.kind, h == handle {
            return root
        }
        for child in root.children {
            if let found = findLeafContaining(handle, in: child) {
                return found
            }
        }
        return nil
    }

    func syncWindows(
        _ tokens: [WindowToken],
        in workspaceId: WorkspaceDescriptor.ID,
        focusedToken: WindowToken?,
        bootstrapScreen: CGRect? = nil,
        bootstrapFullscreenScreen: CGRect? = nil
    ) -> Set<WindowToken> {
        assertSanctionedMutation()
        let existingWindows: Set<WindowToken> = states[workspaceId].map { Set($0.leafByToken.keys) } ?? []
        let newWindows = Set(tokens)

        let toRemove = existingWindows.subtracting(newWindows)
        var queuedAdditions: Set<WindowToken> = []
        var toAdd: [WindowToken] = []
        toAdd.reserveCapacity(tokens.count)
        for token in tokens where !existingWindows.contains(token) {
            guard queuedAdditions.insert(token).inserted else { continue }
            toAdd.append(token)
        }

        for token in toRemove {
            removeWindow(token: token, from: workspaceId)
        }

        let shouldBootstrapIncrementally = bootstrapScreen != nil
            && !tokens.isEmpty
            && currentFrames(in: workspaceId).isEmpty
        if shouldBootstrapIncrementally,
           let bootstrapScreen,
           windowCount(in: workspaceId) > 0
        {
            _ = calculateLayout(
                for: workspaceId,
                screen: bootstrapScreen,
                fullscreenScreen: bootstrapFullscreenScreen ?? bootstrapScreen
            )
        }

        var activeFrame: CGRect?
        if let focusedToken, let node = findNode(for: focusedToken, in: workspaceId) {
            activeFrame = node.cachedFrame
        }
        if activeFrame == nil {
            activeFrame = selectedNode(in: workspaceId)?.cachedFrame
                ?? states[workspaceId]?.root.descendToFirstLeaf().cachedFrame
        }

        for token in toAdd {
            let newNode = addWindow(token: token, to: workspaceId, activeWindowFrame: activeFrame)
            if shouldBootstrapIncrementally, let bootstrapScreen {
                let frames = calculateLayout(
                    for: workspaceId,
                    screen: bootstrapScreen,
                    fullscreenScreen: bootstrapFullscreenScreen ?? bootstrapScreen
                )
                activeFrame = frames[token]
            } else {
                activeFrame = newNode.cachedFrame
            }
        }

        return toRemove
    }

    func calculateLayout(
        for workspaceId: WorkspaceDescriptor.ID,
        screen: CGRect,
        fullscreenScreen: CGRect? = nil
    ) -> [WindowToken: CGRect] {
        guard let state = states[workspaceId] else { return [:] }

        let windowCount = state.leafByToken.count
        if windowCount == 0 {
            return [:]
        }

        invalidateMinSizeCache(for: workspaceId)

        var output: [WindowToken: CGRect] = [:]
        let tilingArea = screen
        let fullscreenArea = fullscreenScreen ?? screen

        if windowCount == 1 {
            let leaf = state.root.descendToFirstLeaf()
            if case let .leaf(handle, fullscreen) = leaf.kind,
               let handle
            {
                let rect: CGRect
                if fullscreen {
                    rect = fullscreenArea
                } else {
                    rect = singleWindowRect(
                        screen: tilingArea,
                        fullscreenScreen: fullscreenArea,
                        minSize: constraints(for: handle).minSize
                    )
                }
                output[handle] = rect
                leaf.cachedFrame = rect
            }
        } else {
            calculateLayoutRecursive(
                node: state.root,
                rect: tilingArea,
                tilingArea: tilingArea,
                fullscreenArea: fullscreenArea,
                boundaryEdges: .all,
                output: &output
            )
        }

        return output
    }

    func currentFrames(in workspaceId: WorkspaceDescriptor.ID) -> [WindowToken: CGRect] {
        guard let root = states[workspaceId]?.root else { return [:] }
        var frames: [WindowToken: CGRect] = [:]
        collectCurrentFrames(node: root, into: &frames)
        return frames
    }

    private func collectCurrentFrames(node: DwindleNode, into frames: inout [WindowToken: CGRect]) {
        if case let .leaf(handle, _) = node.kind, let handle, let frame = node.cachedFrame {
            frames[handle] = frame
        }
        for child in node.children {
            collectCurrentFrames(node: child, into: &frames)
        }
    }

    func presentedFrames(in workspaceId: WorkspaceDescriptor.ID, at time: TimeInterval) -> [WindowToken: CGRect] {
        guard let root = states[workspaceId]?.root else { return [:] }
        var frames: [WindowToken: CGRect] = [:]
        collectPresentedFrames(node: root, at: time, into: &frames)
        return frames
    }

    private func collectPresentedFrames(
        node: DwindleNode,
        at time: TimeInterval,
        into frames: inout [WindowToken: CGRect]
    ) {
        if case let .leaf(handle, _) = node.kind, let handle, let frame = node.presentedFrame(at: time) {
            frames[handle] = frame
        }
        for child in node.children {
            collectPresentedFrames(node: child, at: time, into: &frames)
        }
    }

    func hitTestFocusableWindow(
        point: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        at time: TimeInterval
    ) -> WindowToken? {
        guard let root = states[workspaceId]?.root else { return nil }

        var firstVisibleMatch: WindowToken?
        return hitTestFocusableWindow(
            point: point,
            at: time,
            in: root,
            firstVisibleMatch: &firstVisibleMatch
        ) ?? firstVisibleMatch
    }

    private func hitTestFocusableWindow(
        point: CGPoint,
        at time: TimeInterval,
        in node: DwindleNode,
        firstVisibleMatch: inout WindowToken?
    ) -> WindowToken? {
        if case let .leaf(handle, fullscreen) = node.kind,
           let handle,
           let frame = presentedFrame(for: node, at: time),
           frame.contains(point)
        {
            if fullscreen {
                return handle
            }

            if firstVisibleMatch == nil {
                firstVisibleMatch = handle
            }
            return nil
        }

        for child in node.children {
            if let fullscreenMatch = hitTestFocusableWindow(
                point: point,
                at: time,
                in: child,
                firstVisibleMatch: &firstVisibleMatch
            ) {
                return fullscreenMatch
            }
        }

        return nil
    }

    private func presentedFrame(for node: DwindleNode, at time: TimeInterval) -> CGRect? {
        node.presentedFrame(at: time)
    }

    private func calculateLayoutRecursive(
        node: DwindleNode,
        rect: CGRect,
        tilingArea: CGRect,
        fullscreenArea: CGRect,
        boundaryEdges: ResizeEdge,
        output: inout [WindowToken: CGRect]
    ) {
        switch node.kind {
        case let .leaf(handle, fullscreen):
            guard let handle else { return }

            let target: CGRect
            if fullscreen {
                target = fullscreenArea
            } else {
                target = DwindleGapCalculator.applyGaps(
                    nodeRect: rect,
                    tilingArea: tilingArea,
                    settings: settings
                )
            }
            output[handle] = target
            node.cachedFrame = target

        case let .split(orientation, ratio):
            node.cachedFrame = rect

            let childEdges = splitChildBoundaryEdges(boundaryEdges, orientation: orientation)
            let firstMin: CGSize
            let secondMin: CGSize

            if let first = node.firstChild() {
                firstMin = computeMinSizeForSubtree(first, boundaryEdges: childEdges.first, cached: true)
            } else {
                firstMin = CGSize(width: 1, height: 1)
            }

            if let second = node.secondChild() {
                secondMin = computeMinSizeForSubtree(second, boundaryEdges: childEdges.second, cached: true)
            } else {
                secondMin = CGSize(width: 1, height: 1)
            }

            let (r1, r2) = splitRect(
                rect,
                orientation: orientation,
                ratio: ratio,
                firstMinSize: firstMin,
                secondMinSize: secondMin
            )

            if let first = node.firstChild() {
                calculateLayoutRecursive(
                    node: first,
                    rect: r1,
                    tilingArea: tilingArea,
                    fullscreenArea: fullscreenArea,
                    boundaryEdges: childEdges.first,
                    output: &output
                )
            }
            if let second = node.secondChild() {
                calculateLayoutRecursive(
                    node: second,
                    rect: r2,
                    tilingArea: tilingArea,
                    fullscreenArea: fullscreenArea,
                    boundaryEdges: childEdges.second,
                    output: &output
                )
            }
        }
    }

    private func splitChildBoundaryEdges(
        _ boundaryEdges: ResizeEdge,
        orientation: DwindleOrientation
    ) -> (first: ResizeEdge, second: ResizeEdge) {
        switch orientation {
        case .horizontal:
            (boundaryEdges.subtracting(.right), boundaryEdges.subtracting(.left))
        case .vertical:
            (boundaryEdges.subtracting(.top), boundaryEdges.subtracting(.bottom))
        }
    }

    private func computeMinSizeForSubtree(
        _ node: DwindleNode,
        boundaryEdges: ResizeEdge,
        cached: Bool
    ) -> CGSize {
        if cached, let cachedMin = node.cachedMinSize {
            return cachedMin
        }

        let result: CGSize
        switch node.kind {
        case let .leaf(handle, _):
            if let handle {
                var minSize = constraints(for: handle).minSize
                let inset = settings.innerGap / 2
                if !boundaryEdges.contains(.left) { minSize.width += inset }
                if !boundaryEdges.contains(.right) { minSize.width += inset }
                if !boundaryEdges.contains(.top) { minSize.height += inset }
                if !boundaryEdges.contains(.bottom) { minSize.height += inset }
                result = minSize
            } else {
                result = CGSize(width: 1, height: 1)
            }

        case let .split(orientation, _):
            guard let first = node.firstChild(), let second = node.secondChild() else {
                result = CGSize(width: 1, height: 1)
                break
            }

            let childEdges = splitChildBoundaryEdges(boundaryEdges, orientation: orientation)
            let firstMin = computeMinSizeForSubtree(first, boundaryEdges: childEdges.first, cached: cached)
            let secondMin = computeMinSizeForSubtree(second, boundaryEdges: childEdges.second, cached: cached)

            switch orientation {
            case .horizontal:
                result = CGSize(
                    width: firstMin.width + secondMin.width,
                    height: max(firstMin.height, secondMin.height)
                )
            case .vertical:
                result = CGSize(
                    width: max(firstMin.width, secondMin.width),
                    height: firstMin.height + secondMin.height
                )
            }
        }

        if cached {
            node.cachedMinSize = result
        }
        return result
    }

    private func tilingBoundaryEdges(of node: DwindleNode) -> ResizeEdge {
        var edges = ResizeEdge.all
        var child = node
        while let parent = child.parent {
            if case let .split(orientation, _) = parent.kind {
                switch orientation {
                case .horizontal:
                    edges.subtract(child.isFirstChild(of: parent) ? .right : .left)
                case .vertical:
                    edges.subtract(child.isFirstChild(of: parent) ? .top : .bottom)
                }
            }
            child = parent
        }
        return edges
    }

    private func feasibleRatioRange(for split: DwindleNode) -> ClosedRange<CGFloat>? {
        guard case let .split(orientation, _) = split.kind,
              let rect = split.cachedFrame,
              let first = split.firstChild(),
              let second = split.secondChild()
        else {
            return 0.1 ... 1.9
        }

        let childEdges = splitChildBoundaryEdges(tilingBoundaryEdges(of: split), orientation: orientation)
        let firstMinSize = computeMinSizeForSubtree(first, boundaryEdges: childEdges.first, cached: false)
        let secondMinSize = computeMinSizeForSubtree(second, boundaryEdges: childEdges.second, cached: false)

        let firstMin: CGFloat
        let secondMin: CGFloat
        let axisLength: CGFloat
        switch orientation {
        case .horizontal:
            firstMin = firstMinSize.width
            secondMin = secondMinSize.width
            axisLength = rect.width
        case .vertical:
            firstMin = firstMinSize.height
            secondMin = secondMinSize.height
            axisLength = rect.height
        }

        guard axisLength > 0 else { return 0.1 ... 1.9 }
        guard firstMin + secondMin <= axisLength else { return nil }

        let lower = max(0.1, 2 * firstMin / axisLength)
        let upper = min(1.9, 2 * (axisLength - secondMin) / axisLength)
        guard lower <= upper else {
            return 2 * firstMin / axisLength > 1.9 ? 1.9 ... 1.9 : 0.1 ... 0.1
        }
        return lower ... upper
    }

    func clampedRatioRespectingMinimums(_ ratio: CGFloat, for split: DwindleNode) -> CGFloat {
        guard let range = feasibleRatioRange(for: split) else {
            return split.splitRatio ?? settings.clampedRatio(ratio)
        }
        return min(max(ratio, range.lowerBound), range.upperBound)
    }

    private func invalidateMinSizeCache(for workspaceId: WorkspaceDescriptor.ID) {
        guard let root = states[workspaceId]?.root else { return }
        invalidateMinSizeCacheRecursive(root)
    }

    private func invalidateMinSizeCacheRecursive(_ node: DwindleNode) {
        node.cachedMinSize = nil
        for child in node.children {
            invalidateMinSizeCacheRecursive(child)
        }
    }

    private func splitRect(
        _ rect: CGRect,
        orientation: DwindleOrientation,
        ratio: CGFloat,
        firstMinSize: CGSize,
        secondMinSize: CGSize
    ) -> (CGRect, CGRect) {
        var fraction = settings.ratioToFraction(ratio)

        switch orientation {
        case .horizontal:
            let totalMin = firstMinSize.width + secondMinSize.width
            if totalMin > rect.width {
                fraction = firstMinSize.width / max(totalMin, 1)
            } else {
                let minFraction = firstMinSize.width / rect.width
                let maxFraction = (rect.width - secondMinSize.width) / rect.width
                fraction = max(minFraction, min(maxFraction, fraction))
            }

            let firstW = rect.width * fraction
            let secondW = rect.width - firstW
            let r1 = CGRect(x: rect.minX, y: rect.minY, width: firstW, height: rect.height)
            let r2 = CGRect(x: rect.minX + firstW, y: rect.minY, width: secondW, height: rect.height)
            return (r1, r2)

        case .vertical:
            let totalMin = firstMinSize.height + secondMinSize.height
            if totalMin > rect.height {
                fraction = firstMinSize.height / max(totalMin, 1)
            } else {
                let minFraction = firstMinSize.height / rect.height
                let maxFraction = (rect.height - secondMinSize.height) / rect.height
                fraction = max(minFraction, min(maxFraction, fraction))
            }

            let firstH = rect.height * fraction
            let secondH = rect.height - firstH
            let r1 = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstH)
            let r2 = CGRect(x: rect.minX, y: rect.minY + firstH, width: rect.width, height: secondH)
            return (r1, r2)
        }
    }

    private func singleWindowRect(screen: CGRect, fullscreenScreen: CGRect, minSize: CGSize) -> CGRect {
        let baseFrame = settings.singleWindowFit.mode == .fill ? fullscreenScreen : screen
        let fit = settings.singleWindowFit.frame(in: baseFrame)
        var rect = fit
        rect.size.width = min(max(fit.width, minSize.width), baseFrame.width)
        rect.size.height = min(max(fit.height, minSize.height), baseFrame.height)
        rect.origin.x = min(max(baseFrame.minX, fit.midX - rect.width / 2), baseFrame.maxX - rect.width)
        rect.origin.y = min(max(baseFrame.minY, fit.midY - rect.height / 2), baseFrame.maxY - rect.height)
        return rect
    }

    func findGeometricNeighbor(
        from handle: WindowToken,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WindowToken? {
        guard let state = states[workspaceId],
              let currentNode = state.leafByToken[handle],
              let currentFrame = currentNode.cachedFrame else { return nil }

        var candidates: [(handle: WindowToken, overlap: CGFloat)] = []

        collectNavigationCandidates(
            from: state.root,
            current: currentNode,
            currentFrame: currentFrame,
            direction: direction,
            innerGap: settings.innerGap,
            candidates: &candidates
        )

        guard !candidates.isEmpty else { return nil }

        let sorted = candidates.sorted { $0.overlap > $1.overlap }
        return sorted.first?.handle
    }

    private func collectNavigationCandidates(
        from node: DwindleNode,
        current: DwindleNode,
        currentFrame: CGRect,
        direction: Direction,
        innerGap: CGFloat,
        candidates: inout [(handle: WindowToken, overlap: CGFloat)]
    ) {
        if node.id == current.id {
            for child in node.children {
                collectNavigationCandidates(
                    from: child,
                    current: current,
                    currentFrame: currentFrame,
                    direction: direction,
                    innerGap: innerGap,
                    candidates: &candidates
                )
            }
            return
        }

        if node.isLeaf, let handle = node.windowToken, let candidateFrame = node.cachedFrame {
            if let overlap = calculateDirectionalOverlap(
                from: currentFrame,
                to: candidateFrame,
                direction: direction,
                innerGap: innerGap
            ) {
                candidates.append((handle, overlap))
            }
            return
        }

        for child in node.children {
            collectNavigationCandidates(
                from: child,
                current: current,
                currentFrame: currentFrame,
                direction: direction,
                innerGap: innerGap,
                candidates: &candidates
            )
        }
    }

    private func calculateDirectionalOverlap(
        from source: CGRect,
        to target: CGRect,
        direction: Direction,
        innerGap: CGFloat
    ) -> CGFloat? {
        let edgeThreshold = innerGap + 5.0
        let minOverlapRatio: CGFloat = 0.1

        switch direction {
        case .up:
            let edgesTouch = abs(source.maxY - target.minY) < edgeThreshold
            guard edgesTouch else { return nil }

            let overlapStart = max(source.minX, target.minX)
            let overlapEnd = min(source.maxX, target.maxX)
            let overlap = max(0, overlapEnd - overlapStart)

            let minRequired = min(source.width, target.width) * minOverlapRatio
            return overlap >= minRequired ? overlap : nil

        case .down:
            let edgesTouch = abs(source.minY - target.maxY) < edgeThreshold
            guard edgesTouch else { return nil }

            let overlapStart = max(source.minX, target.minX)
            let overlapEnd = min(source.maxX, target.maxX)
            let overlap = max(0, overlapEnd - overlapStart)

            let minRequired = min(source.width, target.width) * minOverlapRatio
            return overlap >= minRequired ? overlap : nil

        case .left:
            let edgesTouch = abs(source.minX - target.maxX) < edgeThreshold
            guard edgesTouch else { return nil }

            let overlapStart = max(source.minY, target.minY)
            let overlapEnd = min(source.maxY, target.maxY)
            let overlap = max(0, overlapEnd - overlapStart)

            let minRequired = min(source.height, target.height) * minOverlapRatio
            return overlap >= minRequired ? overlap : nil

        case .right:
            let edgesTouch = abs(source.maxX - target.minX) < edgeThreshold
            guard edgesTouch else { return nil }

            let overlapStart = max(source.minY, target.minY)
            let overlapEnd = min(source.maxY, target.maxY)
            let overlap = max(0, overlapEnd - overlapStart)

            let minRequired = min(source.height, target.height) * minOverlapRatio
            return overlap >= minRequired ? overlap : nil
        }
    }

    func moveFocus(direction: Direction, in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        assertSanctionedMutation()
        guard let current = selectedNode(in: workspaceId),
              let currentHandle = current.windowToken
        else {
            if let state = states[workspaceId] {
                let firstLeaf = state.root.descendToFirstLeaf()
                state.selectedNodeId = firstLeaf.id
                return firstLeaf.windowToken
            }
            return nil
        }

        guard let neighborHandle = findGeometricNeighbor(
            from: currentHandle,
            direction: direction,
            in: workspaceId
        ) else {
            return nil
        }

        if let neighborNode = findNode(for: neighborHandle, in: workspaceId) {
            states[workspaceId]?.selectedNodeId = neighborNode.id
        }
        return neighborHandle
    }

    func swapWindowOutcome(direction: Direction, in workspaceId: WorkspaceDescriptor.ID) -> WindowMoveOutcome {
        assertSanctionedMutation()
        guard let state = states[workspaceId],
              let current = selectedNode(in: workspaceId),
              case let .leaf(currentHandle, currentFullscreen) = current.kind,
              let ch = currentHandle
        else {
            return .blocked
        }

        guard let neighborHandle = findGeometricNeighbor(from: ch, direction: direction, in: workspaceId),
              let neighbor = state.leafByToken[neighborHandle],
              case let .leaf(nh, neighborFullscreen) = neighbor.kind
        else {
            return .atWorkspaceEdge
        }

        current.kind = .leaf(handle: nh, fullscreen: neighborFullscreen)
        neighbor.kind = .leaf(handle: currentHandle, fullscreen: currentFullscreen)

        let currentCachedFrame = current.cachedFrame
        current.cachedFrame = neighbor.cachedFrame
        neighbor.cachedFrame = currentCachedFrame

        current.clearAnimations()
        neighbor.clearAnimations()

        state.leafByToken[ch] = neighbor
        if let nh {
            state.leafByToken[nh] = current
        }

        state.selectedNodeId = neighbor.id

        return .movedWithinWorkspace
    }

    @discardableResult
    func toggleOrientation(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        assertSanctionedMutation()
        guard let selected = selectedNode(in: workspaceId),
              let parent = selected.parent,
              case let .split(orientation, ratio) = parent.kind
        else {
            return false
        }

        parent.kind = .split(orientation: orientation.perpendicular, ratio: ratio)
        return true
    }

    func toggleFullscreen(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        assertSanctionedMutation()
        guard let selected = selectedNode(in: workspaceId),
              case let .leaf(handle, fullscreen) = selected.kind
        else {
            return nil
        }

        selected.kind = .leaf(handle: handle, fullscreen: !fullscreen)
        return handle
    }

    @discardableResult
    func summonWindowRight(
        _ token: WindowToken,
        beside anchorToken: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard token != anchorToken,
              let sourceNode = findNode(for: token, in: workspaceId),
              let anchorNode = findNode(for: anchorToken, in: workspaceId),
              sourceNode.isLeaf,
              anchorNode.isLeaf
        else {
            return false
        }

        let preservedConstraints = windowConstraints[token]
        let preservedFullscreen = sourceNode.isFullscreen

        removeWindow(token: token, from: workspaceId)

        guard let updatedAnchorNode = findNode(for: anchorToken, in: workspaceId) else {
            return false
        }

        setSelectedNode(updatedAnchorNode, in: workspaceId)
        setPreselection(.right, in: workspaceId)

        let reinsertedLeaf = addWindow(
            token: token,
            to: workspaceId,
            activeWindowFrame: updatedAnchorNode.cachedFrame
        )

        if let preservedConstraints {
            updateWindowConstraints(for: token, constraints: preservedConstraints)
        }
        if preservedFullscreen {
            reinsertedLeaf.kind = .leaf(handle: token, fullscreen: true)
        }

        return true
    }

    @discardableResult
    func moveSelectionToRoot(stable: Bool, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        assertSanctionedMutation()
        guard let selected = selectedNode(in: workspaceId) else { return false }
        let leaf = selected.isLeaf ? selected : selected.descendToFirstLeaf()
        guard let root = states[workspaceId]?.root else { return false }

        if leaf.id == root.id { return false }

        guard let leafParent = leaf.parent else { return false }

        if leafParent.id == root.id { return false }

        var ancestor = leafParent
        while let parent = ancestor.parent, parent.id != root.id {
            ancestor = parent
        }

        guard ancestor.parent?.id == root.id else { return false }

        guard root.children.count == 2,
              let first = root.firstChild(),
              let second = root.secondChild() else { return false }

        let ancestorIsFirst = first.id == ancestor.id
        let swapNode = ancestorIsFirst ? second : first

        guard let leafSibling = leaf.sibling() else { return false }
        let leafIsFirst = leaf.isFirstChild(of: leafParent)

        leaf.detach()
        if ancestorIsFirst {
            leaf.insertAfter(ancestor)
        } else {
            leaf.insertBefore(ancestor)
        }

        swapNode.detach()
        if leafIsFirst {
            swapNode.insertBefore(leafSibling)
        } else {
            swapNode.insertAfter(leafSibling)
        }

        if stable, root.children.count == 2,
           let newFirst = root.firstChild()
        {
            newFirst.detach()
            root.appendChild(newFirst)
        }
        return true
    }

    @discardableResult
    func resizeSelected(
        by delta: CGFloat,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard let selected = selectedNode(in: workspaceId) else { return false }

        let targetOrientation = direction.dwindleOrientation
        let increaseFirst = !direction.isPositive

        var current = selected
        while let parent = current.parent {
            guard case let .split(orientation, ratio) = parent.kind else {
                current = parent
                continue
            }

            if orientation == targetOrientation {
                let isFirst = current.isFirstChild(of: parent)
                var newRatio = ratio

                if (isFirst && increaseFirst) || (!isFirst && !increaseFirst) {
                    newRatio += delta
                } else {
                    newRatio -= delta
                }

                let clampedRatio = clampedRatioRespectingMinimums(newRatio, for: parent)
                guard clampedRatio != ratio else { return false }
                parent.kind = .split(orientation: orientation, ratio: clampedRatio)
                return true
            }

            current = parent
        }
        return false
    }

    @discardableResult
    func resizeFocusedWindow(by delta: CGFloat, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        assertSanctionedMutation()
        guard let selected = selectedNode(in: workspaceId) else { return false }

        var current = selected
        while let parent = current.parent {
            guard case let .split(orientation, ratio) = parent.kind else {
                current = parent
                continue
            }
            let isFirst = current.isFirstChild(of: parent)
            let newRatio = isFirst ? ratio + delta : ratio - delta
            let clampedRatio = clampedRatioRespectingMinimums(newRatio, for: parent)
            guard clampedRatio != ratio else { return false }
            parent.kind = .split(orientation: orientation, ratio: clampedRatio)
            return true
        }
        return false
    }

    @discardableResult
    func balanceSizes(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        assertSanctionedMutation()
        guard let root = states[workspaceId]?.root else { return false }
        return balanceSizesRecursive(root)
    }

    private func balanceSizesRecursive(_ node: DwindleNode) -> Bool {
        guard case let .split(orientation, ratio) = node.kind else { return false }
        let target = clampedRatioRespectingMinimums(1.0, for: node)
        var changed = ratio != target
        if changed {
            node.kind = .split(orientation: orientation, ratio: target)
        }
        for child in node.children {
            changed = balanceSizesRecursive(child) || changed
        }
        return changed
    }

    @discardableResult
    func swapSplit(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        assertSanctionedMutation()
        guard let selected = selectedNode(in: workspaceId),
              let parent = selected.parent,
              parent.children.count == 2 else { return false }

        let first = parent.children[0]
        let second = parent.children[1]
        parent.children = [second, first]
        return true
    }

    @discardableResult
    func cycleSplitRatio(forward: Bool, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        assertSanctionedMutation()
        guard let selected = selectedNode(in: workspaceId),
              let parent = selected.parent,
              case let .split(orientation, currentRatio) = parent.kind else { return false }

        let presets: [CGFloat] = [0.3, 0.5, 0.7]

        let currentIndex = presets.enumerated().min(by: {
            abs($0.element - currentRatio) < abs($1.element - currentRatio)
        })?.offset ?? 1

        let newIndex: Int
        if forward {
            newIndex = (currentIndex + 1) % presets.count
        } else {
            newIndex = (currentIndex - 1 + presets.count) % presets.count
        }

        let newRatio = clampedRatioRespectingMinimums(presets[newIndex], for: parent)
        guard newRatio != currentRatio else { return false }
        parent.kind = .split(orientation: orientation, ratio: newRatio)
        return true
    }

    func tickAnimations(at time: TimeInterval, in workspaceId: WorkspaceDescriptor.ID) {
        guard let root = states[workspaceId]?.root else { return }
        tickAnimationsRecursive(root, at: time)
    }

    private func tickAnimationsRecursive(_ node: DwindleNode, at time: TimeInterval) {
        node.tickAnimations(at: time)
        for child in node.children {
            tickAnimationsRecursive(child, at: time)
        }
    }

    func hasActiveAnimations(in workspaceId: WorkspaceDescriptor.ID, at time: TimeInterval) -> Bool {
        guard let root = states[workspaceId]?.root else { return false }
        return hasActiveAnimationsRecursive(root, at: time)
    }

    private func hasActiveAnimationsRecursive(_ node: DwindleNode, at time: TimeInterval) -> Bool {
        if node.hasActiveAnimations(at: time) { return true }
        for child in node.children {
            if hasActiveAnimationsRecursive(child, at: time) { return true }
        }
        return false
    }

    func animateWindowMovements(
        oldFrames: [WindowToken: CGRect],
        previousTargetFrames: [WindowToken: CGRect],
        newFrames: [WindowToken: CGRect],
        in workspaceId: WorkspaceDescriptor.ID,
        startTime: TimeInterval,
        motion: MotionSnapshot
    ) {
        guard let state = states[workspaceId] else { return }
        for (handle, newFrame) in newFrames {
            guard let oldFrame = oldFrames[handle],
                  let node = state.leafByToken[handle] else { continue }

            let targetChanged = previousTargetFrames[handle].map {
                frameChanged($0, newFrame)
            } ?? true

            if targetChanged {
                node.animateFrom(
                    oldFrame: oldFrame,
                    newFrame: newFrame,
                    startTime: startTime,
                    config: windowMovementAnimationConfig,
                    animated: motion.animationsEnabled
                )
            }
        }
    }

    private func frameChanged(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) > 0.5 ||
            abs(lhs.origin.y - rhs.origin.y) > 0.5 ||
            abs(lhs.width - rhs.width) > 0.5 ||
            abs(lhs.height - rhs.height) > 0.5
    }

    func calculateAnimatedFrames(
        baseFrames: [WindowToken: CGRect],
        in workspaceId: WorkspaceDescriptor.ID,
        at time: TimeInterval
    ) -> [WindowToken: CGRect] {
        guard let state = states[workspaceId] else { return baseFrames }
        var result = baseFrames

        for (handle, frame) in baseFrames {
            guard let node = state.leafByToken[handle] else { continue }
            guard let presentedFrame = node.presentedFrame(at: time) else { continue }

            let hasAnimation = abs(presentedFrame.origin.x - frame.origin.x) > 0.1 ||
                abs(presentedFrame.origin.y - frame.origin.y) > 0.1 ||
                abs(presentedFrame.width - frame.width) > 0.1 ||
                abs(presentedFrame.height - frame.height) > 0.1

            if hasAnimation {
                result[handle] = presentedFrame
            }
        }

        return result
    }
}
