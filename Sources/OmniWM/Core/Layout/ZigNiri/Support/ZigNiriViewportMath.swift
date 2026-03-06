import CZigLayout
import Foundation

enum ZigNiriViewportMath {
    struct TransitionPlan {
        let resolvedColumnIndex: Int
        let offsetDelta: CGFloat
        let adjustedTargetOffset: CGFloat
        let targetOffset: CGFloat
        let snapDelta: CGFloat
        let snapToTargetImmediately: Bool
    }

    struct EnsureVisiblePlan {
        let targetOffset: CGFloat
        let offsetDelta: CGFloat
        let isNoop: Bool
    }

    struct ScrollStepResult {
        let applied: Bool
        let newOffset: CGFloat
        let selectionProgress: CGFloat
        let selectionSteps: Int?
    }

    struct GestureUpdateResult {
        let currentViewOffset: Double
        let selectionProgress: CGFloat
        let selectionSteps: Int?
    }

    struct GestureEndResult {
        let resolvedColumnIndex: Int
        let springFrom: Double
        let springTo: Double
        let initialVelocity: Double
    }

    enum ViewportMathError: Error, CustomStringConvertible {
        case invalidInput(operation: String, reason: String)
        case kernelCallFailed(operation: String, rc: Int32, details: String)

        var description: String {
            switch self {
            case let .invalidInput(operation, reason):
                return "\(operation) invalid input: \(reason)"
            case let .kernelCallFailed(operation, rc, details):
                return "\(operation) failed rc=\(rc) \(details)"
            }
        }
    }

    private static func report(_ error: ViewportMathError) {
        NSLog("ZigNiriViewportMath error: %@", error.description)
    }

    private static func centerModeCode(_ centerMode: CenterFocusedColumn) -> UInt8 {
        switch centerMode {
        case .never:
            0
        case .always:
            1
        case .onOverflow:
            2
        }
    }

    static func computeVisibleOffset(
        spans: [Double],
        containerIndex: Int,
        gap: CGFloat,
        viewportSpan: CGFloat,
        currentViewStart: CGFloat,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool,
        fromContainerIndex: Int?
    ) -> CGFloat {
        guard containerIndex >= 0 else {
            report(
                .invalidInput(
                    operation: "omni_viewport_compute_visible_offset",
                    reason: "containerIndex must be non-negative"
                )
            )
            return currentViewStart
        }

        var outTarget: Double = 0
        let fromIndex = Int64(fromContainerIndex ?? -1)

        let rc: Int32 = spans.withUnsafeBufferPointer { spansBuf in
            withUnsafeMutablePointer(to: &outTarget) { outPtr in
                omni_viewport_compute_visible_offset(
                    spansBuf.baseAddress,
                    spans.count,
                    containerIndex,
                    Double(gap),
                    Double(viewportSpan),
                    Double(currentViewStart),
                    centerModeCode(centerMode),
                    alwaysCenterSingleColumn ? 1 : 0,
                    fromIndex,
                    outPtr
                )
            }
        }

        if rc != OMNI_OK {
            report(
                .kernelCallFailed(
                    operation: "omni_viewport_compute_visible_offset",
                    rc: rc,
                    details: "span_count=\(spans.count) container_index=\(containerIndex) gap=\(gap) viewport_span=\(viewportSpan) current_view_start=\(currentViewStart) center_mode=\(centerModeCode(centerMode)) always_center_single_column=\(alwaysCenterSingleColumn) from_container_index=\(fromIndex)"
                )
            )
            return currentViewStart
        }
        return CGFloat(outTarget)
    }

    static func transitionPlan(
        spans: [Double],
        currentActiveIndex: Int,
        requestedIndex: Int,
        gap: CGFloat,
        viewportSpan: CGFloat,
        currentTargetOffset: CGFloat,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool,
        fromContainerIndex: Int?,
        scale: CGFloat
    ) -> TransitionPlan {
        guard currentActiveIndex >= 0, requestedIndex >= 0, scale > 0 else {
            report(
                .invalidInput(
                    operation: "omni_viewport_transition_to_column",
                    reason: "currentActiveIndex/requestedIndex must be non-negative and scale must be positive"
                )
            )
            return TransitionPlan(
                resolvedColumnIndex: max(0, requestedIndex),
                offsetDelta: 0,
                adjustedTargetOffset: currentTargetOffset,
                targetOffset: currentTargetOffset,
                snapDelta: 0,
                snapToTargetImmediately: true
            )
        }

        var out = OmniViewportTransitionResult(
            resolved_column_index: 0,
            offset_delta: 0,
            adjusted_target_offset: 0,
            target_offset: 0,
            snap_delta: 0,
            snap_to_target_immediately: 0
        )
        let fromIndex = Int64(fromContainerIndex ?? -1)

        let rc: Int32 = spans.withUnsafeBufferPointer { spansBuf in
            withUnsafeMutablePointer(to: &out) { outPtr in
                omni_viewport_transition_to_column(
                    spansBuf.baseAddress,
                    spansBuf.count,
                    currentActiveIndex,
                    requestedIndex,
                    Double(gap),
                    Double(viewportSpan),
                    Double(currentTargetOffset),
                    centerModeCode(centerMode),
                    alwaysCenterSingleColumn ? 1 : 0,
                    fromIndex,
                    Double(scale),
                    outPtr
                )
            }
        }

        if rc != OMNI_OK {
            report(
                .kernelCallFailed(
                    operation: "omni_viewport_transition_to_column",
                    rc: rc,
                    details: "span_count=\(spans.count) current_active_index=\(currentActiveIndex) requested_index=\(requestedIndex) gap=\(gap) viewport_span=\(viewportSpan) current_target_offset=\(currentTargetOffset) center_mode=\(centerModeCode(centerMode)) always_center_single_column=\(alwaysCenterSingleColumn) from_container_index=\(fromIndex) scale=\(scale)"
                )
            )
            return TransitionPlan(
                resolvedColumnIndex: max(0, requestedIndex),
                offsetDelta: 0,
                adjustedTargetOffset: currentTargetOffset,
                targetOffset: currentTargetOffset,
                snapDelta: 0,
                snapToTargetImmediately: true
            )
        }

        return TransitionPlan(
            resolvedColumnIndex: Int(out.resolved_column_index),
            offsetDelta: CGFloat(out.offset_delta),
            adjustedTargetOffset: CGFloat(out.adjusted_target_offset),
            targetOffset: CGFloat(out.target_offset),
            snapDelta: CGFloat(out.snap_delta),
            snapToTargetImmediately: out.snap_to_target_immediately != 0
        )
    }

    static func ensureVisiblePlan(
        spans: [Double],
        activeContainerIndex: Int,
        targetContainerIndex: Int,
        gap: CGFloat,
        viewportSpan: CGFloat,
        currentOffset: CGFloat,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool,
        fromContainerIndex: Int?,
        epsilon: CGFloat = 0.001
    ) -> EnsureVisiblePlan {
        guard activeContainerIndex >= 0, targetContainerIndex >= 0 else {
            report(
                .invalidInput(
                    operation: "omni_viewport_ensure_visible",
                    reason: "activeContainerIndex and targetContainerIndex must be non-negative"
                )
            )
            return EnsureVisiblePlan(
                targetOffset: currentOffset,
                offsetDelta: 0,
                isNoop: true
            )
        }

        var out = OmniViewportEnsureVisibleResult(
            target_offset: 0,
            offset_delta: 0,
            is_noop: 0
        )
        let fromIndex = Int64(fromContainerIndex ?? -1)

        let rc: Int32 = spans.withUnsafeBufferPointer { spansBuf in
            withUnsafeMutablePointer(to: &out) { outPtr in
                omni_viewport_ensure_visible(
                    spansBuf.baseAddress,
                    spansBuf.count,
                    activeContainerIndex,
                    targetContainerIndex,
                    Double(gap),
                    Double(viewportSpan),
                    Double(currentOffset),
                    centerModeCode(centerMode),
                    alwaysCenterSingleColumn ? 1 : 0,
                    fromIndex,
                    Double(epsilon),
                    outPtr
                )
            }
        }

        if rc != OMNI_OK {
            report(
                .kernelCallFailed(
                    operation: "omni_viewport_ensure_visible",
                    rc: rc,
                    details: "span_count=\(spans.count) active_container_index=\(activeContainerIndex) target_container_index=\(targetContainerIndex) gap=\(gap) viewport_span=\(viewportSpan) current_offset=\(currentOffset) center_mode=\(centerModeCode(centerMode)) always_center_single_column=\(alwaysCenterSingleColumn) from_container_index=\(fromIndex) epsilon=\(epsilon)"
                )
            )
            return EnsureVisiblePlan(
                targetOffset: currentOffset,
                offsetDelta: 0,
                isNoop: true
            )
        }

        return EnsureVisiblePlan(
            targetOffset: CGFloat(out.target_offset),
            offsetDelta: CGFloat(out.offset_delta),
            isNoop: out.is_noop != 0
        )
    }

    static func scrollStep(
        spans: [Double],
        deltaPixels: CGFloat,
        viewportSpan: CGFloat,
        gap: CGFloat,
        currentOffset: CGFloat,
        selectionProgress: CGFloat,
        changeSelection: Bool
    ) -> ScrollStepResult {
        var out = OmniViewportScrollResult(
            applied: 0,
            new_offset: Double(currentOffset),
            selection_progress: Double(selectionProgress),
            has_selection_steps: 0,
            selection_steps: 0
        )

        let rc: Int32 = spans.withUnsafeBufferPointer { spansBuf in
            withUnsafeMutablePointer(to: &out) { outPtr in
                omni_viewport_scroll_step(
                    spansBuf.baseAddress,
                    spansBuf.count,
                    Double(deltaPixels),
                    Double(viewportSpan),
                    Double(gap),
                    Double(currentOffset),
                    Double(selectionProgress),
                    changeSelection ? 1 : 0,
                    outPtr
                )
            }
        }

        if rc != OMNI_OK {
            report(
                .kernelCallFailed(
                    operation: "omni_viewport_scroll_step",
                    rc: rc,
                    details: "span_count=\(spans.count) delta_pixels=\(deltaPixels) viewport_span=\(viewportSpan) gap=\(gap) current_offset=\(currentOffset) selection_progress=\(selectionProgress) change_selection=\(changeSelection)"
                )
            )
            return ScrollStepResult(
                applied: false,
                newOffset: currentOffset,
                selectionProgress: selectionProgress,
                selectionSteps: nil
            )
        }

        return ScrollStepResult(
            applied: out.applied != 0,
            newOffset: CGFloat(out.new_offset),
            selectionProgress: CGFloat(out.selection_progress),
            selectionSteps: out.has_selection_steps != 0 ? Int(out.selection_steps) : nil
        )
    }

    static func gestureBegin(
        currentViewOffset: CGFloat,
        isTrackpad: Bool
    ) -> OmniViewportGestureState {
        var state = OmniViewportGestureState()

        let rc: Int32 = withUnsafeMutablePointer(to: &state) { statePtr in
            omni_viewport_gesture_begin(
                Double(currentViewOffset),
                isTrackpad ? 1 : 0,
                statePtr
            )
        }

        if rc != OMNI_OK {
            report(
                .kernelCallFailed(
                    operation: "omni_viewport_gesture_begin",
                    rc: rc,
                    details: "current_view_offset=\(currentViewOffset) is_trackpad=\(isTrackpad)"
                )
            )
            state.is_trackpad = isTrackpad ? 1 : 0
            state.current_view_offset = Double(currentViewOffset)
            state.stationary_view_offset = Double(currentViewOffset)
        }

        return state
    }

    static func gestureVelocity(state: OmniViewportGestureState) -> Double {
        var mutableState = state
        var outVelocity: Double = 0

        let rc: Int32 = withUnsafePointer(to: &mutableState) { statePtr in
            withUnsafeMutablePointer(to: &outVelocity) { outPtr in
                omni_viewport_gesture_velocity(
                    statePtr,
                    outPtr
                )
            }
        }

        if rc != OMNI_OK {
            report(
                .kernelCallFailed(
                    operation: "omni_viewport_gesture_velocity",
                    rc: rc,
                    details: ""
                )
            )
            return 0
        }

        return outVelocity
    }

    static func gestureUpdate(
        state: inout OmniViewportGestureState,
        spans: [Double],
        activeContainerIndex: Int,
        deltaPixels: CGFloat,
        timestamp: TimeInterval,
        gap: CGFloat,
        viewportSpan: CGFloat,
        selectionProgress: CGFloat
    ) -> GestureUpdateResult {
        guard activeContainerIndex >= 0 else {
            report(
                .invalidInput(
                    operation: "omni_viewport_gesture_update",
                    reason: "activeContainerIndex must be non-negative"
                )
            )
            return GestureUpdateResult(
                currentViewOffset: state.current_view_offset,
                selectionProgress: selectionProgress,
                selectionSteps: nil
            )
        }

        var out = OmniViewportGestureUpdateResult(
            current_view_offset: 0,
            selection_progress: Double(selectionProgress),
            has_selection_steps: 0,
            selection_steps: 0
        )

        let rc: Int32 = withUnsafeMutablePointer(to: &state) { statePtr in
            spans.withUnsafeBufferPointer { spansBuf in
                withUnsafeMutablePointer(to: &out) { outPtr in
                    omni_viewport_gesture_update(
                        statePtr,
                        spansBuf.baseAddress,
                        spansBuf.count,
                        activeContainerIndex,
                        Double(deltaPixels),
                        timestamp,
                        Double(gap),
                        Double(viewportSpan),
                        Double(selectionProgress),
                        outPtr
                    )
                }
            }
        }

        if rc != OMNI_OK {
            report(
                .kernelCallFailed(
                    operation: "omni_viewport_gesture_update",
                    rc: rc,
                    details: "span_count=\(spans.count) active_container_index=\(activeContainerIndex) delta_pixels=\(deltaPixels) timestamp=\(timestamp) gap=\(gap) viewport_span=\(viewportSpan) selection_progress=\(selectionProgress)"
                )
            )
            return GestureUpdateResult(
                currentViewOffset: state.current_view_offset,
                selectionProgress: selectionProgress,
                selectionSteps: nil
            )
        }

        return GestureUpdateResult(
            currentViewOffset: out.current_view_offset,
            selectionProgress: CGFloat(out.selection_progress),
            selectionSteps: out.has_selection_steps != 0 ? Int(out.selection_steps) : nil
        )
    }

    static func gestureEnd(
        state: OmniViewportGestureState,
        spans: [Double],
        activeContainerIndex: Int,
        gap: CGFloat,
        viewportSpan: CGFloat,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool
    ) -> GestureEndResult {
        guard activeContainerIndex >= 0 else {
            report(
                .invalidInput(
                    operation: "omni_viewport_gesture_end",
                    reason: "activeContainerIndex must be non-negative"
                )
            )
            return GestureEndResult(
                resolvedColumnIndex: 0,
                springFrom: state.current_view_offset,
                springTo: state.current_view_offset,
                initialVelocity: 0
            )
        }

        var mutableState = state
        var out = OmniViewportGestureEndResult(
            resolved_column_index: 0,
            spring_from: 0,
            spring_to: 0,
            initial_velocity: 0
        )

        let rc: Int32 = withUnsafePointer(to: &mutableState) { statePtr in
            spans.withUnsafeBufferPointer { spansBuf in
                withUnsafeMutablePointer(to: &out) { outPtr in
                    omni_viewport_gesture_end(
                        statePtr,
                        spansBuf.baseAddress,
                        spansBuf.count,
                        activeContainerIndex,
                        Double(gap),
                        Double(viewportSpan),
                        centerModeCode(centerMode),
                        alwaysCenterSingleColumn ? 1 : 0,
                        outPtr
                    )
                }
            }
        }

        if rc != OMNI_OK {
            report(
                .kernelCallFailed(
                    operation: "omni_viewport_gesture_end",
                    rc: rc,
                    details: "span_count=\(spans.count) active_container_index=\(activeContainerIndex) gap=\(gap) viewport_span=\(viewportSpan) center_mode=\(centerModeCode(centerMode)) always_center_single_column=\(alwaysCenterSingleColumn)"
                )
            )
            return GestureEndResult(
                resolvedColumnIndex: activeContainerIndex,
                springFrom: mutableState.current_view_offset,
                springTo: mutableState.current_view_offset,
                initialVelocity: 0
            )
        }

        return GestureEndResult(
            resolvedColumnIndex: Int(out.resolved_column_index),
            springFrom: out.spring_from,
            springTo: out.spring_to,
            initialVelocity: out.initial_velocity
        )
    }
}
