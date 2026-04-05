import Foundation
import CoreGraphics
import QuartzCore

final class DwindleLayoutEngine {
    private var roots: [WorkspaceDescriptor.ID: DwindleNode] = [:]
    private var tokenToNode: [WindowToken: DwindleNode] = [:]
    private var selectedNodeId: [WorkspaceDescriptor.ID: DwindleNodeId] = [:]
    private var preselection: [WorkspaceDescriptor.ID: Direction] = [:]
    private var windowConstraints: [WindowToken: WindowSizeConstraints] = [:]

    var settings: DwindleSettings = DwindleSettings()
    private var monitorSettings: [Monitor.ID: ResolvedDwindleSettings] = [:]
    var animationClock: AnimationClock?
    var displayRefreshRate: Double = 60.0

    func updateWindowConstraints(for token: WindowToken, constraints: WindowSizeConstraints) {
        windowConstraints[token] = constraints.normalized()
    }

    func constraints(for token: WindowToken) -> WindowSizeConstraints {
        windowConstraints[token] ?? .unconstrained
    }

    func updateMonitorSettings(_ resolved: ResolvedDwindleSettings, for monitorId: Monitor.ID) {
        monitorSettings[monitorId] = resolved
    }

    func cleanupRemovedMonitor(_ monitorId: Monitor.ID) {
        monitorSettings.removeValue(forKey: monitorId)
    }

    func effectiveSettings(for monitorId: Monitor.ID) -> DwindleSettings {
        guard let resolved = monitorSettings[monitorId] else { return settings }

        var effective = settings
        effective.smartSplit = resolved.smartSplit
        effective.defaultSplitRatio = resolved.defaultSplitRatio
        effective.splitWidthMultiplier = resolved.splitWidthMultiplier
        if !resolved.singleWindowAspectRatio.isFillScreen {
            effective.singleWindowAspectRatio = resolved.singleWindowAspectRatio.size
        }
        if !resolved.useGlobalGaps {
            effective.innerGap = resolved.innerGap
            effective.outerGapTop = resolved.outerGapTop
            effective.outerGapBottom = resolved.outerGapBottom
            effective.outerGapLeft = resolved.outerGapLeft
            effective.outerGapRight = resolved.outerGapRight
        }
        return effective
    }

    var windowMovementAnimationConfig: CubicConfig = CubicConfig(duration: 0.3)

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

        let targetNode: DwindleNode
        if let selected = selectedNode(in: workspaceId), selected.isLeaf {
            targetNode = selected
        } else {
            targetNode = root.descendToFirstLeaf()
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
        workspaceId: WorkspaceDescriptor.ID,
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
              let activeFrame = activeWindowFrame else {
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
            let newSelected = parent.descendToFirstLeaf()
            selectedNodeId[workspaceId] = newSelected.id
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
        focusedToken: WindowToken?
    ) -> Set<WindowToken> {
        let existingWindows = Set(roots[workspaceId]?.collectAllWindows() ?? [])
        let newWindows = Set(tokens)

        let toRemove = existingWindows.subtracting(newWindows)
        let toAdd = newWindows.subtracting(existingWindows)

        for token in toRemove {
            removeWindow(token: token, from: workspaceId)
        }

        var activeFrame: CGRect?
        if let focusedToken, let node = tokenToNode[focusedToken] {
            activeFrame = node.cachedFrame
        }

        for token in toAdd {
            addWindow(token: token, to: workspaceId, activeWindowFrame: activeFrame)
            if let newNode = tokenToNode[token] {
                activeFrame = newNode.cachedFrame
            }
        }

        return toRemove
    }

    func calculateLayout(
        for workspaceId: WorkspaceDescriptor.ID,
        screen: CGRect
    ) -> [WindowToken: CGRect] {
        guard let root = roots[workspaceId] else { return [:] }

        let windowCount = root.collectAllWindows().count
        if windowCount == 0 {
            return [:]
        }

        invalidateMinSizeCache(for: workspaceId)

        var output: [WindowToken: CGRect] = [:]
        let tilingArea = DwindleGapCalculator.applyOuterGapsOnly(rect: screen, settings: settings)

        if windowCount == 1 {
            let leaf = root.descendToFirstLeaf()
            if case let .leaf(handle, fullscreen) = leaf.kind,
               let handle {
                let rect: CGRect
                if fullscreen {
                    rect = screen
                } else {
                    rect = singleWindowRect(screen: tilingArea)
                }
                output[handle] = rect
                leaf.cachedFrame = rect
            }
        } else {
            calculateLayoutRecursive(
                node: root,
                rect: tilingArea,
                tilingArea: tilingArea,
                output: &output
            )
        }

        return output
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

    private func calculateLayoutRecursive(
        node: DwindleNode,
        rect: CGRect,
        tilingArea: CGRect,
        output: inout [WindowToken: CGRect]
    ) {
        switch node.kind {
        case let .leaf(handle, fullscreen):
            guard let handle else { return }

            let target: CGRect
            if fullscreen {
                target = tilingArea
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

            let firstMin: CGSize
            let secondMin: CGSize

            if let first = node.firstChild() {
                firstMin = computeMinSizeForSubtree(first)
            } else {
                firstMin = CGSize(width: 1, height: 1)
            }

            if let second = node.secondChild() {
                secondMin = computeMinSizeForSubtree(second)
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
                calculateLayoutRecursive(node: first, rect: r1, tilingArea: tilingArea, output: &output)
            }
            if let second = node.secondChild() {
                calculateLayoutRecursive(node: second, rect: r2, tilingArea: tilingArea, output: &output)
            }
        }
    }

    private func computeMinSizeForSubtree(_ node: DwindleNode) -> CGSize {
        if let cached = node.cachedMinSize {
            return cached
        }

        let result: CGSize
        switch node.kind {
        case let .leaf(handle, _):
            if let handle {
                let c = constraints(for: handle)
                result = c.minSize
            } else {
                result = CGSize(width: 1, height: 1)
            }

        case let .split(orientation, _):
            guard let first = node.firstChild(), let second = node.secondChild() else {
                result = CGSize(width: 1, height: 1)
                break
            }

            let firstMin = computeMinSizeForSubtree(first)
            let secondMin = computeMinSizeForSubtree(second)

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

        node.cachedMinSize = result
        return result
    }

    private func invalidateMinSizeCache(for workspaceId: WorkspaceDescriptor.ID) {
        guard let root = roots[workspaceId] else { return }
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
                let totalMinClamped = max(totalMin, 1)
                fraction = firstMinSize.width / totalMinClamped
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
                let totalMinClamped = max(totalMin, 1)
                fraction = firstMinSize.height / totalMinClamped
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

    private func singleWindowRect(screen: CGRect) -> CGRect {
        let targetRatio = settings.singleWindowAspectRatio.width / settings.singleWindowAspectRatio.height
        let currentRatio = screen.width / screen.height

        if abs(targetRatio - currentRatio) < settings.singleWindowAspectRatioTolerance {
            return screen
        }

        var width = screen.width
        var height = screen.height

        if currentRatio > targetRatio {
            width = height * targetRatio
        } else {
            height = width / targetRatio
        }

        return CGRect(
            x: screen.minX + (screen.width - width) / 2,
            y: screen.minY + (screen.height - height) / 2,
            width: width,
            height: height
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
              let currentHandle = current.windowToken else {
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
              case let .leaf(nh, neighborFullscreen) = neighbor.kind else {
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
              case let .split(orientation, ratio) = parent.kind else {
            return
        }

        parent.kind = .split(orientation: orientation.perpendicular, ratio: ratio)
    }

    func toggleFullscreen(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        guard let selected = selectedNode(in: workspaceId),
              case let .leaf(handle, fullscreen) = selected.kind else {
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
           let newFirst = root.firstChild() {
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

        let newIndex: Int
        if forward {
            newIndex = (currentIndex + 1) % presets.count
        } else {
            newIndex = (currentIndex - 1 + presets.count) % presets.count
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

    func animateWindowMovements(
        oldFrames: [WindowToken: CGRect],
        newFrames: [WindowToken: CGRect],
        motion: MotionSnapshot
    ) {
        for (handle, newFrame) in newFrames {
            guard let oldFrame = oldFrames[handle],
                  let node = tokenToNode[handle] else { continue }

            let changed = abs(oldFrame.origin.x - newFrame.origin.x) > 0.5 ||
                          abs(oldFrame.origin.y - newFrame.origin.y) > 0.5 ||
                          abs(oldFrame.width - newFrame.width) > 0.5 ||
                          abs(oldFrame.height - newFrame.height) > 0.5

            if changed {
                node.animateFrom(
                    oldFrame: oldFrame,
                    newFrame: newFrame,
                    clock: animationClock,
                    config: windowMovementAnimationConfig,
                    animated: motion.animationsEnabled
                )
            }
        }
    }

    func calculateAnimatedFrames(
        baseFrames: [WindowToken: CGRect],
        in workspaceId: WorkspaceDescriptor.ID,
        at time: TimeInterval
    ) -> [WindowToken: CGRect] {
        var result = baseFrames

        for (handle, frame) in baseFrames {
            guard let node = tokenToNode[handle] else { continue }
            let posOffset = node.renderOffset(at: time)
            let sizeOffset = node.renderSizeOffset(at: time)

            let hasAnimation = abs(posOffset.x) > 0.1 || abs(posOffset.y) > 0.1 ||
                              abs(sizeOffset.width) > 0.1 || abs(sizeOffset.height) > 0.1

            if hasAnimation {
                result[handle] = CGRect(
                    x: frame.origin.x + posOffset.x,
                    y: frame.origin.y + posOffset.y,
                    width: frame.width + sizeOffset.width,
                    height: frame.height + sizeOffset.height
                )
            }
        }

        return result
    }
}
