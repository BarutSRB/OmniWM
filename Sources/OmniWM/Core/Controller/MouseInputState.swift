// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

private let niriWheelScrollTickAmount: CGFloat = 120.0

struct MouseInputState {
    /// Who started the active move or resize. A trackpad gesture rejects every mouse button, so mouse drags
    /// and releases cannot steer or finish an interaction they did not begin.
    enum InteractionSource: Hashable {
        case mouse(MouseEventHandler.MouseButton)
        case trackpadGesture

        var mouseButton: MouseEventHandler.MouseButton? {
            if case let .mouse(button) = self { button } else { nil }
        }
    }

    struct LockedGestureContext {
        let workspaceId: WorkspaceDescriptor.ID
        let monitorId: Monitor.ID
        let fingerCount: Int
        let columnScrollCandidate: Bool
        let columnScrollAxis: WorkspaceSwipeAxis
        let workspaceAxis: WorkspaceSwipeAxis?
        /// The tiled window under the cursor when the gesture began, when a window move or resize gesture
        /// could target it. `nil` means no window gesture candidate.
        let windowGestureTarget: WindowToken?
        /// Cursor location when the gesture began; window gestures steer a virtual cursor from here.
        let startLocation: CGPoint
    }

    enum GesturePhase {
        case idle
        case armed
        case committed
    }

    enum NativeTitleBarDragPhase {
        case armed
        case dragging
        case awaitingFrameChange
        case awaitingFrameWrite
        case awaitingCorrection
    }

    struct NativeTitleBarDrag {
        let token: WindowToken
        var phase: NativeTitleBarDragPhase = .armed
        var receivedFrameChange = false
        var issuedUnreadableCorrection = false
        var terminalFailureRetryRequestId: AXFrameRequestId?
    }

    struct FocusFollowsMouseSample {
        let location: CGPoint
        let modifiersRawValue: UInt64
        let windowIdUnderPointer: Int?
    }

    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var moveTap: CFMachPort?
    var moveTapRunLoopSource: CFRunLoopSource?
    var currentHoveredEdges: ResizeEdge = []
    var isResizing: Bool = false
    var isMoving: Bool = false
    var activeInteractionSource: InteractionSource?
    var activeInteractionButton: MouseEventHandler.MouseButton? {
        get { activeInteractionSource?.mouseButton }
        set { activeInteractionSource = newValue.map { .mouse($0) } }
    }

    var capturedInteractionButton: MouseEventHandler.MouseButton?
    var resizeLayout: LayoutType?
    var moveLayout: LayoutType?
    var awaitsNativeTitleBarDragTarget = false
    var nativeTitleBarDragFallbackToken: WindowToken?
    var nativeTitleBarDragFallbackReleased = false
    var nativeTitleBarDrag: NativeTitleBarDrag?

    var lastFocusFollowsMouseTime: Date = .distantPast
    var latestFocusFollowsMouseSample: FocusFollowsMouseSample?
    let focusFollowsMouseDebounce: TimeInterval = 0.1
    var dragGhostController: DragGhostController?

    var gesturePhase: GesturePhase = .idle
    var gestureStartX: CGFloat = 0.0
    var gestureStartY: CGFloat = 0.0
    var gestureLastAverageX: CGFloat = 0.0
    var gestureLastAverageY: CGFloat = 0.0
    var lockedGestureContext: LockedGestureContext?
    var activeGestureMode: TrackpadGestureMode?
    var gestureOwnsWindowInteraction: Bool {
        activeInteractionSource == .trackpadGesture
    }

    /// When the contact frame first disagreed with the locked finger count during a committed window gesture.
    var gestureFingerCountMismatchSince: TimeInterval?
    var viewportGestureSessionID: AnimationDriver.GestureSessionID?
    var workspaceSwipeFired = false
    let workspaceSwipeTracker = SwipeTracker()
    var suppressGestureStartUntilAllTouchesLift = false
    var consumeTrackpadScrollUntilAllTouchesLift = false
    var suppressTrackpadMomentumScroll = false
    var horizontalWheelTracker = NiriScrollTracker(tick: niriWheelScrollTickAmount)
    var verticalWheelTracker = NiriScrollTracker(tick: niriWheelScrollTickAmount)
}
