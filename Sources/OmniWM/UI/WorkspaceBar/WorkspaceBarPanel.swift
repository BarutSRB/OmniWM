import AppKit

@MainActor
final class WorkspaceBarPanel: NSPanel {
    var targetScreen: NSScreen?

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let constrainingScreen = targetScreen ?? screen else {
            return frameRect
        }

        var constrained = frameRect
        let screenFrame = constrainingScreen.frame

        constrained.origin.x = max(screenFrame.minX, min(constrained.origin.x, screenFrame.maxX - constrained.width))
        constrained.origin.y = max(screenFrame.minY, min(constrained.origin.y, screenFrame.maxY - constrained.height))

        return constrained
    }
}
