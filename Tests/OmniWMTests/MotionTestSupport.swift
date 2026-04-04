import AppKit
import Foundation

@testable import OmniWM

@MainActor
private enum SponsorsWindowControllerTestSharedState {
    static let controller = SponsorsWindowController(motionPolicy: MotionPolicy())
}

extension SponsorsWindowController {
    @MainActor
    static var shared: SponsorsWindowController {
        SponsorsWindowControllerTestSharedState.controller
    }
}

extension CommandPaletteController {
    convenience init(environment: CommandPaletteEnvironment = .init()) {
        self.init(motionPolicy: MotionPolicy(), environment: environment)
    }
}

extension WorkspaceBarManager {
    convenience init() {
        self.init(motionPolicy: MotionPolicy())
    }
}

extension NiriLayoutEngine {
    func animateColumnsForRemoval(
        columnIndex removedIdx: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        gaps: CGFloat
    ) -> ColumnRemovalResult {
        animateColumnsForRemoval(
            columnIndex: removedIdx,
            in: workspaceId,
            motion: .enabled,
            state: &state,
            gaps: gaps
        )
    }

    func ensureSelectionVisible(
        node: NiriNode,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat,
        orientation: Monitor.Orientation = .horizontal,
        animationConfig: SpringConfig? = nil,
        fromContainerIndex: Int? = nil,
        previousActiveContainerPosition: CGFloat? = nil
    ) {
        ensureSelectionVisible(
            node: node,
            in: workspaceId,
            motion: .enabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps,
            orientation: orientation,
            animationConfig: animationConfig,
            fromContainerIndex: fromContainerIndex,
            previousActiveContainerPosition: previousActiveContainerPosition
        )
    }

    func toggleFullscreen(_ window: NiriWindow, state: inout ViewportState) {
        toggleFullscreen(window, motion: .enabled, state: &state)
    }

    func moveWindow(
        _ node: NiriWindow,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        moveWindow(
            node,
            direction: direction,
            in: workspaceId,
            motion: .enabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    func toggleColumnWidth(
        _ column: NiriContainer,
        forwards: Bool,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        toggleColumnWidth(
            column,
            forwards: forwards,
            in: workspaceId,
            motion: .enabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    func toggleFullWidth(
        _ column: NiriContainer,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        toggleFullWidth(
            column,
            in: workspaceId,
            motion: .enabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    func balanceSizes(
        in workspaceId: WorkspaceDescriptor.ID,
        workingAreaWidth: CGFloat,
        gaps: CGFloat
    ) {
        balanceSizes(
            in: workspaceId,
            motion: .enabled,
            workingAreaWidth: workingAreaWidth,
            gaps: gaps
        )
    }

    func createColumnAndMove(
        _ node: NiriWindow,
        from sourceColumn: NiriContainer,
        direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        gaps: CGFloat,
        workingAreaWidth: CGFloat
    ) {
        createColumnAndMove(
            node,
            from: sourceColumn,
            direction: direction,
            in: workspaceId,
            motion: .enabled,
            state: &state,
            gaps: gaps,
            workingAreaWidth: workingAreaWidth
        )
    }

    @discardableResult
    func expelWindow(
        _ window: NiriWindow,
        to direction: Direction,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        expelWindow(
            window,
            to: direction,
            in: workspaceId,
            motion: .enabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    @discardableResult
    func insertWindowInNewColumn(
        _ window: NiriWindow,
        insertIndex: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        insertWindowInNewColumn(
            window,
            insertIndex: insertIndex,
            in: workspaceId,
            motion: .enabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    func interactiveMoveBegin(
        windowId: NodeId,
        windowHandle: WindowHandle,
        startLocation: CGPoint,
        isInsertMode: Bool = false,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        interactiveMoveBegin(
            windowId: windowId,
            windowHandle: windowHandle,
            startLocation: startLocation,
            isInsertMode: isInsertMode,
            in: workspaceId,
            motion: .enabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    func interactiveMoveEnd(
        at point: CGPoint,
        in workspaceId: WorkspaceDescriptor.ID,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) -> Bool {
        interactiveMoveEnd(
            at: point,
            in: workspaceId,
            motion: .enabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }

    func interactiveResizeEnd(
        windowId: NodeId? = nil,
        state: inout ViewportState,
        workingFrame: CGRect,
        gaps: CGFloat
    ) {
        interactiveResizeEnd(
            windowId: windowId,
            motion: .enabled,
            state: &state,
            workingFrame: workingFrame,
            gaps: gaps
        )
    }
}

extension NiriContainer {
    func animateMoveFrom(
        displacement: CGPoint,
        clock: AnimationClock?,
        config: SpringConfig = .default,
        displayRefreshRate: Double = 60.0
    ) {
        animateMoveFrom(
            displacement: displacement,
            clock: clock,
            config: config,
            displayRefreshRate: displayRefreshRate,
            animated: true
        )
    }
}

extension NiriWindow {
    func animateMoveFrom(
        displacement: CGPoint,
        clock: AnimationClock?,
        config: SpringConfig = .default,
        displayRefreshRate: Double = 60.0
    ) {
        animateMoveFrom(
            displacement: displacement,
            clock: clock,
            config: config,
            displayRefreshRate: displayRefreshRate,
            animated: true
        )
    }
}

extension DwindleNode {
    func animateFrom(
        oldFrame: CGRect,
        newFrame: CGRect,
        clock: AnimationClock?,
        config: CubicConfig
    ) {
        animateFrom(
            oldFrame: oldFrame,
            newFrame: newFrame,
            clock: clock,
            config: config,
            animated: true
        )
    }
}
