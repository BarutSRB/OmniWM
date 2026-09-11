// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

private let niriWheelScrollTickAmount: CGFloat = 120.0

struct MouseInputState {
    struct LockedGestureContext {
        let workspaceId: WorkspaceDescriptor.ID
        let monitorId: Monitor.ID
        let fingerCount: Int
        let columnScrollCandidate: Bool
        let columnScrollAxis: WorkspaceSwipeAxis
        let workspaceAxis: WorkspaceSwipeAxis?
        let overviewCandidate: Bool
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
    var activeInteractionButton: MouseEventHandler.MouseButton?
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
    var viewportGestureSessionID: AnimationDriver.GestureSessionID?
    var workspaceSwipeFired = false
    let workspaceSwipeTracker = SwipeTracker()
    var suppressGestureStartUntilAllTouchesLift = false
    var consumeTrackpadScrollUntilAllTouchesLift = false
    var suppressTrackpadMomentumScroll = false
    var horizontalWheelTracker = NiriScrollTracker(tick: niriWheelScrollTickAmount)
    var verticalWheelTracker = NiriScrollTracker(tick: niriWheelScrollTickAmount)
}
