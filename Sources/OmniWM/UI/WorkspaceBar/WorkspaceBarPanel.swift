import AppKit

@MainActor
final class WorkspaceBarPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect {
        frameRect
    }
}
