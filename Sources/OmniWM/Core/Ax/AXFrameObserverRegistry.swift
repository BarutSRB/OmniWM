// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

@MainActor
final class AXFrameObserverRegistry {
    private struct AXPendingFrameObserver {
        var windowId: Int
        let pid: pid_t
        var expectedWindow: AXWindowRef
        var targetFrame: CGRect
        let currentFrameHint: CGRect?
        var components: AXFrameComponents
        var observers: [AXFrameApplicationTerminalObserver]
        var traceRequestId: UInt64
    }

    private var pendingFrameObserversByRequestId: [AXFrameRequestId: AXPendingFrameObserver] = [:]
    private var observerRequestIdByWindowId: [Int: AXFrameRequestId] = [:]

    func requestId(for windowId: Int) -> AXFrameRequestId? {
        observerRequestIdByWindowId[windowId]
    }

    func needsReplacement(
        for windowId: Int,
        expectedWindow: AXWindowRef,
        targetFrame: CGRect,
        components: AXFrameComponents
    ) -> Bool {
        guard let requestId = observerRequestIdByWindowId[windowId],
              let pendingObserver = pendingFrameObserversByRequestId[requestId] else { return false }
        return !pendingObserver.targetFrame.approximatelyEqual(to: targetFrame, tolerance: FrameTolerance.frameWrite)
            || pendingObserver.components != components
            || !sameAXWindowIdentity(pendingObserver.expectedWindow, expectedWindow)
    }

    func rekey(oldWindowId: Int, newWindowId: Int) {
        if let requestId = observerRequestIdByWindowId.removeValue(forKey: oldWindowId) {
            observerRequestIdByWindowId[newWindowId] = requestId
            if var pendingObserver = pendingFrameObserversByRequestId[requestId] {
                pendingObserver.windowId = newWindowId
                pendingObserver.expectedWindow = AXWindowRef(
                    element: pendingObserver.expectedWindow.element,
                    windowId: newWindowId
                )
                pendingFrameObserversByRequestId[requestId] = pendingObserver
            }
        }
    }

    func cancelAll(currentFrameHint: (Int) -> CGRect?) -> [AXFrameTerminalDelivery] {
        let deliveries = pendingFrameObserversByRequestId.map { requestId, pendingObserver in
            let currentFrameHint = currentFrameHint(pendingObserver.windowId)
                ?? pendingObserver.currentFrameHint
            return AXFrameTerminalDelivery(
                result: AXFrameApplyResult(
                    requestId: requestId,
                    pid: pendingObserver.pid,
                    windowId: pendingObserver.windowId,
                    expectedWindow: pendingObserver.expectedWindow,
                    targetFrame: pendingObserver.targetFrame,
                    currentFrameHint: pendingObserver.currentFrameHint,
                    writeResult: .skipped(
                        targetFrame: pendingObserver.targetFrame,
                        currentFrameHint: currentFrameHint,
                        failureReason: .cancelled,
                        observedFrame: currentFrameHint,
                        components: pendingObserver.components
                    ),
                    traceRequestId: pendingObserver.traceRequestId
                ),
                observers: pendingObserver.observers
            )
        }

        pendingFrameObserversByRequestId.removeAll()
        observerRequestIdByWindowId.removeAll()
        return deliveries
    }

    func register(
        for request: AXFrameApplicationRequest,
        replacing existingObserverRequestId: AXFrameRequestId?,
        terminalObserver: AXFrameApplicationTerminalObserver?
    ) {
        if let existingObserverRequestId,
           var pendingObserver = pendingFrameObserversByRequestId[existingObserverRequestId],
           sameAXWindowIdentity(pendingObserver.expectedWindow, request.expectedWindow),
           pendingObserver.targetFrame.approximatelyEqual(
               to: request.frame,
               tolerance: FrameTolerance.frameWrite
           ) && pendingObserver.components == request.components
        {
            pendingFrameObserversByRequestId.removeValue(forKey: existingObserverRequestId)
            pendingObserver.windowId = request.windowId
            pendingObserver.targetFrame = request.frame
            pendingObserver.components = request.components
            pendingObserver.traceRequestId = request.traceRequestId
            if let terminalObserver {
                pendingObserver.observers.append(terminalObserver)
            }
            pendingFrameObserversByRequestId[request.requestId] = pendingObserver
            observerRequestIdByWindowId[request.windowId] = request.requestId
        } else if let terminalObserver {
            pendingFrameObserversByRequestId[request.requestId] = AXPendingFrameObserver(
                windowId: request.windowId,
                pid: request.pid,
                expectedWindow: request.expectedWindow,
                targetFrame: request.frame,
                currentFrameHint: request.currentFrameHint,
                components: request.components,
                observers: [terminalObserver],
                traceRequestId: request.traceRequestId
            )
            observerRequestIdByWindowId[request.windowId] = request.requestId
        }
    }

    func append(
        _ observer: @escaping AXFrameApplicationTerminalObserver,
        for windowId: Int,
        expectedWindow: AXWindowRef,
        targetFrame: CGRect,
        components: AXFrameComponents
    ) -> Bool {
        guard let requestId = observerRequestIdByWindowId[windowId],
              var pendingObserver = pendingFrameObserversByRequestId[requestId],
              sameAXWindowIdentity(pendingObserver.expectedWindow, expectedWindow),
              pendingObserver.components == components,
              pendingObserver.targetFrame.approximatelyEqual(to: targetFrame, tolerance: FrameTolerance.frameWrite)
        else {
            return false
        }

        pendingObserver.observers.append(observer)
        pendingFrameObserversByRequestId[requestId] = pendingObserver
        return true
    }

    func complete(with result: AXFrameApplyResult) -> [AXFrameTerminalDelivery] {
        guard let pendingObserver = pendingFrameObserversByRequestId.removeValue(forKey: result.requestId) else {
            return []
        }
        if observerRequestIdByWindowId[pendingObserver.windowId] == result.requestId {
            observerRequestIdByWindowId.removeValue(forKey: pendingObserver.windowId)
        }
        let deliveredResult = pendingObserver.windowId == result.windowId
            ? result
            : result.rekeyed(to: pendingObserver.windowId)
        return [
            AXFrameTerminalDelivery(
                result: deliveredResult,
                observers: pendingObserver.observers
            )
        ]
    }

    func cancel(for windowId: Int, currentFrameHint: CGRect?) -> [AXFrameTerminalDelivery] {
        guard let requestId = observerRequestIdByWindowId.removeValue(forKey: windowId),
              let pendingObserver = pendingFrameObserversByRequestId.removeValue(forKey: requestId)
        else {
            return []
        }
        return [
            AXFrameTerminalDelivery(
                result: AXFrameApplyResult(
                    requestId: requestId,
                    pid: pendingObserver.pid,
                    windowId: pendingObserver.windowId,
                    expectedWindow: pendingObserver.expectedWindow,
                    targetFrame: pendingObserver.targetFrame,
                    currentFrameHint: pendingObserver.currentFrameHint,
                    writeResult: .skipped(
                        targetFrame: pendingObserver.targetFrame,
                        currentFrameHint: currentFrameHint,
                        failureReason: .cancelled,
                        observedFrame: currentFrameHint,
                        components: pendingObserver.components
                    ),
                    traceRequestId: pendingObserver.traceRequestId
                ),
                observers: pendingObserver.observers
            )
        ]
    }
}
