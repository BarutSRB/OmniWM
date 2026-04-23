// SPDX-License-Identifier: GPL-2.0-only
import COmniWMKernels
import CoreGraphics
import Foundation
import QuartzCore

private extension DwindleOrientation {
    var kernelRawValue: UInt32 {
        switch self {
        case .horizontal:
            UInt32(OMNIWM_DWINDLE_ORIENTATION_HORIZONTAL)
        case .vertical:
            UInt32(OMNIWM_DWINDLE_ORIENTATION_VERTICAL)
        }
    }
}

private enum DwindleKernelConstants {
    static let minimumDimension: CGFloat = 1
    static let gapSticksTolerance: CGFloat = 2
    static let splitRatioMin: CGFloat = 0.1
    static let splitRatioMax: CGFloat = 1.9
    static let splitFractionDivisor: CGFloat = 2
    static let splitFractionMin: CGFloat = 0.05
    static let splitFractionMax: CGFloat = 0.95
}

private struct DwindleKernelSnapshot {
    let rootIndex: Int32
    let nodes: ContiguousArray<DwindleNode>
    let rawNodes: ContiguousArray<omniwm_dwindle_node_input>
}

struct DwindleAnimationFrames {
    let frames: [WindowToken: CGRect]
    let animationsActive: Bool
}

final class DwindleLayoutEngine {
    private var roots: [WorkspaceDescriptor.ID: DwindleNode] = [:]
    private var tokenToNode: [WindowToken: DwindleNode] = [:]
    private var selectedNodeId: [WorkspaceDescriptor.ID: DwindleNodeId] = [:]
    private var preselection: [WorkspaceDescriptor.ID: Direction] = [:]
    private var windowConstraints: [WindowToken: WindowSizeConstraints] = [:]

    var settings: DwindleSettings = .init()
    var animationClock: AnimationClock?
    var displayRefreshRate: Double = 60.0

    func updateWindowConstraints(for token: WindowToken, constraints: WindowSizeConstraints) {
        windowConstraints[token] = constraints.normalized()
    }

    func constraints(for token: WindowToken) -> WindowSizeConstraints {
        windowConstraints[token] ?? .unconstrained
    }

    var windowMovementAnimationConfig: SpringConfig = .dwindle

    func root(for workspaceId: WorkspaceDescriptor.ID) -> DwindleNode? {
        roots[workspaceId]
    }

    func ensureRoot(for workspaceId: WorkspaceDescriptor.ID) -> DwindleNode {
        if let existing = roots[workspaceId] {
            return existing
        }
        let newRoot = DwindleNode(kind: .leaf(handle: nil, fullscreen: false))
        roots[workspaceId] = newRoot
        return newRoot
    }

    func removeLayout(for workspaceId: WorkspaceDescriptor.ID) {
        if let root = roots.removeValue(forKey: workspaceId) {
            for window in root.collectAllWindows() {
                tokenToNode.removeValue(forKey: window)
                windowConstraints.removeValue(forKey: window)
            }
        }
        selectedNodeId.removeValue(forKey: workspaceId)
    }

    func containsWindow(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let root = roots[workspaceId] else { return false }
        return root.collectAllWindows().contains(token)
    }

    func findNode(for token: WindowToken) -> DwindleNode? {
        tokenToNode[token]
    }

    func windowCount(in workspaceId: WorkspaceDescriptor.ID) -> Int {
        roots[workspaceId]?.collectAllWindows().count ?? 0
    }

    func selectedNode(in workspaceId: WorkspaceDescriptor.ID) -> DwindleNode? {
        guard let nodeId = selectedNodeId[workspaceId],
              let root = roots[workspaceId] else { return nil }
        return findNodeById(nodeId, in: root)
    }

    func setSelectedNode(_ node: DwindleNode?, in workspaceId: WorkspaceDescriptor.ID) {
        selectedNodeId[workspaceId] = node?.id
    }

    func setPreselection(_ direction: Direction?, in workspaceId: WorkspaceDescriptor.ID) {
        if let direction {
            preselection[workspaceId] = direction
        } else {
            preselection.removeValue(forKey: workspaceId)
        }
    }

    func getPreselection(in workspaceId: WorkspaceDescriptor.ID) -> Direction? {
        preselection[workspaceId]
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
        let root = ensureRoot(for: workspaceId)

        if case let .leaf(existingHandle, _) = root.kind, existingHandle == nil {
            root.kind = .leaf(handle: token, fullscreen: false)
            tokenToNode[token] = root
            selectedNodeId[workspaceId] = root.id
            return root
        }

        let targetNode: DwindleNode = if let selected = selectedNode(in: workspaceId), selected.isLeaf {
            selected
        } else {
            root.descendToFirstLeaf()
        }

        let preselectedDir = preselection[workspaceId]
        let newLeaf = splitLeaf(
            targetNode,
            newWindow: token,
            workspaceId: workspaceId,
            activeWindowFrame: activeWindowFrame,
            preselectedDirection: preselectedDir
        )
        preselection.removeValue(forKey: workspaceId)

        tokenToNode[token] = newLeaf
        selectedNodeId[workspaceId] = newLeaf.id
        return newLeaf
    }

    private func splitLeaf(
        _ leaf: DwindleNode,
        newWindow: WindowToken,
        workspaceId _: WorkspaceDescriptor.ID,
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
        if let targetRect {
            newLeaf.insertionSeed = DwindleInsertionSeed(
                sourceFrame: targetRect,
                orientation: orientation,
                appearsFirst: newFirst
            )
        }

        leaf.kind = .split(orientation: orientation, ratio: settings.defaultSplitRatio)

        if newFirst {
            leaf.replaceChildren(first: newLeaf, second: existingLeaf)
        } else {
            leaf.replaceChildren(first: existingLeaf, second: newLeaf)
        }

        if let existingHandle {
            tokenToNode[existingHandle] = existingLeaf
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

        let slope: CGFloat = if abs(deltaX) < 0.001 {
            .infinity
        } else {
            deltaY / deltaX
        }

        let aspect: CGFloat = if abs(targetRect.width) < 0.001 {
            .infinity
        } else {
            targetRect.height / targetRect.width
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
        guard let node = tokenToNode.removeValue(forKey: token) else { return }
        windowConstraints.removeValue(forKey: token)

        if case .leaf = node.kind {
            node.kind = .leaf(handle: nil, fullscreen: false)
        }

        cleanupAfterRemoval(node, in: workspaceId)
    }

    @discardableResult
    func rekeyWindow(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard oldToken != newToken,
              tokenToNode[newToken] == nil,
              let node = tokenToNode.removeValue(forKey: oldToken),
              roots[workspaceId] != nil
        else {
            return false
        }

        guard case let .leaf(handle, fullscreen) = node.kind, handle == oldToken else {
            tokenToNode[oldToken] = node
            return false
        }

        if let constraints = windowConstraints.removeValue(forKey: oldToken) {
            windowConstraints[newToken] = constraints
        }
        tokenToNode[newToken] = node
        node.kind = .leaf(handle: newToken, fullscreen: fullscreen)
        return true
    }

    private func cleanupAfterRemoval(_ node: DwindleNode, in workspaceId: WorkspaceDescriptor.ID) {
        guard let parent = node.parent else {
            if let root = roots[workspaceId], root.id == node.id {
                if case let .leaf(handle, _) = node.kind, handle == nil {
                    return
                }
            }
            return
        }

        guard let sibling = node.sibling() else { return }

        node.detach()

        parent.kind = sibling.kind
        parent.children = sibling.children
        for child in parent.children {
            child.parent = parent
        }

        for window in sibling.collectAllWindows() {
            if let leafNode = findLeafContaining(window, in: parent) {
                tokenToNode[window] = leafNode
            }
        }

        if let selectedId = selectedNodeId[workspaceId], selectedId == node.id {
            selectedNodeId[workspaceId] = parent.descendToFirstLeaf().id
        }

        if selectedNode(in: workspaceId) == nil {
            selectedNodeId[workspaceId] = parent.descendToFirstLeaf().id
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
        bootstrapScreen: CGRect? = nil
    ) -> Set<WindowToken> {
        let existingWindows = Set(roots[workspaceId]?.collectAllWindows() ?? [])
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
            _ = calculateLayout(for: workspaceId, screen: bootstrapScreen)
        }

        var activeFrame: CGRect?
        if let focusedToken, let node = tokenToNode[focusedToken] {
            activeFrame = node.cachedFrame
        }
        if activeFrame == nil {
            activeFrame = selectedNode(in: workspaceId)?.cachedFrame
                ?? roots[workspaceId]?.descendToFirstLeaf().cachedFrame
        }

        for token in toAdd {
            addWindow(token: token, to: workspaceId, activeWindowFrame: activeFrame)
            if shouldBootstrapIncrementally, let bootstrapScreen {
                let frames = calculateLayout(for: workspaceId, screen: bootstrapScreen)
                activeFrame = frames[token]
            } else if let newNode = tokenToNode[token] {
                activeFrame = newNode.cachedFrame
            }
        }

        return toRemove
    }

    func calculateLayout(
        for workspaceId: WorkspaceDescriptor.ID,
        screen: CGRect,
        scale: CGFloat? = nil
    ) -> [WindowToken: CGRect] {
        guard let root = roots[workspaceId] else { return [:] }

        let windowCount = root.collectAllWindows().count
        guard windowCount > 0 else { return [:] }

        let snapshot = makeKernelSnapshot(from: root)
        var rawInput = makeKernelInput(rootIndex: snapshot.rootIndex, screen: screen)
        var rawFrames = ContiguousArray(
            repeating: omniwm_dwindle_node_frame(
                x: 0,
                y: 0,
                width: 0,
                height: 0,
                has_frame: 0
            ),
            count: snapshot.rawNodes.count
        )

        let status = snapshot.rawNodes.withUnsafeBufferPointer { rawNodes in
            rawFrames.withUnsafeMutableBufferPointer { rawFrames in
                omniwm_dwindle_solve(
                    &rawInput,
                    rawNodes.baseAddress,
                    rawNodes.count,
                    rawFrames.baseAddress,
                    rawFrames.count
                )
            }
        }
        precondition(
            status == OMNIWM_KERNELS_STATUS_OK,
            "omniwm_dwindle_solve returned \(status)"
        )

        return applyKernelFrames(
            rawFrames,
            snapshot: snapshot,
            windowCount: windowCount,
            scale: scale
        )
    }

    private func makeKernelSnapshot(from root: DwindleNode) -> DwindleKernelSnapshot {
        var nodes = ContiguousArray<DwindleNode>()
        var rawNodes = ContiguousArray<omniwm_dwindle_node_input>()

        func append(_ node: DwindleNode) -> Int32 {
            precondition(rawNodes.count < Int(Int32.max), "Dwindle kernel snapshot exceeded Int32 capacity")

            let index = Int32(rawNodes.count)
            nodes.append(node)
            rawNodes.append(
                omniwm_dwindle_node_input(
                    first_child_index: -1,
                    second_child_index: -1,
                    split_ratio: 1.0,
                    min_width: 0,
                    min_height: 0,
                    kind: UInt32(OMNIWM_DWINDLE_NODE_KIND_LEAF),
                    orientation: UInt32(OMNIWM_DWINDLE_ORIENTATION_HORIZONTAL),
                    has_window: 0,
                    fullscreen: 0
                )
            )

            let firstChildIndex = node.firstChild().map(append) ?? -1
            let secondChildIndex = node.secondChild().map(append) ?? -1

            switch node.kind {
            case let .split(orientation, ratio):
                rawNodes[Int(index)] = omniwm_dwindle_node_input(
                    first_child_index: firstChildIndex,
                    second_child_index: secondChildIndex,
                    split_ratio: ratio,
                    min_width: 0,
                    min_height: 0,
                    kind: UInt32(OMNIWM_DWINDLE_NODE_KIND_SPLIT),
                    orientation: orientation.kernelRawValue,
                    has_window: 0,
                    fullscreen: 0
                )

            case let .leaf(handle, fullscreen):
                let minimumSize = if let handle {
                    constraints(for: handle).minSize
                } else {
                    CGSize(
                        width: DwindleKernelConstants.minimumDimension,
                        height: DwindleKernelConstants.minimumDimension
                    )
                }

                rawNodes[Int(index)] = omniwm_dwindle_node_input(
                    first_child_index: -1,
                    second_child_index: -1,
                    split_ratio: 1.0,
                    min_width: minimumSize.width,
                    min_height: minimumSize.height,
                    kind: UInt32(OMNIWM_DWINDLE_NODE_KIND_LEAF),
                    orientation: UInt32(OMNIWM_DWINDLE_ORIENTATION_HORIZONTAL),
                    has_window: handle == nil ? 0 : 1,
                    fullscreen: fullscreen ? 1 : 0
                )
            }

            return index
        }

        return DwindleKernelSnapshot(
            rootIndex: append(root),
            nodes: nodes,
            rawNodes: rawNodes
        )
    }

    private func makeKernelInput(
        rootIndex: Int32,
        screen: CGRect
    ) -> omniwm_dwindle_layout_input {
        omniwm_dwindle_layout_input(
            root_index: rootIndex,
            screen_x: screen.minX,
            screen_y: screen.minY,
            screen_width: screen.width,
            screen_height: screen.height,
            inner_gap: settings.innerGap,
            outer_gap_top: settings.outerGapTop,
            outer_gap_bottom: settings.outerGapBottom,
            outer_gap_left: settings.outerGapLeft,
            outer_gap_right: settings.outerGapRight,
            single_window_aspect_width: settings.singleWindowAspectRatio.width,
            single_window_aspect_height: settings.singleWindowAspectRatio.height,
            single_window_aspect_tolerance: settings.singleWindowAspectRatioTolerance,
            minimum_dimension: DwindleKernelConstants.minimumDimension,
            gap_sticks_tolerance: DwindleKernelConstants.gapSticksTolerance,
            split_ratio_min: DwindleKernelConstants.splitRatioMin,
            split_ratio_max: DwindleKernelConstants.splitRatioMax,
            split_fraction_divisor: DwindleKernelConstants.splitFractionDivisor,
            split_fraction_min: DwindleKernelConstants.splitFractionMin,
            split_fraction_max: DwindleKernelConstants.splitFractionMax
        )
    }

    private func applyKernelFrames(
        _ rawFrames: ContiguousArray<omniwm_dwindle_node_frame>,
        snapshot: DwindleKernelSnapshot,
        windowCount: Int,
        scale: CGFloat?
    ) -> [WindowToken: CGRect] {
        var frames: [WindowToken: CGRect] = [:]
        frames.reserveCapacity(windowCount)

        for (index, node) in snapshot.nodes.enumerated() {
            let rawFrame = rawFrames[index]
            guard rawFrame.has_frame != 0 else { continue }

            let frame = CGRect(
                x: rawFrame.x,
                y: rawFrame.y,
                width: rawFrame.width,
                height: rawFrame.height
            )
            let roundedFrame = roundedFrame(frame, scale: scale)
            node.cachedFrame = roundedFrame

            if case let .leaf(handle, _) = node.kind, let handle {
                frames[handle] = roundedFrame
            }
        }

        return frames
    }


    func currentFrames(in workspaceId: WorkspaceDescriptor.ID) -> [WindowToken: CGRect] {
        guard let root = roots[workspaceId] else { return [:] }
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

    func capturePresentedFrames(
        in workspaceId: WorkspaceDescriptor.ID,
        at time: TimeInterval,
        scale: CGFloat
    ) -> [WindowToken: CGRect] {
        let canonicalFrames = currentFrames(in: workspaceId)
        return calculateAnimatedFrames(
            baseFrames: canonicalFrames,
            in: workspaceId,
            at: time,
            scale: scale
        )
    }

    func hitTestFocusableWindow(
        point: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        at time: TimeInterval
    ) -> WindowToken? {
        guard let root = roots[workspaceId] else { return nil }

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
        guard let frame = node.cachedFrame else { return nil }

        let offset = node.renderOffset(at: time)
        let sizeOffset = node.renderSizeOffset(at: time)
        return CGRect(
            x: frame.origin.x + offset.x,
            y: frame.origin.y + offset.y,
            width: frame.width + sizeOffset.width,
            height: frame.height + sizeOffset.height
        )
    }

    func findGeometricNeighbor(
        from handle: WindowToken,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WindowToken? {
        guard let currentNode = findNode(for: handle),
              let currentFrame = currentNode.cachedFrame,
              let root = roots[workspaceId] else { return nil }

        var candidates: [(handle: WindowToken, overlap: CGFloat)] = []

        collectNavigationCandidates(
            from: root,
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
        guard let current = selectedNode(in: workspaceId),
              let currentHandle = current.windowToken
        else {
            if let root = roots[workspaceId] {
                let firstLeaf = root.descendToFirstLeaf()
                selectedNodeId[workspaceId] = firstLeaf.id
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

        if let neighborNode = findNode(for: neighborHandle) {
            selectedNodeId[workspaceId] = neighborNode.id
        }
        return neighborHandle
    }

    func swapWindows(direction: Direction, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let current = selectedNode(in: workspaceId),
              case let .leaf(currentHandle, currentFullscreen) = current.kind,
              let ch = currentHandle,
              let neighborHandle = findGeometricNeighbor(from: ch, direction: direction, in: workspaceId),
              let neighbor = findNode(for: neighborHandle),
              case let .leaf(nh, neighborFullscreen) = neighbor.kind
        else {
            return false
        }

        current.kind = .leaf(handle: nh, fullscreen: neighborFullscreen)
        neighbor.kind = .leaf(handle: currentHandle, fullscreen: currentFullscreen)

        let currentCachedFrame = current.cachedFrame
        current.cachedFrame = neighbor.cachedFrame
        neighbor.cachedFrame = currentCachedFrame

        current.moveXAnimation = nil
        current.moveYAnimation = nil
        current.sizeWAnimation = nil
        current.sizeHAnimation = nil

        neighbor.moveXAnimation = nil
        neighbor.moveYAnimation = nil
        neighbor.sizeWAnimation = nil
        neighbor.sizeHAnimation = nil

        tokenToNode[ch] = neighbor
        if let nh {
            tokenToNode[nh] = current
        }

        selectedNodeId[workspaceId] = neighbor.id

        return true
    }

    func toggleOrientation(in workspaceId: WorkspaceDescriptor.ID) {
        guard let selected = selectedNode(in: workspaceId),
              let parent = selected.parent,
              case let .split(orientation, ratio) = parent.kind
        else {
            return
        }

        parent.kind = .split(orientation: orientation.perpendicular, ratio: ratio)
    }

    func toggleFullscreen(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        guard let selected = selectedNode(in: workspaceId),
              case let .leaf(handle, fullscreen) = selected.kind
        else {
            return nil
        }

        let newFullscreen = !fullscreen
        if newFullscreen, let root = roots[workspaceId] {
            clearFullscreenFlags(in: root, except: selected.id)
        }
        selected.kind = .leaf(handle: handle, fullscreen: newFullscreen)
        return handle
    }

    private func clearFullscreenFlags(in node: DwindleNode, except selectedId: DwindleNodeId) {
        if case let .leaf(handle, fullscreen) = node.kind,
           fullscreen,
           node.id != selectedId
        {
            node.kind = .leaf(handle: handle, fullscreen: false)
        }

        for child in node.children {
            clearFullscreenFlags(in: child, except: selectedId)
        }
    }

    @discardableResult
    func summonWindowRight(
        _ token: WindowToken,
        beside anchorToken: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard token != anchorToken,
              let sourceNode = findNode(for: token),
              let anchorNode = findNode(for: anchorToken),
              sourceNode.isLeaf,
              anchorNode.isLeaf
        else {
            return false
        }

        let preservedConstraints = windowConstraints[token]
        let preservedFullscreen = sourceNode.isFullscreen

        removeWindow(token: token, from: workspaceId)

        guard let updatedAnchorNode = findNode(for: anchorToken) else {
            if let preservedConstraints {
                windowConstraints[token] = preservedConstraints
            }
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

    func moveSelectionToRoot(stable: Bool, in workspaceId: WorkspaceDescriptor.ID) {
        guard let selected = selectedNode(in: workspaceId) else { return }
        let leaf = selected.isLeaf ? selected : selected.descendToFirstLeaf()
        guard let root = roots[workspaceId] else { return }

        if leaf.id == root.id { return }

        guard let leafParent = leaf.parent else { return }

        if leafParent.id == root.id { return }

        var ancestor = leafParent
        while let parent = ancestor.parent, parent.id != root.id {
            ancestor = parent
        }

        guard ancestor.parent?.id == root.id else { return }

        guard root.children.count == 2,
              let first = root.firstChild(),
              let second = root.secondChild() else { return }

        let ancestorIsFirst = first.id == ancestor.id
        let swapNode = ancestorIsFirst ? second : first

        guard let leafSibling = leaf.sibling() else { return }
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
    }

    func resizeSelected(
        by delta: CGFloat,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let selected = selectedNode(in: workspaceId) else { return }

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

                parent.kind = .split(orientation: orientation, ratio: settings.clampedRatio(newRatio))
                return
            }

            current = parent
        }
    }

    func balanceSizes(in workspaceId: WorkspaceDescriptor.ID) {
        guard let root = roots[workspaceId] else { return }
        balanceSizesRecursive(root)
    }

    private func balanceSizesRecursive(_ node: DwindleNode) {
        guard case let .split(orientation, _) = node.kind else { return }
        node.kind = .split(orientation: orientation, ratio: 1.0)
        for child in node.children {
            balanceSizesRecursive(child)
        }
    }

    func swapSplit(in workspaceId: WorkspaceDescriptor.ID) {
        guard let selected = selectedNode(in: workspaceId),
              let parent = selected.parent,
              parent.children.count == 2 else { return }

        let first = parent.children[0]
        let second = parent.children[1]
        parent.children = [second, first]
    }

    func cycleSplitRatio(forward: Bool, in workspaceId: WorkspaceDescriptor.ID) {
        guard let selected = selectedNode(in: workspaceId),
              let parent = selected.parent,
              case let .split(orientation, currentRatio) = parent.kind else { return }

        let presets: [CGFloat] = [0.3, 0.5, 0.7]

        let currentIndex = presets.enumerated().min(by: {
            abs($0.element - currentRatio) < abs($1.element - currentRatio)
        })?.offset ?? 1

        let newIndex: Int = if forward {
            (currentIndex + 1) % presets.count
        } else {
            (currentIndex - 1 + presets.count) % presets.count
        }

        parent.kind = .split(orientation: orientation, ratio: presets[newIndex])
    }

    func tickAnimations(at time: TimeInterval, in workspaceId: WorkspaceDescriptor.ID) {
        guard let root = roots[workspaceId] else { return }
        tickAnimationsRecursive(root, at: time)
    }

    private func tickAnimationsRecursive(_ node: DwindleNode, at time: TimeInterval) {
        node.tickAnimations(at: time)
        for child in node.children {
            tickAnimationsRecursive(child, at: time)
        }
    }

    func clearAnimations(in workspaceId: WorkspaceDescriptor.ID) {
        guard let root = roots[workspaceId] else { return }
        clearAnimationsRecursive(root)
    }

    private func clearAnimationsRecursive(_ node: DwindleNode) {
        node.clearAnimations()
        node.insertionSeed = nil
        for child in node.children {
            clearAnimationsRecursive(child)
        }
    }

    func hasActiveAnimations(in workspaceId: WorkspaceDescriptor.ID, at time: TimeInterval) -> Bool {
        guard let root = roots[workspaceId] else { return false }
        return hasActiveAnimationsRecursive(root, at: time)
    }

    private func hasActiveAnimationsRecursive(_ node: DwindleNode, at time: TimeInterval) -> Bool {
        if node.hasActiveAnimations(at: time) { return true }
        for child in node.children {
            if hasActiveAnimationsRecursive(child, at: time) { return true }
        }
        return false
    }

    func prepareAnimationFramesForRelayout(
        oldFrames: [WindowToken: CGRect],
        newFrames: [WindowToken: CGRect],
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot,
        scale: CGFloat,
        at time: TimeInterval
    ) -> DwindleAnimationFrames {
        let pixelEpsilon = Self.pixelEpsilon(for: scale)
        guard motion.animationsEnabled else {
            clearAnimations(in: workspaceId)
            return DwindleAnimationFrames(frames: newFrames, animationsActive: false)
        }

        for (handle, newFrame) in newFrames {
            guard let node = tokenToNode[handle] else { continue }

            let seedOldFrame = node.insertionSeed?.startingFrame(
                for: newFrame,
                pixelEpsilon: pixelEpsilon
            )
            let oldFrame = oldFrames[handle] ?? seedOldFrame
            node.insertionSeed = nil

            guard let oldFrame else { continue }
            let changed = abs(oldFrame.origin.x - newFrame.origin.x) > pixelEpsilon ||
                abs(oldFrame.origin.y - newFrame.origin.y) > pixelEpsilon ||
                abs(oldFrame.width - newFrame.width) > pixelEpsilon ||
                abs(oldFrame.height - newFrame.height) > pixelEpsilon

            if changed {
                node.animateFrom(
                    oldFrame: oldFrame,
                    newFrame: newFrame,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate,
                    pixelEpsilon: pixelEpsilon,
                    animated: true
                )
            }
        }

        return animationFrames(
            from: newFrames,
            in: workspaceId,
            at: time,
            scale: scale
        )
    }

    func animationFrames(
        from baseFrames: [WindowToken: CGRect],
        in workspaceId: WorkspaceDescriptor.ID,
        at time: TimeInterval,
        scale: CGFloat
    ) -> DwindleAnimationFrames {
        let renderedFrames = calculateAnimatedFrames(
            baseFrames: baseFrames,
            in: workspaceId,
            at: time,
            scale: scale
        )
        return DwindleAnimationFrames(
            frames: renderedFrames,
            animationsActive: hasActiveAnimations(in: workspaceId, at: time)
        )
    }

    func animateWindowMovements(
        oldFrames: [WindowToken: CGRect],
        newFrames: [WindowToken: CGRect],
        motion: MotionSnapshot
    ) {
        let pixelEpsilon = Self.pixelEpsilon(for: 1.0)
        for (handle, newFrame) in newFrames {
            guard let oldFrame = oldFrames[handle],
                  let node = tokenToNode[handle] else { continue }

            let changed = abs(oldFrame.origin.x - newFrame.origin.x) > pixelEpsilon ||
                abs(oldFrame.origin.y - newFrame.origin.y) > pixelEpsilon ||
                abs(oldFrame.width - newFrame.width) > pixelEpsilon ||
                abs(oldFrame.height - newFrame.height) > pixelEpsilon

            if changed {
                node.animateFrom(
                    oldFrame: oldFrame,
                    newFrame: newFrame,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    displayRefreshRate: displayRefreshRate,
                    pixelEpsilon: pixelEpsilon,
                    animated: motion.animationsEnabled
                )
            }
        }
    }

    func calculateAnimatedFrames(
        baseFrames: [WindowToken: CGRect],
        in _: WorkspaceDescriptor.ID,
        at time: TimeInterval,
        scale: CGFloat? = nil
    ) -> [WindowToken: CGRect] {
        var result = baseFrames
        let pixelEpsilon = Self.pixelEpsilon(for: scale ?? 1.0)

        for (handle, frame) in baseFrames {
            guard let node = tokenToNode[handle] else { continue }
            let posOffset = node.renderOffset(at: time)
            let sizeOffset = node.renderSizeOffset(at: time)

            let hasAnimation = abs(posOffset.x) > pixelEpsilon || abs(posOffset.y) > pixelEpsilon ||
                abs(sizeOffset.width) > pixelEpsilon || abs(sizeOffset.height) > pixelEpsilon

            if hasAnimation {
                result[handle] = roundedFrame(
                    CGRect(
                        x: frame.origin.x + posOffset.x,
                        y: frame.origin.y + posOffset.y,
                        width: frame.width + sizeOffset.width,
                        height: frame.height + sizeOffset.height
                    ),
                    scale: scale
                )
            } else {
                result[handle] = roundedFrame(frame, scale: scale)
            }
        }

        return result
    }

    private static func pixelEpsilon(for scale: CGFloat) -> CGFloat {
        1.0 / max(scale, 1.0)
    }

    private func roundedFrame(_ frame: CGRect, scale: CGFloat?) -> CGRect {
        guard let scale else { return frame }
        return frame.roundedToPhysicalPixels(scale: scale)
    }
}
