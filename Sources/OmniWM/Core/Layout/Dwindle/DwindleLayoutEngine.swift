import Foundation
import CoreGraphics
import QuartzCore

final class DwindleLayoutEngine {
    private var roots: [WorkspaceDescriptor.ID: DwindleNode] = [:]
    private var windowToNode: [WindowHandle: DwindleNode] = [:]
    private var selectedNodeId: [WorkspaceDescriptor.ID: DwindleNodeId] = [:]

    var settings: DwindleSettings = DwindleSettings()
    private var monitorSettings: [Monitor.ID: ResolvedDwindleSettings] = [:]
    var animationClock: AnimationClock?
    var displayRefreshRate: Double = 60.0

    func updateMonitorSettings(_ resolved: ResolvedDwindleSettings, for monitorId: Monitor.ID) {
        monitorSettings[monitorId] = resolved
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

    var windowMovementAnimationConfig: SpringConfig = SpringConfig(
        duration: 0.35,
        bounce: 0.0,
        epsilon: 0.0001,
        velocityEpsilon: 0.01
    )

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
                windowToNode.removeValue(forKey: window)
            }
        }
        selectedNodeId.removeValue(forKey: workspaceId)
    }

    func containsWindow(_ handle: WindowHandle, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let root = roots[workspaceId] else { return false }
        return root.collectAllWindows().contains(handle)
    }

    func findNode(for handle: WindowHandle) -> DwindleNode? {
        windowToNode[handle]
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
        handle: WindowHandle,
        to workspaceId: WorkspaceDescriptor.ID,
        activeWindowFrame: CGRect?
    ) -> DwindleNode {
        let root = ensureRoot(for: workspaceId)

        if case let .leaf(existingHandle, _) = root.kind, existingHandle == nil {
            root.kind = .leaf(handle: handle, fullscreen: false)
            windowToNode[handle] = root
            selectedNodeId[workspaceId] = root.id
            return root
        }

        let targetNode: DwindleNode
        if let selected = selectedNode(in: workspaceId), selected.isLeaf {
            targetNode = selected
        } else {
            targetNode = root.descendToFirstLeaf()
        }

        let newLeaf = splitLeaf(
            targetNode,
            newWindow: handle,
            workspaceId: workspaceId,
            activeWindowFrame: activeWindowFrame
        )

        windowToNode[handle] = newLeaf
        selectedNodeId[workspaceId] = newLeaf.id
        return newLeaf
    }

    private func splitLeaf(
        _ leaf: DwindleNode,
        newWindow: WindowHandle,
        workspaceId: WorkspaceDescriptor.ID,
        activeWindowFrame: CGRect?
    ) -> DwindleNode {
        guard case let .leaf(existingHandle, fullscreen) = leaf.kind else {
            let newLeaf = DwindleNode(kind: .leaf(handle: newWindow, fullscreen: false))
            leaf.appendChild(newLeaf)
            return newLeaf
        }

        let targetRect = leaf.cachedFrame
        let (orientation, newFirst) = planSplit(
            targetRect: targetRect,
            activeWindowFrame: activeWindowFrame
        )

        let existingLeaf = DwindleNode(kind: .leaf(handle: existingHandle, fullscreen: fullscreen))
        let newLeaf = DwindleNode(kind: .leaf(handle: newWindow, fullscreen: false))

        leaf.kind = .split(orientation: orientation, ratio: settings.defaultSplitRatio)

        if newFirst {
            leaf.replaceChildren(first: newLeaf, second: existingLeaf)
        } else {
            leaf.replaceChildren(first: existingLeaf, second: newLeaf)
        }

        if let existingHandle {
            windowToNode[existingHandle] = existingLeaf
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

    func removeWindow(handle: WindowHandle, from workspaceId: WorkspaceDescriptor.ID) {
        guard let node = windowToNode.removeValue(forKey: handle) else { return }

        if case .leaf = node.kind {
            node.kind = .leaf(handle: nil, fullscreen: false)
        }

        cleanupAfterRemoval(node, in: workspaceId)
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
                windowToNode[window] = leafNode
            }
        }

        if let selectedId = selectedNodeId[workspaceId], selectedId == node.id {
            let newSelected = parent.descendToFirstLeaf()
            selectedNodeId[workspaceId] = newSelected.id
        }
    }

    private func findLeafContaining(_ handle: WindowHandle, in root: DwindleNode) -> DwindleNode? {
        if case let .leaf(h, _) = root.kind, h === handle {
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
        _ handles: [WindowHandle],
        in workspaceId: WorkspaceDescriptor.ID,
        focusedHandle: WindowHandle?
    ) -> Set<WindowHandle> {
        let existingWindows = Set(roots[workspaceId]?.collectAllWindows() ?? [])
        let newWindows = Set(handles)

        let toRemove = existingWindows.subtracting(newWindows)
        let toAdd = newWindows.subtracting(existingWindows)

        for handle in toRemove {
            removeWindow(handle: handle, from: workspaceId)
        }

        var activeFrame: CGRect?
        if let focused = focusedHandle, let node = windowToNode[focused] {
            activeFrame = node.cachedFrame
        }

        for handle in toAdd {
            addWindow(handle: handle, to: workspaceId, activeWindowFrame: activeFrame)
            if let newNode = windowToNode[handle] {
                activeFrame = newNode.cachedFrame
            }
        }

        return toRemove
    }

    func calculateLayout(
        for workspaceId: WorkspaceDescriptor.ID,
        screen: CGRect
    ) -> [WindowHandle: CGRect] {
        guard let root = roots[workspaceId] else { return [:] }

        let windowCount = root.collectAllWindows().count
        if windowCount == 0 {
            return [:]
        }

        var output: [WindowHandle: CGRect] = [:]
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

    private func calculateLayoutRecursive(
        node: DwindleNode,
        rect: CGRect,
        tilingArea: CGRect,
        output: inout [WindowHandle: CGRect]
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
            let (r1, r2) = splitRect(rect, orientation: orientation, ratio: ratio)

            if let first = node.firstChild() {
                calculateLayoutRecursive(node: first, rect: r1, tilingArea: tilingArea, output: &output)
            }
            if let second = node.secondChild() {
                calculateLayoutRecursive(node: second, rect: r2, tilingArea: tilingArea, output: &output)
            }
        }
    }

    private func splitRect(
        _ rect: CGRect,
        orientation: DwindleOrientation,
        ratio: CGFloat
    ) -> (CGRect, CGRect) {
        let fraction = settings.ratioToFraction(ratio)

        switch orientation {
        case .horizontal:
            let firstW = rect.width * fraction
            let secondW = rect.width - firstW
            let r1 = CGRect(x: rect.minX, y: rect.minY, width: firstW, height: rect.height)
            let r2 = CGRect(x: rect.minX + firstW, y: rect.minY, width: secondW, height: rect.height)
            return (r1, r2)

        case .vertical:
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

    func findNeighbor(from node: DwindleNode, direction: Direction) -> DwindleNode? {
        let targetOrientation = direction.dwindleOrientation
        let goToSecond = direction.isPositive

        var current = node
        while let parent = current.parent {
            guard case let .split(orientation, _) = parent.kind else {
                current = parent
                continue
            }

            if orientation == targetOrientation {
                let isFirst = current.isFirstChild(of: parent)
                if goToSecond && isFirst {
                    if let second = parent.secondChild() {
                        return descendInDirection(second, direction: direction.opposite)
                    }
                } else if !goToSecond && !isFirst {
                    if let first = parent.firstChild() {
                        return descendInDirection(first, direction: direction.opposite)
                    }
                }
            }
            current = parent
        }

        return nil
    }

    private func descendInDirection(_ node: DwindleNode, direction: Direction) -> DwindleNode {
        var current = node
        let targetOrientation = direction.dwindleOrientation
        let preferSecond = direction.isPositive

        while !current.isLeaf {
            guard case let .split(orientation, _) = current.kind else { break }

            if orientation == targetOrientation {
                if preferSecond, let second = current.secondChild() {
                    current = second
                } else if let first = current.firstChild() {
                    current = first
                } else {
                    break
                }
            } else {
                if let first = current.firstChild() {
                    current = first
                } else {
                    break
                }
            }
        }

        return current
    }

    func findGeometricNeighbor(
        from handle: WindowHandle,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WindowHandle? {
        guard let currentNode = findNode(for: handle),
              let currentFrame = currentNode.cachedFrame,
              let root = roots[workspaceId] else { return nil }

        var candidates: [(handle: WindowHandle, overlap: CGFloat)] = []

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
        candidates: inout [(handle: WindowHandle, overlap: CGFloat)]
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

        if node.isLeaf, let handle = node.windowHandle, let candidateFrame = node.cachedFrame {
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

    func moveFocus(direction: Direction, in workspaceId: WorkspaceDescriptor.ID) -> WindowHandle? {
        guard let current = selectedNode(in: workspaceId),
              let currentHandle = current.windowHandle else {
            if let root = roots[workspaceId] {
                let firstLeaf = root.descendToFirstLeaf()
                selectedNodeId[workspaceId] = firstLeaf.id
                return firstLeaf.windowHandle
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

        windowToNode[ch] = neighbor
        if let nh {
            windowToNode[nh] = current
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

    func toggleFullscreen(in workspaceId: WorkspaceDescriptor.ID) -> WindowHandle? {
        guard let selected = selectedNode(in: workspaceId),
              case let .leaf(handle, fullscreen) = selected.kind else {
            return nil
        }

        selected.kind = .leaf(handle: handle, fullscreen: !fullscreen)
        return handle
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
        oldFrames: [WindowHandle: CGRect],
        newFrames: [WindowHandle: CGRect]
    ) {
        for (handle, newFrame) in newFrames {
            guard let oldFrame = oldFrames[handle],
                  let node = windowToNode[handle] else { continue }

            let moved = abs(oldFrame.origin.x - newFrame.origin.x) > 1 ||
                        abs(oldFrame.origin.y - newFrame.origin.y) > 1

            if moved {
                node.animateFrom(
                    oldFrame: oldFrame,
                    newFrame: newFrame,
                    clock: animationClock,
                    config: windowMovementAnimationConfig
                )
            }
        }
    }

    func calculateAnimatedFrames(
        baseFrames: [WindowHandle: CGRect],
        in workspaceId: WorkspaceDescriptor.ID,
        at time: TimeInterval
    ) -> [WindowHandle: CGRect] {
        var result = baseFrames

        for (handle, frame) in baseFrames {
            guard let node = windowToNode[handle] else { continue }
            let offset = node.renderOffset(at: time)
            if abs(offset.x) > 0.1 || abs(offset.y) > 0.1 {
                result[handle] = CGRect(
                    x: frame.origin.x + offset.x,
                    y: frame.origin.y + offset.y,
                    width: frame.width,
                    height: frame.height
                )
            }
        }

        return result
    }
}
