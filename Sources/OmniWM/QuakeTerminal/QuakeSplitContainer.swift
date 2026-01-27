import Cocoa
import GhosttyKit

@MainActor
final class QuakeSplitContainer: NSView {
    private(set) var root: SplitNode
    private(set) var focusedView: GhosttySurfaceView?
    private var dividerViews: [SplitDividerView] = []

    private let dividerThickness: CGFloat = 4

    var onFocusChanged: ((GhosttySurfaceView) -> Void)?

    override var isFlipped: Bool { false }

    init(initialView: GhosttySurfaceView) {
        self.root = .leaf(initialView)
        self.focusedView = initialView
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        addSubview(initialView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func allSurfaceViews() -> [GhosttySurfaceView] {
        root.allSurfaceViews()
    }

    func split(view: GhosttySurfaceView, direction: SplitDirection, newView: GhosttySurfaceView) {
        root = root.inserting(at: view, direction: direction, newView: newView)
        addSubview(newView)
        focusedView = newView
        relayout()
    }

    func remove(view: GhosttySurfaceView) -> Bool {
        guard let newRoot = root.removing(view) else {
            return false
        }
        view.removeFromSuperview()
        root = newRoot

        if focusedView === view {
            focusedView = root.allSurfaceViews().first
        }

        relayout()
        return true
    }

    func contains(view: GhosttySurfaceView) -> Bool {
        root.contains(view)
    }

    func focus(view: GhosttySurfaceView) {
        focusedView = view
        window?.makeFirstResponder(view)
        onFocusChanged?(view)
    }

    func navigate(direction: NavigationDirection) {
        guard let focused = focusedView else { return }
        if let neighbor = root.findNeighbor(of: focused, direction: direction, in: bounds) {
            focus(view: neighbor)
        }
    }

    func equalize() {
        root = root.equalized()
        relayout()
    }

    func relayout() {
        let leafBounds = root.calculateBounds(in: bounds)
        for lb in leafBounds {
            lb.view.frame = lb.rect
        }

        for dv in dividerViews {
            dv.removeFromSuperview()
        }
        dividerViews.removeAll()

        let dividerInfos = root.calculateDividers(in: bounds, thickness: dividerThickness)
        for info in dividerInfos {
            let dv = SplitDividerView(info: info, container: self)
            dv.frame = info.rect
            addSubview(dv)
            dividerViews.append(dv)
        }

        updateSurfaceSizes()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        relayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    private func updateSurfaceSizes() {
        guard let window else { return }
        let scale = window.backingScaleFactor
        for view in root.allSurfaceViews() {
            guard let surface = view.ghosttySurface else { continue }
            let size = view.frame.size
            ghostty_surface_set_size(surface, UInt32(size.width * scale), UInt32(size.height * scale))
        }
    }

    func handleDividerDrag(info: SplitNode.DividerInfo, delta: CGFloat) {
        guard let leftView = info.leftViews.first else { return }

        let totalSize: CGFloat
        switch info.direction {
        case .horizontal: totalSize = bounds.width
        case .vertical: totalSize = bounds.height
        }

        guard totalSize > 0 else { return }
        let ratioDelta = delta / totalSize
        let newRatio = min(max(info.currentRatio + ratioDelta, 0.1), 0.9)

        root = root.updatingRatioForSplit(containing: leftView, newRatio: newRatio)
        relayout()
    }
}

@MainActor
private final class SplitDividerView: NSView {
    private let info: SplitNode.DividerInfo
    private weak var container: QuakeSplitContainer?
    private var dragStart: NSPoint?

    override var isFlipped: Bool { false }

    init(info: SplitNode.DividerInfo, container: QuakeSplitContainer) {
        self.info = info
        self.container = container
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.3, alpha: 1).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch info.direction {
        case .horizontal: cursor = .resizeLeftRight
        case .vertical: cursor = .resizeUpDown
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let current = NSEvent.mouseLocation
        let delta: CGFloat
        switch info.direction {
        case .horizontal: delta = current.x - start.x
        case .vertical: delta = -(current.y - start.y)
        }
        dragStart = current
        container?.handleDividerDrag(info: info, delta: delta)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }
}
