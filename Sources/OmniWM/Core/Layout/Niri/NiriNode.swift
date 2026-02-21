import AppKit
import Foundation

enum ColumnDisplay: Equatable {
    case normal

    case tabbed
}

enum SizingMode: Equatable {
    case normal

    case fullscreen
}

enum ProportionalSize: Equatable {
    case proportion(CGFloat)

    case fixed(CGFloat)

    var value: CGFloat {
        switch self {
        case let .proportion(p): p
        case let .fixed(f): f
        }
    }

    var isProportion: Bool {
        if case .proportion = self { return true }
        return false
    }

    var isFixed: Bool {
        if case .fixed = self { return true }
        return false
    }

    static let `default` = ProportionalSize.proportion(1.0)
}

enum WeightedSize: Equatable {
    case auto(weight: CGFloat)

    case fixed(CGFloat)

    var weight: CGFloat {
        switch self {
        case let .auto(w): w
        case .fixed: 0
        }
    }

    var isAuto: Bool {
        if case .auto = self { return true }
        return false
    }

    var isFixed: Bool {
        if case .fixed = self { return true }
        return false
    }

    static let `default` = WeightedSize.auto(weight: 1.0)
}

struct WindowSizeConstraints: Equatable {
    var minSize: CGSize

    var maxSize: CGSize

    var isFixed: Bool

    static let unconstrained = WindowSizeConstraints(
        minSize: CGSize(width: 1, height: 1),
        maxSize: .zero,
        isFixed: false
    )

    static func fixed(size: CGSize) -> WindowSizeConstraints {
        WindowSizeConstraints(
            minSize: size,
            maxSize: size,
            isFixed: true
        )
    }

    var hasMinWidth: Bool {
        minSize.width > 1
    }

    var hasMinHeight: Bool {
        minSize.height > 1
    }

    var hasMaxWidth: Bool {
        maxSize.width > 0
    }

    var hasMaxHeight: Bool {
        maxSize.height > 0
    }

    func clampHeight(_ height: CGFloat) -> CGFloat {
        var result = height
        if hasMinHeight {
            result = max(result, minSize.height)
        }
        if hasMaxHeight {
            result = min(result, maxSize.height)
        }
        return result
    }

    func clampWidth(_ width: CGFloat) -> CGFloat {
        var result = width
        if hasMinWidth {
            result = max(result, minSize.width)
        }
        if hasMaxWidth {
            result = min(result, maxSize.width)
        }
        return result
    }
}

struct PresetSize: Equatable {
    enum Kind: Equatable {
        case proportion(CGFloat)
        case fixed(CGFloat)

        var value: CGFloat {
            switch self {
            case let .proportion(p): p
            case let .fixed(f): f
            }
        }
    }

    let kind: Kind

    static func proportion(_ value: CGFloat) -> PresetSize {
        PresetSize(kind: .proportion(value))
    }

    static func fixed(_ value: CGFloat) -> PresetSize {
        PresetSize(kind: .fixed(value))
    }

    var asProportionalSize: ProportionalSize {
        switch kind {
        case let .proportion(p): .proportion(p)
        case let .fixed(f): .fixed(f)
        }
    }

}

struct NodeId: Hashable, Equatable {
    let uuid: UUID

    init() {
        uuid = UUID()
    }
}

class NiriNode {
    let id: NodeId
    weak var parent: NiriNode?
    private(set) var children: [NiriNode] = [] {
        didSet { invalidateChildrenCache() }
    }

    var size: CGFloat = 1.0

    var frame: CGRect?

    init() {
        id = NodeId()
    }

    func invalidateChildrenCache() {
        parent?.invalidateChildrenCache()
    }

    func findRoot() -> NiriRoot? {
        var current: NiriNode? = self
        while let node = current {
            if let root = node as? NiriRoot {
                return root
            }
            current = node.parent
        }
        return nil
    }

    func firstChild() -> NiriNode? {
        children.first
    }

    func lastChild() -> NiriNode? {
        children.last
    }

    func nextSibling() -> NiriNode? {
        guard let parent else { return nil }
        guard let index = parent.children.firstIndex(where: { $0 === self }) else { return nil }
        let nextIndex = index + 1
        guard nextIndex < parent.children.count else { return nil }
        return parent.children[nextIndex]
    }

    func prevSibling() -> NiriNode? {
        guard let parent else { return nil }
        guard let index = parent.children.firstIndex(where: { $0 === self }) else { return nil }
        guard index > 0 else { return nil }
        return parent.children[index - 1]
    }

    func appendChild(_ child: NiriNode) {
        child.detach()
        child.parent = self
        children.append(child)
        findRoot()?.registerNode(child)
    }

    func insertBefore(_ child: NiriNode, reference: NiriNode) {
        guard let index = children.firstIndex(where: { $0 === reference }) else {
            return
        }
        child.detach()
        child.parent = self
        children.insert(child, at: index)
        findRoot()?.registerNode(child)
    }

    func insertAfter(_ child: NiriNode, reference: NiriNode) {
        guard let index = children.firstIndex(where: { $0 === reference }) else {
            return
        }
        child.detach()
        child.parent = self
        children.insert(child, at: index + 1)
        findRoot()?.registerNode(child)
    }

    func detach() {
        guard let parent else { return }
        let root = findRoot()
        parent.children.removeAll { $0 === self }
        self.parent = nil
        root?.unregisterNode(self)
    }

    func remove() {
        detach()
        children.removeAll()
    }

    func swapWith(_ sibling: NiriNode) {
        guard let parent,
              parent === sibling.parent,
              let myIndex = parent.children.firstIndex(where: { $0 === self }),
              let sibIndex = parent.children.firstIndex(where: { $0 === sibling })
        else {
            return
        }
        parent.children.swapAt(myIndex, sibIndex)
    }

    func swapChildren(_ child1: NiriNode, _ child2: NiriNode) {
        guard let idx1 = children.firstIndex(where: { $0 === child1 }),
              let idx2 = children.firstIndex(where: { $0 === child2 })
        else {
            return
        }
        children.swapAt(idx1, idx2)
    }

    func insertChild(_ child: NiriNode, at index: Int) {
        child.detach()
        child.parent = self
        let clampedIndex = max(0, min(index, children.count))
        children.insert(child, at: clampedIndex)
        findRoot()?.registerNode(child)
    }

    func findNode(by id: NodeId) -> NiriNode? {
        if self.id == id {
            return self
        }
        for child in children {
            if let found = child.findNode(by: id) {
                return found
            }
        }
        return nil
    }
}

class NiriContainer: NiriNode {
    var displayMode: ColumnDisplay = .normal

    private(set) var activeTileIdx: Int = 0

    var width: ProportionalSize = .default

    var cachedWidth: CGFloat = 0

    var presetWidthIdx: Int?

    var isFullWidth: Bool = false

    var savedWidth: ProportionalSize?

    var height: ProportionalSize = .default

    var cachedHeight: CGFloat = 0

    var isFullHeight: Bool = false

    var savedHeight: ProportionalSize?

    var moveAnimation: MoveAnimation?

    var widthAnimation: SpringAnimation?
    var targetWidth: CGFloat?

    private var _cachedWindowNodes: [NiriWindow]?

    override init() {
        super.init()
    }

    override func invalidateChildrenCache() {
        _cachedWindowNodes = nil
        super.invalidateChildrenCache()
    }

    func animateMoveFrom(
        displacement: CGPoint,
        clock: AnimationClock?,
        config: SpringConfig = .default,
        displayRefreshRate: Double = 60.0,
        animationsEnabled: Bool = true
    ) {
        guard animationsEnabled else { return }
        let now = clock?.now() ?? CACurrentMediaTime()
        let currentOffset = renderOffset(at: now)
        let currentVel = moveAnimation?.currentVelocity(at: now) ?? 0

        if displacement.x != 0 {
            let totalOffsetX = displacement.x + currentOffset.x
            let anim = SpringAnimation(
                from: 1,
                to: 0,
                initialVelocity: currentVel,
                startTime: now,
                config: config,
                displayRefreshRate: displayRefreshRate
            )
            moveAnimation = MoveAnimation(animation: anim, fromOffset: totalOffsetX)
        }
    }

    func renderOffset(at time: TimeInterval = CACurrentMediaTime()) -> CGPoint {
        guard let anim = moveAnimation else { return .zero }
        return CGPoint(x: anim.currentOffset(at: time), y: 0)
    }

    func tickMoveAnimation(at time: TimeInterval) -> Bool {
        guard let anim = moveAnimation else { return false }
        if anim.isComplete(at: time) {
            moveAnimation = nil
            return false
        }
        return true
    }

    var hasMoveAnimationRunning: Bool {
        moveAnimation != nil
    }

    func offsetMoveAnimCurrent(_ offsetX: CGFloat) {
        guard let anim = moveAnimation else { return }
        let now = CACurrentMediaTime()
        let value = anim.animation.value(at: now)
        if value > 0.001 {
            moveAnimation = MoveAnimation(
                animation: anim.animation,
                fromOffset: anim.fromOffset + offsetX / CGFloat(value)
            )
        }
    }

    func animateWidthTo(
        newWidth: CGFloat,
        clock: AnimationClock?,
        config: SpringConfig,
        displayRefreshRate: Double = 60.0,
        animationsEnabled: Bool = true
    ) {
        guard animationsEnabled else { return }
        let now = clock?.now() ?? CACurrentMediaTime()
        let currentWidth = cachedWidth > 0 ? cachedWidth : newWidth
        let currentVel = widthAnimation?.velocity(at: now) ?? 0

        widthAnimation = SpringAnimation(
            from: Double(currentWidth),
            to: Double(newWidth),
            initialVelocity: currentVel,
            startTime: now,
            config: config,
            displayRefreshRate: displayRefreshRate
        )
        targetWidth = newWidth
    }

    func tickWidthAnimation(at time: TimeInterval) -> Bool {
        guard let anim = widthAnimation else { return false }

        cachedWidth = CGFloat(anim.value(at: time))

        if anim.isComplete(at: time) {
            if let target = targetWidth {
                cachedWidth = target
            }
            widthAnimation = nil
            targetWidth = nil
            return false
        }
        return true
    }

    var hasWidthAnimationRunning: Bool {
        widthAnimation != nil
    }

    private func resolveSpan(
        spec: ProportionalSize,
        isFull: Bool,
        availableSpace: CGFloat,
        gaps: CGFloat,
        minConstraint: CGFloat,
        maxConstraint: CGFloat?
    ) -> CGFloat {
        if isFull { return availableSpace }
        var result: CGFloat
        switch spec {
        case let .proportion(p):
            result = (availableSpace - gaps) * p
        case let .fixed(f):
            result = f
        }
        if result < minConstraint { result = minConstraint }
        if let maxConstraint, result > maxConstraint { result = maxConstraint }
        return result
    }

    func resolveAndCacheWidth(workingAreaWidth: CGFloat, gaps: CGFloat) {
        var minW: CGFloat = 0
        var maxW: CGFloat?
        for window in windowNodes {
            minW = max(minW, window.constraints.minSize.width)
            if window.constraints.hasMaxWidth {
                let candidateMax = window.constraints.maxSize.width
                maxW = min(maxW ?? candidateMax, candidateMax)
            }
        }
        cachedWidth = resolveSpan(spec: width, isFull: isFullWidth, availableSpace: workingAreaWidth, gaps: gaps, minConstraint: minW, maxConstraint: maxW)
    }

    func resolveAndCacheHeight(workingAreaHeight: CGFloat, gaps: CGFloat) {
        let minH = windowNodes.map(\.constraints.minSize.height).max() ?? 0
        let maxH = windowNodes.compactMap { $0.constraints.hasMaxHeight ? $0.constraints.maxSize.height : nil }.min()
        cachedHeight = resolveSpan(spec: height, isFull: isFullHeight, availableSpace: workingAreaHeight, gaps: gaps, minConstraint: minH, maxConstraint: maxH)
    }

    override var size: CGFloat {
        get { width.value }
        set {
            width = .proportion(newValue)
        }
    }

    func isFull(maxWindows: Int) -> Bool {
        children.count >= maxWindows
    }

    var windowNodes: [NiriWindow] {
        if let cached = _cachedWindowNodes { return cached }
        let result = children.compactMap { $0 as? NiriWindow }
        _cachedWindowNodes = result
        return result
    }

    var isTabbed: Bool {
        displayMode == .tabbed
    }

    var activeWindow: NiriWindow? {
        let windows = windowNodes
        guard !windows.isEmpty else { return nil }
        let idx = activeTileIdx.clamped(to: 0 ... (windows.count - 1))
        return windows[idx]
    }

    func clampActiveTileIdx() {
        let count = windowNodes.count
        if count == 0 {
            activeTileIdx = 0
        } else {
            activeTileIdx = activeTileIdx.clamped(to: 0 ... (count - 1))
        }
    }

    func setActiveTileIdx(_ idx: Int) {
        let count = windowNodes.count
        if count == 0 {
            activeTileIdx = 0
        } else {
            activeTileIdx = idx.clamped(to: 0 ... (count - 1))
        }
    }

    func adjustActiveTileIdxForRemoval(of node: NiriNode) {
        guard isTabbed else { return }
        let windows = windowNodes
        guard let idx = windows.firstIndex(where: { $0 === node }) else { return }
        if idx == activeTileIdx {
            if windows.count > 1, idx >= windows.count - 1 {
                activeTileIdx = max(0, idx - 1)
            }
        } else if idx < activeTileIdx {
            activeTileIdx = max(0, activeTileIdx - 1)
        }
    }

}

class NiriWindow: NiriNode {
    let handle: WindowHandle

    var sizingMode: SizingMode = .normal

    var height: WeightedSize = .default

    var savedHeight: WeightedSize?

    var windowWidth: WeightedSize = .default

    var constraints: WindowSizeConstraints = .unconstrained

    var resolvedHeight: CGFloat?

    var resolvedWidth: CGFloat?

    var heightFixedByConstraint: Bool = false

    var widthFixedByConstraint: Bool = false

    var lastFocusedTime: Date?

    var isHiddenInTabbedMode: Bool = false

    var moveXAnimation: MoveAnimation?
    var moveYAnimation: MoveAnimation?

    init(handle: WindowHandle) {
        self.handle = handle
        super.init()
    }

    override var size: CGFloat {
        get {
            switch height {
            case let .auto(weight): weight
            case .fixed: 1.0
            }
        }
        set {
            height = .auto(weight: newValue)
        }
    }

    var heightWeight: CGFloat {
        switch height {
        case let .auto(weight): weight
        case .fixed: 1.0
        }
    }

    var widthWeight: CGFloat {
        switch windowWidth {
        case let .auto(weight): weight
        case .fixed: 1.0
        }
    }

    var isFullscreen: Bool {
        sizingMode == .fullscreen
    }

    var windowId: UUID {
        handle.id
    }

    func renderOffset(at time: TimeInterval = CACurrentMediaTime()) -> CGPoint {
        var offset = CGPoint.zero
        if let moveX = moveXAnimation {
            offset.x = moveX.currentOffset(at: time)
        }
        if let moveY = moveYAnimation {
            offset.y = moveY.currentOffset(at: time)
        }
        return offset
    }

    func animateMoveFrom(
        displacement: CGPoint,
        clock: AnimationClock?,
        config: SpringConfig = .default,
        displayRefreshRate: Double = 60.0,
        animationsEnabled: Bool = true
    ) {
        guard animationsEnabled else { return }
        let now = clock?.now() ?? CACurrentMediaTime()
        let currentOffset = renderOffset(at: now)
        let currentVelX = moveXAnimation?.currentVelocity(at: now) ?? 0
        let currentVelY = moveYAnimation?.currentVelocity(at: now) ?? 0

        if displacement.x != 0 {
            let totalOffsetX = displacement.x + currentOffset.x
            let anim = SpringAnimation(
                from: 1,
                to: 0,
                initialVelocity: currentVelX,
                startTime: now,
                config: config,
                displayRefreshRate: displayRefreshRate
            )
            moveXAnimation = MoveAnimation(animation: anim, fromOffset: totalOffsetX)
        }
        if displacement.y != 0 {
            let totalOffsetY = displacement.y + currentOffset.y
            let anim = SpringAnimation(
                from: 1,
                to: 0,
                initialVelocity: currentVelY,
                startTime: now,
                config: config,
                displayRefreshRate: displayRefreshRate
            )
            moveYAnimation = MoveAnimation(animation: anim, fromOffset: totalOffsetY)
        }
    }

    func tickMoveAnimations(at time: TimeInterval) -> Bool {
        var running = false
        if let moveX = moveXAnimation {
            if moveX.isComplete(at: time) {
                moveXAnimation = nil
            } else {
                running = true
            }
        }
        if let moveY = moveYAnimation {
            if moveY.isComplete(at: time) {
                moveYAnimation = nil
            } else {
                running = true
            }
        }
        return running
    }

    func stopMoveAnimations() {
        moveXAnimation = nil
        moveYAnimation = nil
    }

    var hasMoveAnimationsRunning: Bool {
        moveXAnimation != nil || moveYAnimation != nil
    }

    var hasAnyAnimationRunning: Bool {
        hasMoveAnimationsRunning
    }
}

class NiriRoot: NiriContainer {
    let workspaceId: WorkspaceDescriptor.ID

    private var nodeIndex: [NodeId: NiriNode]?
    private var _cachedColumns: [NiriContainer]?
    private var _cachedAllWindows: [NiriWindow]?
    private var _cachedWindowIdSet: Set<UUID>?

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

    var windowIdSet: Set<UUID> {
        if let cached = _cachedWindowIdSet { return cached }
        let result = Set(allWindows.map(\.handle.id))
        _cachedWindowIdSet = result
        return result
    }

    func containsWindowId(_ id: UUID) -> Bool {
        windowIdSet.contains(id)
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

    override func findNode(by id: NodeId) -> NiriNode? {
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

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
