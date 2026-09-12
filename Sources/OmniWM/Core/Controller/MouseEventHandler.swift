// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
final class MouseEventHandler {
    nonisolated(unsafe) weak static var _instance: MouseEventHandler?

    weak var controller: WMController?
    var state = MouseInputState()
    var isCapturingPerformance: Bool {
        performanceCounters != nil
    }

    private var multitouchSource: MultitouchGestureSource?
    private var performanceCounters: MousePerformanceCounters?
    var multitouchSourceFactory: @MainActor () -> MultitouchGestureSource = { MultitouchGestureSource() }
    var pressedMouseButtonsProvider: @MainActor () -> Int = { Int(NSEvent.pressedMouseButtons) }
    var nativeWindowFrameProvider: @MainActor (AXWindowRef) -> CGRect? = {
        AXWindowService.framePreferFast($0)
    }

    init(controller: WMController) {
        self.controller = controller
    }

    @discardableResult
    func installMultitouchSource(_ source: MultitouchGestureSource) -> Bool {
        let current = multitouchSource
        if let current, current !== source {
            guard current.shutdown() else { return false }
            accumulateRetiredMultitouchPerformance(from: current)
        }
        source.onSnapshot = { [weak self] snapshot in
            self?.receiveTapGestureEvent(snapshot)
        }
        source.onSourceWillReplace = { [weak self] in
            self?.resetForMultitouchSourceReplacement()
        }
        multitouchSource = source
        if performanceCounters != nil, current !== source {
            source.beginPerformanceCapture()
        }
        guard source.startLifecycle() else {
            accumulateRetiredMultitouchPerformance(from: source)
            multitouchSource = nil
            return false
        }
        return true
    }

    func cleanup() {
        state.latestFocusFollowsMouseSample = nil
        clearNativeTitleBarDrag()
        cancelActiveMouseInteraction()
        state.capturedInteractionButton = nil
        tearDownEventTaps()
        let retiringMultitouchSource = multitouchSource
        if retiringMultitouchSource?.shutdown() != false {
            if let retiringMultitouchSource {
                accumulateRetiredMultitouchPerformance(from: retiringMultitouchSource)
            }
            multitouchSource = nil
        }
        MouseEventHandler._instance = nil
        DiagnosticsEventRecorder.shared.recordLifecycle(name: "mouse.moveTap.removed")
        DiagnosticsEventRecorder.shared.recordLifecycle(name: "mouse.tap.removed")
        controller?.eventIntake.removePendingMouseEvents()
        resetForMultitouchSourceReplacement()
    }

    func reconcileMultitouchSource() {
        guard let controller, controller.hasStartedServices else { return }
        let shouldRun = controller.settings.gestures.trackpadGesturesEnabled
        if shouldRun {
            if let multitouchSource {
                if !multitouchSource.startLifecycle() {
                    FallbackFiringRecorder.shared.note(.input, "multitouchSourceCleanupBlocked")
                }
                return
            }
            if !installMultitouchSource(multitouchSourceFactory()) {
                FallbackFiringRecorder.shared.note(.input, "multitouchSourceCleanupBlocked")
            }
        } else {
            let retiringMultitouchSource = multitouchSource
            if retiringMultitouchSource?.shutdown() != false {
                if let retiringMultitouchSource {
                    accumulateRetiredMultitouchPerformance(from: retiringMultitouchSource)
                }
                multitouchSource = nil
                resetForMultitouchSourceReplacement()
            } else {
                FallbackFiringRecorder.shared.note(.input, "multitouchSourceCleanupBlocked")
            }
        }
    }

    func beginPerformanceCapture() {
        performanceCounters = MousePerformanceCounters()
        multitouchSource?.beginPerformanceCapture()
    }

    func performanceSnapshot() -> PerformanceSnapshot? {
        guard let performanceCounters else { return nil }
        return performanceCounters.snapshot(multitouch: multitouchSource?.performanceSnapshot())
    }

    func endPerformanceCapture() -> PerformanceSnapshot? {
        guard let performanceCounters else { return nil }
        let multitouch = multitouchSource?.endPerformanceCapture()
        let snapshot = performanceCounters.snapshot(multitouch: multitouch)
        self.performanceCounters = nil
        return snapshot
    }

    private func accumulateRetiredMultitouchPerformance(from source: MultitouchGestureSource) {
        guard var performanceCounters,
              let snapshot = source.endPerformanceCapture()
        else { return }
        performanceCounters.accumulateRetiredMultitouch(snapshot)
        self.performanceCounters = performanceCounters
    }

    func requestMultitouchRevalidation(_ reason: MultitouchGestureSource.RevalidationReason) {
        multitouchSource?.requestRevalidation(reason)
    }

    func clearGestureLatches() {
        state.suppressGestureStartUntilAllTouchesLift = false
        state.consumeTrackpadScrollUntilAllTouchesLift = false
    }

    func suspendMultitouchForSleep() {
        multitouchSource?.suspendForSleep()
    }

    var multitouchDiagnosticsSnapshot: MultitouchGestureSource.DiagnosticsSnapshot? {
        multitouchSource?.diagnosticsSnapshot()
    }

    func resetForMultitouchSourceReplacement() {
        resetGestureState()
        state.workspaceSwipeTracker.reset()
        clearGestureLatches()
        state.suppressTrackpadMomentumScroll = false
    }

    func recordMouseWarpSample() {
        performanceCounters?.mouseWarpSamples &+= 1
    }

    func recordDroppedTrackpadScroll() {
        performanceCounters?.droppedTrackpadScrollEvents &+= 1
    }

    func recordCGEvent(_ type: CGEventType) {
        guard performanceCounters != nil else { return }
        performanceCounters?.cgEvents &+= 1
        switch type {
        case .mouseMoved:
            performanceCounters?.mouseMovedEvents &+= 1
        case .leftMouseDragged,
             .rightMouseDragged:
            performanceCounters?.mouseDraggedEvents &+= 1
        case .scrollWheel:
            performanceCounters?.scrollEvents &+= 1
        case .leftMouseDown,
             .leftMouseUp,
             .rightMouseDown,
             .rightMouseUp:
            performanceCounters?.buttonEvents &+= 1
        default:
            break
        }
    }
}
