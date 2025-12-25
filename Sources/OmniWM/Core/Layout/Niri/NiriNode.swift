import AppKit
import Foundation

enum ColumnDisplay: Equatable {
    case normal

    case tabbed
}

enum SizingMode: Equatable {
    case normal

    case maximized

    case fullscreen
}

enum ColumnWidth: Equatable {
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

    static let `default` = ColumnWidth.proportion(1.0)
}

enum WindowHeight: Equatable {
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

    static let `default` = WindowHeight.auto(weight: 1.0)
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

    var asColumnWidth: ColumnWidth {
        switch kind {
        case let .proportion(p): .proportion(p)
        case let .fixed(f): .fixed(f)
        }
    }

    var asWindowHeight: WindowHeight {
        switch kind {
        case let .proportion(p): .auto(weight: p)
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
    var children: [NiriNode] = []

    var size: CGFloat = 1.0

    var frame: CGRect?

    init() {
        id = NodeId()
    }

    func firstChild() -> NiriNode? {
        children.first
    }

    func lastChild() -> NiriNode? {
        children.last
    }

    func nextSibling() -> NiriNode? {
        guard let parent else { return nil }
        guard let index = parent.children.firstIndex(where: { $0.id == self.id }) else { return nil }
        let nextIndex = index + 1
        guard nextIndex < parent.children.count else { return nil }
        return parent.children[nextIndex]
    }

    func prevSibling() -> NiriNode? {
        guard let parent else { return nil }
        guard let index = parent.children.firstIndex(where: { $0.id == self.id }) else { return nil }
        guard index > 0 else { return nil }
        return parent.children[index - 1]
    }

    func appendChild(_ child: NiriNode) {
        child.detach()
        child.parent = self
        children.append(child)
    }

    func insertBefore(_ child: NiriNode, reference: NiriNode) {
        guard let index = children.firstIndex(where: { $0.id == reference.id }) else {
            return
        }
        child.detach()
        child.parent = self
        children.insert(child, at: index)
    }

    func insertAfter(_ child: NiriNode, reference: NiriNode) {
        guard let index = children.firstIndex(where: { $0.id == reference.id }) else {
            return
        }
        child.detach()
        child.parent = self
        children.insert(child, at: index + 1)
    }

    func detach() {
        guard let parent else { return }
        parent.children.removeAll { $0.id == self.id }
        self.parent = nil
    }

    func remove() {
        detach()

        for child in children {
            child.remove()
        }
        children.removeAll()
    }

    func swapWith(_ sibling: NiriNode) {
        guard let parent,
              parent.id == sibling.parent?.id,
              let myIndex = parent.children.firstIndex(where: { $0.id == self.id }),
              let sibIndex = parent.children.firstIndex(where: { $0.id == sibling.id })
        else {
            return
        }
        parent.children.swapAt(myIndex, sibIndex)
    }

    func swapChildren(_ child1: NiriNode, _ child2: NiriNode) {
        guard let idx1 = children.firstIndex(where: { $0.id == child1.id }),
              let idx2 = children.firstIndex(where: { $0.id == child2.id })
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

    var descendantCount: Int {
        children.reduce(children.count) { $0 + $1.descendantCount }
    }
}

class NiriContainer: NiriNode {
    var displayMode: ColumnDisplay = .normal

    var activeTileIdx: Int = 0

    var width: ColumnWidth = .default

    var presetWidthIdx: Int?

    var isFullWidth: Bool = false

    var savedWidth: ColumnWidth?

    var activatePrevRestoreStart: CGFloat?

    override init() {
        super.init()
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
        children.compactMap { $0 as? NiriWindow }
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

    func resolveWidth(
        workingAreaWidth: CGFloat,
        totalProportionalWeight: CGFloat,
        gaps: CGFloat
    ) -> CGFloat {
        if isFullWidth {
            return workingAreaWidth - gaps
        }

        switch width {
        case let .proportion(p):
            guard totalProportionalWeight > 0 else { return workingAreaWidth - gaps }
            return (workingAreaWidth - gaps) * (p / totalProportionalWeight)
        case let .fixed(f):
            return min(f, workingAreaWidth - gaps)
        }
    }
}

class NiriWindow: NiriNode {
    let handle: WindowHandle

    var sizingMode: SizingMode = .normal

    var height: WindowHeight = .default

    var presetHeightIdx: Int?

    var savedHeight: WindowHeight?

    var savedColumnWidth: ColumnWidth?

    var constraints: WindowSizeConstraints = .unconstrained

    var resolvedHeight: CGFloat?

    var heightFixedByConstraint: Bool = false

    var lastFocusedTime: Date?

    var isHiddenInTabbedMode: Bool = false

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

    func resolveHeight(availableHeight: CGFloat, totalWeight: CGFloat) -> CGFloat {
        switch height {
        case let .auto(weight):
            guard totalWeight > 0 else { return availableHeight }
            return availableHeight * (weight / totalWeight)
        case let .fixed(f):
            return min(f, availableHeight)
        }
    }

    var isFullscreen: Bool {
        sizingMode == .fullscreen
    }

    var isMaximized: Bool {
        sizingMode == .maximized
    }

    var isFullscreenOrMaximized: Bool {
        sizingMode != .normal
    }

    var windowId: UUID {
        handle.id
    }
}

class NiriRoot: NiriContainer {
    let workspaceId: WorkspaceDescriptor.ID

    init(workspaceId: WorkspaceDescriptor.ID) {
        self.workspaceId = workspaceId
        super.init()
    }

    var columns: [NiriContainer] {
        children.compactMap { $0 as? NiriContainer }
    }

    var allWindows: [NiriWindow] {
        columns.flatMap(\.windowNodes)
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
