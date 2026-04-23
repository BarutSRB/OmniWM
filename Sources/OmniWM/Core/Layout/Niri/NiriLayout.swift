// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import COmniWMKernels
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
    let frames: [WindowToken: CGRect]
    let hiddenHandles: [WindowToken: HideSide]
}

private enum NiriKernelConstants {
    static let singleWindowAspectTolerance: CGFloat = 0.001
}

private extension Monitor.Orientation {
    var niriKernelRawValue: UInt32 {
        switch self {
        case .horizontal:
            UInt32(OMNIWM_NIRI_ORIENTATION_HORIZONTAL)
        case .vertical:
            UInt32(OMNIWM_NIRI_ORIENTATION_VERTICAL)
        }
    }
}

private extension SizingMode {
    var niriKernelRawValue: UInt8 {
        switch self {
        case .normal:
            UInt8(OMNIWM_NIRI_WINDOW_SIZING_NORMAL)
        case .fullscreen:
            UInt8(OMNIWM_NIRI_WINDOW_SIZING_FULLSCREEN)
        }
    }
}

private extension AxisHideEdge {
    init?(kernelRawValue: UInt8) {
        switch Int32(kernelRawValue) {
        case Int32(OMNIWM_NIRI_HIDDEN_EDGE_MINIMUM):
            self = .minimum
        case Int32(OMNIWM_NIRI_HIDDEN_EDGE_MAXIMUM):
            self = .maximum
        case Int32(OMNIWM_NIRI_HIDDEN_EDGE_NONE):
            return nil
        default:
            preconditionFailure("Unknown Niri hidden edge \(kernelRawValue)")
        }
    }
}

extension omniwm_niri_container_output {
    var canonicalRect: CGRect {
        CGRect(
            x: canonical_x,
            y: canonical_y,
            width: canonical_width,
            height: canonical_height
        )
    }

    var renderedRect: CGRect {
        CGRect(
            x: rendered_x,
            y: rendered_y,
            width: rendered_width,
            height: rendered_height
        )
    }
}

extension omniwm_niri_window_output {
    var canonicalRect: CGRect {
        CGRect(
            x: canonical_x,
            y: canonical_y,
            width: canonical_width,
            height: canonical_height
        )
    }

    var renderedRect: CGRect {
        CGRect(
            x: rendered_x,
            y: rendered_y,
            width: rendered_width,
            height: rendered_height
        )
    }
}

struct NiriLayoutKernelSnapshot {
    let containers: [NiriContainer]
    let windows: [NiriWindow]
    let input: omniwm_niri_layout_input
    let rawContainers: ContiguousArray<omniwm_niri_container_input>
    let rawWindows: ContiguousArray<omniwm_niri_window_input>
    let rawMonitors: ContiguousArray<omniwm_niri_hidden_placement_monitor>
}

struct NiriLayoutKernelProjection {
    let snapshot: NiriLayoutKernelSnapshot
    let containerOutputs: ContiguousArray<omniwm_niri_container_output>
    let windowOutputs: ContiguousArray<omniwm_niri_window_output>
}

extension NiriLayoutEngine {
    func calculateLayout(
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil,
        orientation: Monitor.Orientation = .horizontal
    ) -> [WindowToken: CGRect] {
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
        animationTime: TimeInterval? = nil,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext? = nil,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext] = []
    ) -> LayoutResult {
        var frames: [WindowToken: CGRect] = [:]
        var hiddenHandles: [WindowToken: HideSide] = [:]
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
            animationTime: animationTime,
            hiddenPlacementMonitor: hiddenPlacementMonitor,
            hiddenPlacementMonitors: hiddenPlacementMonitors
        )
        return LayoutResult(frames: frames, hiddenHandles: hiddenHandles)
    }

    func calculateLayoutInto(
        frames: inout [WindowToken: CGRect],
        hiddenHandles: inout [WindowToken: HideSide],
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil,
        orientation: Monitor.Orientation = .horizontal,
        animationTime: TimeInterval? = nil,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext? = nil,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext] = []
    ) {
        let workingFrame = workingArea?.workingFrame ?? monitorFrame
        let viewFrame = workingArea?.viewFrame ?? screenFrame ?? monitorFrame
        let effectiveScale = workingArea?.scale ?? scale
        let time = animationTime ?? CACurrentMediaTime()

        guard let projection = projectKernelLayout(
            state: state,
            workspaceId: workspaceId,
            workingArea: WorkingAreaContext(
                workingFrame: workingFrame,
                viewFrame: viewFrame,
                scale: effectiveScale
            ),
            gaps: gaps,
            orientation: orientation,
            animationTime: time,
            workspaceOffset: 0,
            includeRenderOffsets: true,
            hiddenPlacementMonitor: hiddenPlacementMonitor,
            hiddenPlacementMonitors: hiddenPlacementMonitors
        ) else {
            return
        }

        applyKernelProjection(
            projection,
            frames: &frames,
            hiddenHandles: &hiddenHandles,
            orientation: orientation
        )
    }

    func projectKernelLayout(
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        workingArea: WorkingAreaContext,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        orientation: Monitor.Orientation,
        animationTime: TimeInterval,
        workspaceOffset: CGFloat,
        includeRenderOffsets: Bool,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext?,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]
    ) -> NiriLayoutKernelProjection? {
        let containers = columns(in: workspaceId)
        guard !containers.isEmpty else { return nil }

        if let singleWindowContext = singleWindowLayoutContext(in: workspaceId),
           singleWindowContext.container.hasManualSingleWindowWidthOverride,
           singleWindowContext.container.cachedWidth <= 0 {
            singleWindowContext.container.resolveAndCacheWidth(
                workingAreaWidth: workingArea.workingFrame.width,
                gaps: gaps.horizontal
            )
        }

        switch orientation {
        case .horizontal:
            prepareColumnWidths(
                in: workspaceId,
                workingAreaWidth: workingArea.workingFrame.width,
                gaps: gaps.horizontal
            )
        case .vertical:
            for container in containers {
                if container.cachedHeight <= 0 {
                    container.resolveAndCacheHeight(
                        workingAreaHeight: workingArea.workingFrame.height,
                        gaps: gaps.vertical
                    )
                }
            }
        }

        let snapshot = makeKernelSnapshot(
            containers: containers,
            singleWindowContext: singleWindowLayoutContext(in: workspaceId),
            state: state,
            workingArea: workingArea,
            gaps: gaps,
            orientation: orientation,
            animationTime: animationTime,
            workspaceOffset: workspaceOffset,
            includeRenderOffsets: includeRenderOffsets,
            hiddenPlacementMonitor: hiddenPlacementMonitor,
            hiddenPlacementMonitors: hiddenPlacementMonitors
        )

        return solveKernelProjection(snapshot)
    }

    private func makeKernelSnapshot(
        containers: [NiriContainer],
        singleWindowContext: SingleWindowLayoutContext?,
        state: ViewportState,
        workingArea: WorkingAreaContext,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        orientation: Monitor.Orientation,
        animationTime: TimeInterval,
        workspaceOffset: CGFloat,
        includeRenderOffsets: Bool,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext?,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]
    ) -> NiriLayoutKernelSnapshot {
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

        var resolvedHiddenPlacementMonitors = hiddenPlacementMonitors
        if let hiddenPlacementMonitor,
           !resolvedHiddenPlacementMonitors.contains(where: { $0.id == hiddenPlacementMonitor.id }) {
            resolvedHiddenPlacementMonitors.append(hiddenPlacementMonitor)
        }

        let hiddenPlacementMonitorIndex = hiddenPlacementMonitor.flatMap { targetMonitor in
            resolvedHiddenPlacementMonitors.firstIndex { $0.id == targetMonitor.id }
        } ?? -1

        let totalWindowCount = containers.reduce(into: 0) { $0 += $1.windowNodes.count }

        var windows: [NiriWindow] = []
        windows.reserveCapacity(totalWindowCount)

        var rawWindows = ContiguousArray<omniwm_niri_window_input>()
        rawWindows.reserveCapacity(totalWindowCount)

        var rawContainers = ContiguousArray<omniwm_niri_container_input>()
        rawContainers.reserveCapacity(containers.count)

        for container in containers {
            let windowStartIndex = rawWindows.count
            let renderOffset = includeRenderOffsets ? container.renderOffset(at: animationTime) : .zero
            let windowNodes = container.windowNodes

            for window in windowNodes {
                windows.append(window)
                rawWindows.append(makeKernelWindowInput(
                    for: window,
                    orientation: orientation,
                    renderOffset: includeRenderOffsets ? window.renderOffset(at: animationTime) : .zero
                ))
            }

            let span: CGFloat = switch orientation {
            case .horizontal: container.cachedWidth
            case .vertical: container.cachedHeight
            }

            rawContainers.append(
                omniwm_niri_container_input(
                    span: span,
                    render_offset_x: renderOffset.x,
                    render_offset_y: renderOffset.y,
                    window_start_index: numericCast(windowStartIndex),
                    window_count: numericCast(windowNodes.count),
                    is_tabbed: container.isTabbed ? 1 : 0,
                    has_manual_single_window_width_override: container.hasManualSingleWindowWidthOverride ? 1 : 0
                )
            )
        }

        let rawMonitors = ContiguousArray(
            resolvedHiddenPlacementMonitors.map { monitor in
                omniwm_niri_hidden_placement_monitor(
                    frame_x: monitor.frame.minX,
                    frame_y: monitor.frame.minY,
                    frame_width: monitor.frame.width,
                    frame_height: monitor.frame.height,
                    visible_x: monitor.visibleFrame.minX,
                    visible_y: monitor.visibleFrame.minY,
                    visible_width: monitor.visibleFrame.width,
                    visible_height: monitor.visibleFrame.height
                )
            }
        )

        let input = omniwm_niri_layout_input(
            working_x: workingArea.workingFrame.minX,
            working_y: workingArea.workingFrame.minY,
            working_width: workingArea.workingFrame.width,
            working_height: workingArea.workingFrame.height,
            view_x: workingArea.viewFrame.minX,
            view_y: workingArea.viewFrame.minY,
            view_width: workingArea.viewFrame.width,
            view_height: workingArea.viewFrame.height,
            scale: workingArea.scale,
            primary_gap: primaryGap,
            secondary_gap: secondaryGap,
            tab_indicator_width: renderStyle.tabIndicatorWidth,
            view_offset: state.viewOffsetPixels.value(at: animationTime),
            workspace_offset: workspaceOffset,
            single_window_aspect_ratio: singleWindowContext.map { Double($0.aspectRatio) } ?? 0,
            single_window_aspect_tolerance: NiriKernelConstants.singleWindowAspectTolerance,
            active_container_index: Int32(clamping: state.activeColumnIndex),
            hidden_placement_monitor_index: Int32(clamping: hiddenPlacementMonitorIndex),
            orientation: orientation.niriKernelRawValue,
            single_window_mode: singleWindowContext == nil ? 0 : 1
        )

        return NiriLayoutKernelSnapshot(
            containers: containers,
            windows: windows,
            input: input,
            rawContainers: rawContainers,
            rawWindows: rawWindows,
            rawMonitors: rawMonitors
        )
    }

    private func makeKernelWindowInput(
        for window: NiriWindow,
        orientation: Monitor.Orientation,
        renderOffset: CGPoint
    ) -> omniwm_niri_window_input {
        let constraints = window.constraints
        switch orientation {
        case .horizontal:
            let fixedValue: CGFloat?
            switch window.height {
            case let .fixed(height):
                fixedValue = height
            case .auto:
                fixedValue = nil
            }
            return omniwm_niri_window_input(
                weight: max(0.1, window.heightWeight),
                min_constraint: constraints.minSize.height,
                max_constraint: constraints.maxSize.height,
                fixed_value: fixedValue ?? 0,
                render_offset_x: renderOffset.x,
                render_offset_y: renderOffset.y,
                has_max_constraint: constraints.hasMaxHeight ? 1 : 0,
                is_constraint_fixed: constraints.isFixed ? 1 : 0,
                has_fixed_value: fixedValue == nil ? 0 : 1,
                sizing_mode: window.sizingMode.niriKernelRawValue
            )
        case .vertical:
            let fixedValue: CGFloat?
            switch window.windowWidth {
            case let .fixed(width):
                fixedValue = width
            case .auto:
                fixedValue = nil
            }
            return omniwm_niri_window_input(
                weight: max(0.1, window.widthWeight),
                min_constraint: constraints.minSize.width,
                max_constraint: constraints.maxSize.width,
                fixed_value: fixedValue ?? 0,
                render_offset_x: renderOffset.x,
                render_offset_y: renderOffset.y,
                has_max_constraint: constraints.hasMaxWidth ? 1 : 0,
                is_constraint_fixed: constraints.isFixed ? 1 : 0,
                has_fixed_value: fixedValue == nil ? 0 : 1,
                sizing_mode: window.sizingMode.niriKernelRawValue
            )
        }
    }

    private func solveKernelProjection(
        _ snapshot: NiriLayoutKernelSnapshot
    ) -> NiriLayoutKernelProjection {
        var rawInput = snapshot.input
        var containerOutputs = ContiguousArray(
            repeating: omniwm_niri_container_output(
                canonical_x: 0,
                canonical_y: 0,
                canonical_width: 0,
                canonical_height: 0,
                rendered_x: 0,
                rendered_y: 0,
                rendered_width: 0,
                rendered_height: 0
            ),
            count: snapshot.rawContainers.count
        )
        var windowOutputs = ContiguousArray(
            repeating: omniwm_niri_window_output(
                canonical_x: 0,
                canonical_y: 0,
                canonical_width: 0,
                canonical_height: 0,
                rendered_x: 0,
                rendered_y: 0,
                rendered_width: 0,
                rendered_height: 0,
                resolved_span: 0,
                hidden_edge: 0,
                physical_hidden_edge: 0
            ),
            count: snapshot.rawWindows.count
        )

        let status = snapshot.rawContainers.withUnsafeBufferPointer { containerBuffer in
            snapshot.rawWindows.withUnsafeBufferPointer { windowBuffer in
                snapshot.rawMonitors.withUnsafeBufferPointer { monitorBuffer in
                    containerOutputs.withUnsafeMutableBufferPointer { containerOutputBuffer in
                        windowOutputs.withUnsafeMutableBufferPointer { windowOutputBuffer in
                            omniwm_niri_layout_solve(
                                &rawInput,
                                containerBuffer.baseAddress,
                                containerBuffer.count,
                                windowBuffer.baseAddress,
                                windowBuffer.count,
                                monitorBuffer.baseAddress,
                                monitorBuffer.count,
                                containerOutputBuffer.baseAddress,
                                containerOutputBuffer.count,
                                windowOutputBuffer.baseAddress,
                                windowOutputBuffer.count
                            )
                        }
                    }
                }
            }
        }

        precondition(
            status == OMNIWM_KERNELS_STATUS_OK,
            "omniwm_niri_layout_solve returned \(status)"
        )

        return NiriLayoutKernelProjection(
            snapshot: snapshot,
            containerOutputs: containerOutputs,
            windowOutputs: windowOutputs
        )
    }

    private func applyKernelProjection(
        _ projection: NiriLayoutKernelProjection,
        frames: inout [WindowToken: CGRect],
        hiddenHandles: inout [WindowToken: HideSide],
        orientation: Monitor.Orientation
    ) {
        for (index, container) in projection.snapshot.containers.enumerated() {
            let output = projection.containerOutputs[index]
            container.frame = output.canonicalRect
            container.renderedFrame = output.renderedRect
        }

        for (index, window) in projection.snapshot.windows.enumerated() {
            let output = projection.windowOutputs[index]
            let canonicalFrame = output.canonicalRect
            let renderedFrame = output.renderedRect

            window.frame = canonicalFrame
            switch orientation {
            case .horizontal:
                window.resolvedHeight = output.resolved_span
            case .vertical:
                window.resolvedWidth = output.resolved_span
            }
            window.renderedFrame = renderedFrame
            frames[window.token] = renderedFrame

            let hiddenEdgeRawValue = output.physical_hidden_edge != UInt8(OMNIWM_NIRI_HIDDEN_EDGE_NONE)
                ? output.physical_hidden_edge
                : output.hidden_edge
            if let hiddenEdge = AxisHideEdge(kernelRawValue: hiddenEdgeRawValue) {
                hiddenHandles[window.token] = hiddenEdge.encodedHideSide
            }
        }
    }

    func resolvedSingleWindowRect(
        for context: SingleWindowLayoutContext,
        in workingFrame: CGRect,
        scale: CGFloat,
        gaps: CGFloat
    ) -> CGRect {
        if context.container.hasManualSingleWindowWidthOverride,
           context.container.cachedWidth <= 0 {
            context.container.resolveAndCacheWidth(
                workingAreaWidth: workingFrame.width,
                gaps: gaps
            )
        }

        var rawInput = omniwm_niri_layout_input(
            working_x: workingFrame.minX,
            working_y: workingFrame.minY,
            working_width: workingFrame.width,
            working_height: workingFrame.height,
            view_x: workingFrame.minX,
            view_y: workingFrame.minY,
            view_width: workingFrame.width,
            view_height: workingFrame.height,
            scale: scale,
            primary_gap: 0,
            secondary_gap: 0,
            tab_indicator_width: 0,
            view_offset: 0,
            workspace_offset: 0,
            single_window_aspect_ratio: context.aspectRatio,
            single_window_aspect_tolerance: NiriKernelConstants.singleWindowAspectTolerance,
            active_container_index: 0,
            hidden_placement_monitor_index: -1,
            orientation: UInt32(OMNIWM_NIRI_ORIENTATION_HORIZONTAL),
            single_window_mode: 1
        )
        let rawContainer = omniwm_niri_container_input(
            span: context.container.cachedWidth,
            render_offset_x: 0,
            render_offset_y: 0,
            window_start_index: 0,
            window_count: 1,
            is_tabbed: 0,
            has_manual_single_window_width_override: context.container.hasManualSingleWindowWidthOverride ? 1 : 0
        )
        let rawWindow = omniwm_niri_window_input(
            weight: 1,
            min_constraint: 1,
            max_constraint: 0,
            fixed_value: 0,
            render_offset_x: 0,
            render_offset_y: 0,
            has_max_constraint: 0,
            is_constraint_fixed: 0,
            has_fixed_value: 0,
            sizing_mode: UInt8(OMNIWM_NIRI_WINDOW_SIZING_NORMAL)
        )
        var containerOutput = omniwm_niri_container_output(
            canonical_x: 0,
            canonical_y: 0,
            canonical_width: 0,
            canonical_height: 0,
            rendered_x: 0,
            rendered_y: 0,
            rendered_width: 0,
            rendered_height: 0
        )
        var windowOutput = omniwm_niri_window_output(
            canonical_x: 0,
            canonical_y: 0,
            canonical_width: 0,
            canonical_height: 0,
            rendered_x: 0,
            rendered_y: 0,
            rendered_width: 0,
            rendered_height: 0,
            resolved_span: 0,
            hidden_edge: 0,
            physical_hidden_edge: 0
        )

        let status = withUnsafePointer(to: rawContainer) { containerPointer in
            withUnsafePointer(to: rawWindow) { windowPointer in
                withUnsafeMutablePointer(to: &containerOutput) { containerOutputPointer in
                    withUnsafeMutablePointer(to: &windowOutput) { windowOutputPointer in
                        omniwm_niri_layout_solve(
                            &rawInput,
                            containerPointer,
                            1,
                            windowPointer,
                            1,
                            nil,
                            0,
                            containerOutputPointer,
                            1,
                            windowOutputPointer,
                            1
                        )
                    }
                }
            }
        }

        precondition(
            status == OMNIWM_KERNELS_STATUS_OK,
            "omniwm_niri_layout_solve returned \(status)"
        )

        return containerOutput.canonicalRect
    }
}
