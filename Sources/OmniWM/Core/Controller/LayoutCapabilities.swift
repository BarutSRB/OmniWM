@MainActor protocol LayoutFocusable: AnyObject {
    func focusNeighbor(direction: Direction)
}

@MainActor protocol LayoutSwappable: AnyObject {
    func swapWindow(direction: Direction)
    func toggleFullscreen()
}

@MainActor protocol LayoutSizable: AnyObject {
    func cycleSize(forward: Bool)
    func balanceSizes()
}
