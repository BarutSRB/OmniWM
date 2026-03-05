import AppKit
import Foundation

extension CGFloat {
    func roundedToPhysicalPixel(scale: CGFloat) -> CGFloat {
        (self * scale).rounded() / scale
    }
}

extension CGPoint {
    func roundedToPhysicalPixels(scale: CGFloat) -> CGPoint {
        CGPoint(
            x: x.roundedToPhysicalPixel(scale: scale),
            y: y.roundedToPhysicalPixel(scale: scale)
        )
    }
}

extension CGSize {
    func roundedToPhysicalPixels(scale: CGFloat) -> CGSize {
        CGSize(
            width: width.roundedToPhysicalPixel(scale: scale),
            height: height.roundedToPhysicalPixel(scale: scale)
        )
    }
}

extension CGRect {
    func roundedToPhysicalPixels(scale: CGFloat) -> CGRect {
        CGRect(
            origin: origin.roundedToPhysicalPixels(scale: scale),
            size: size.roundedToPhysicalPixels(scale: scale)
        )
    }
}

struct LayoutResult {
    let frames: [WindowHandle: CGRect]
    let hiddenHandles: [WindowHandle: HideSide]
}

extension NiriLayoutEngine {
    private func workspaceSwitchOffset(
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        time: TimeInterval
    ) -> CGFloat {
        guard let monitorId = monitorContaining(workspace: workspaceId),
              let monitor = monitors[monitorId],
              let workspaceIndex = monitor.workspaceOrder.firstIndex(of: workspaceId) else {
            return 0
        }

        let renderIndex = monitor.workspaceRenderIndex(at: time)
        let delta = Double(workspaceIndex) - renderIndex
        if abs(delta) < 0.001 {
            return 0
        }

        let reduceMotionScale: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.25 : 1.0
        return CGFloat(delta) * monitorFrame.width * reduceMotionScale
    }

    func calculateLayout(
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil,
        orientation: Monitor.Orientation = .horizontal
    ) -> [WindowHandle: CGRect] {
        calculateLayoutWithVisibility(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: monitorFrame,
            screenFrame: screenFrame,
            gaps: gaps,
            scale: scale,
            workingArea: workingArea,
            orientation: orientation
        ).frames
    }

    func calculateLayoutWithVisibility(
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil,
        orientation: Monitor.Orientation = .horizontal,
        animationTime: TimeInterval? = nil
    ) -> LayoutResult {
        var frames: [WindowHandle: CGRect] = [:]
        var hiddenHandles: [WindowHandle: HideSide] = [:]
        calculateLayoutInto(
            frames: &frames,
            hiddenHandles: &hiddenHandles,
            state: state,
            workspaceId: workspaceId,
            monitorFrame: monitorFrame,
            screenFrame: screenFrame,
            gaps: gaps,
            scale: scale,
            workingArea: workingArea,
            orientation: orientation,
            animationTime: animationTime
        )
        return LayoutResult(frames: frames, hiddenHandles: hiddenHandles)
    }

    func calculateLayoutInto(
        frames: inout [WindowHandle: CGRect],
        hiddenHandles: inout [WindowHandle: HideSide],
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil,
        orientation: Monitor.Orientation = .horizontal,
        animationTime: TimeInterval? = nil
    ) {
        calculateLayoutIntoZig(
            frames: &frames,
            hiddenHandles: &hiddenHandles,
            state: state,
            workspaceId: workspaceId,
            monitorFrame: monitorFrame,
            screenFrame: screenFrame,
            gaps: gaps,
            scale: scale,
            workingArea: workingArea,
            orientation: orientation,
            animationTime: animationTime
        )
    }

    private func calculateLayoutIntoZig(
        frames: inout [WindowHandle: CGRect],
        hiddenHandles: inout [WindowHandle: HideSide],
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil,
        orientation: Monitor.Orientation = .horizontal,
        animationTime: TimeInterval? = nil
    ) {
        let latencyToken = NiriLatencyProbe.begin(.layoutPass)
        defer { NiriLatencyProbe.end(latencyToken) }

        let containers = columns(in: workspaceId)
        guard !containers.isEmpty else {
            interactionIndexes.removeValue(forKey: workspaceId)
            layoutContexts.removeValue(forKey: workspaceId)
            clearRuntimeMirrorState(for: workspaceId)
            return
        }

        let snapshot = NiriStateZigKernel.makeSnapshot(columns: containers)
        guard let layoutContext = prepareSeededRuntimeContext(
            for: workspaceId,
            snapshot: snapshot
        ) else { return }

        let workingFrame = workingArea?.workingFrame ?? monitorFrame
        let viewFrame = workingArea?.viewFrame ?? screenFrame ?? monitorFrame
        let effectiveScale = workingArea?.scale ?? scale

        let primaryGap: CGFloat
        let secondaryGap: CGFloat
        switch orientation {
        case .horizontal:
            primaryGap = gaps.horizontal
            secondaryGap = gaps.vertical
        case .vertical:
            primaryGap = gaps.vertical
            secondaryGap = gaps.horizontal
        }

        let time = animationTime ?? CACurrentMediaTime()
        let workspaceOffset = workspaceSwitchOffset(
            workspaceId: workspaceId,
            monitorFrame: monitorFrame,
            time: time
        )
        let offsetFullscreenRect = workingFrame.offsetBy(dx: workspaceOffset, dy: 0)

        for container in containers {
            switch orientation {
            case .horizontal:
                if container.cachedWidth <= 0 {
                    container.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: primaryGap)
                }
            case .vertical:
                if container.cachedHeight <= 0 {
                    container.resolveAndCacheHeight(workingAreaHeight: workingFrame.height, gaps: primaryGap)
                }
            }
        }

        let activeIdx = state.activeColumnIndex.clamped(to: 0 ... max(0, containers.count - 1))
        let sizeKeyPath: KeyPath<NiriContainer, CGFloat> = switch orientation {
        case .horizontal: \.cachedWidth
        case .vertical: \.cachedHeight
        }
        let activePos = state.containerPosition(
            at: activeIdx,
            containers: containers,
            gap: primaryGap,
            sizeKeyPath: sizeKeyPath
        )
        let viewStart = activePos + state.viewOffsetPixels.value(at: time)
        let viewportSpan: CGFloat = switch orientation {
        case .horizontal: workingFrame.width
        case .vertical: workingFrame.height
        }

        let kernelResults: NiriLayoutZigKernel.LayoutPassResult
        do {
            kernelResults = try NiriLayoutZigKernel.run(
                context: layoutContext,
                columns: containers,
                orientation: orientation,
                primaryGap: primaryGap,
                secondaryGap: secondaryGap,
                workingFrame: workingFrame,
                viewFrame: viewFrame,
                fullscreenFrame: offsetFullscreenRect,
                viewStart: viewStart,
                viewportSpan: viewportSpan,
                workspaceOffset: workspaceOffset,
                scale: effectiveScale,
                tabIndicatorWidth: renderStyle.tabIndicatorWidth,
                time: time
            )
        } catch let error as NiriLayoutZigKernel.KernelCallError {
            interactionIndexes.removeValue(forKey: workspaceId)
            if case .runtimeRenderStateMismatch = error {
                // Recover on next pass by forcing a fresh runtime seed in prepareSeededRuntimeContext.
                clearRuntimeMirrorState(for: workspaceId)
            }
            return
        } catch {
            interactionIndexes.removeValue(forKey: workspaceId)
            return
        }

        for result in kernelResults.columns {
            result.column.frame = result.frame.roundedToPhysicalPixels(scale: effectiveScale)
        }

        for result in kernelResults.windows {
            let roundedBaseFrame = result.baseFrame.roundedToPhysicalPixels(scale: effectiveScale)
            let roundedAnimatedFrame = result.animatedFrame.roundedToPhysicalPixels(scale: effectiveScale)

            result.window.frame = roundedBaseFrame
            switch orientation {
            case .horizontal:
                result.window.resolvedHeight = result.resolvedSpan
                result.window.heightFixedByConstraint = result.wasConstrained
            case .vertical:
                result.window.resolvedWidth = result.resolvedSpan
                result.window.widthFixedByConstraint = result.wasConstrained
            }

            if let side = result.hideSide {
                hiddenHandles[result.window.handle] = side
            }
            frames[result.window.handle] = roundedAnimatedFrame
        }

        if let runtimeView = runtimeWorkspaceView(for: workspaceId) {
            interactionIndexes[workspaceId] = NiriLayoutZigKernel.makeInteractionIndex(
                view: runtimeView,
                handleToNode: handleToNode
            )
        } else {
            interactionIndexes.removeValue(forKey: workspaceId)
        }
    }
}
