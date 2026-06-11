import CoreGraphics
import Foundation

typealias AXFrameApplicationTerminalObserver = @MainActor (AXFrameApplyResult) -> Void

struct AXFrameTerminalDelivery {
    let result: AXFrameApplyResult
    let observers: [AXFrameApplicationTerminalObserver]

    @MainActor
    func deliver() {
        for observer in observers {
            observer(result)
        }
    }
}

struct AXFrameRetryRequest: Equatable {
    let pid: pid_t
    let windowId: Int
    let frame: CGRect
}

struct AXFrameEnqueueDecision {
    var request: AXFrameApplicationRequest?
    var deliveries: [AXFrameTerminalDelivery] = []
    var shouldCancelPendingRetry = false
}

struct AXFrameApplyOutcome {
    var deliveries: [AXFrameTerminalDelivery] = []
    var retries: [AXFrameRetryRequest] = []
}

@MainActor
final class AXFrameApplicationLedger {
    private struct PendingFrameObserver {
        var windowId: Int
        let pid: pid_t
        let targetFrame: CGRect
        let currentFrameHint: CGRect?
        var observers: [AXFrameApplicationTerminalObserver]
    }

    private var lastAppliedFrames: [Int: CGRect] = [:]
    private var pendingFrameWrites: [Int: CGRect] = [:]
    private var recentFrameWriteFailures: [Int: AXFrameWriteFailureReason] = [:]
    private var retryBudgetByWindowId: [Int: Int] = [:]
    private var forceApplyWindowIds: Set<Int> = []
    private var pendingFrameRequestIdByWindowId: [Int: AXFrameRequestId] = [:]
    private var pendingFrameObserversByRequestId: [AXFrameRequestId: PendingFrameObserver] = [:]
    private var observerRequestIdByWindowId: [Int: AXFrameRequestId] = [:]
    private var rekeyedWindowIdsByPreviousId: [Int: Int] = [:]
    private var nextFrameApplicationRequestId: AXFrameRequestId = 1

    func forceApplyNextFrame(for windowId: Int) {
        forceApplyWindowIds.insert(windowId)
    }

    func lastAppliedFrame(for windowId: Int) -> CGRect? {
        lastAppliedFrames[windowId]
    }

    func recentFrameWriteFailure(for windowId: Int) -> AXFrameWriteFailureReason? {
        recentFrameWriteFailures[windowId]
    }

    func hasPendingFrameWrite(for windowId: Int) -> Bool {
        pendingFrameWrites[windowId] != nil
    }

    func pendingFrameWrite(for windowId: Int) -> CGRect? {
        pendingFrameWrites[windowId]
    }

    func shouldSuppressFrameChangeRelayout(for windowId: Int, observedFrame: CGRect?) -> Bool {
        if pendingFrameWrites[windowId] != nil {
            return true
        }
        guard let observedFrame,
              let lastAppliedFrame = lastAppliedFrames[windowId]
        else {
            return false
        }
        return observedFrame.approximatelyEqual(to: lastAppliedFrame, tolerance: FrameTolerance.frameWrite)
    }

    func rekeyWindowState(oldWindowId: Int, newWindowId: Int) {
        guard oldWindowId != newWindowId else { return }
        rekeyedWindowIdsByPreviousId[oldWindowId] = newWindowId
        let remappedWindowIds = rekeyedWindowIdsByPreviousId.compactMap { previousWindowId, mappedWindowId in
            mappedWindowId == oldWindowId ? previousWindowId : nil
        }
        for previousWindowId in remappedWindowIds {
            rekeyedWindowIdsByPreviousId[previousWindowId] = newWindowId
        }

        if let frame = lastAppliedFrames.removeValue(forKey: oldWindowId) {
            lastAppliedFrames[newWindowId] = frame
        }

        if let frame = pendingFrameWrites.removeValue(forKey: oldWindowId) {
            pendingFrameWrites[newWindowId] = frame
        }

        if let requestId = pendingFrameRequestIdByWindowId.removeValue(forKey: oldWindowId) {
            pendingFrameRequestIdByWindowId[newWindowId] = requestId
        }

        if let failure = recentFrameWriteFailures.removeValue(forKey: oldWindowId) {
            recentFrameWriteFailures[newWindowId] = failure
        }

        if let retryBudget = retryBudgetByWindowId.removeValue(forKey: oldWindowId) {
            retryBudgetByWindowId[newWindowId] = retryBudget
        }

        if forceApplyWindowIds.remove(oldWindowId) != nil {
            forceApplyWindowIds.insert(newWindowId)
        }

        if let requestId = observerRequestIdByWindowId.removeValue(forKey: oldWindowId) {
            observerRequestIdByWindowId[newWindowId] = requestId
            if var pendingObserver = pendingFrameObserversByRequestId[requestId] {
                pendingObserver.windowId = newWindowId
                pendingFrameObserversByRequestId[requestId] = pendingObserver
            }
        }
        clearSettledRekeyMappings(to: newWindowId)
    }

    func confirmFrameWrite(for windowId: Int, frame: CGRect) {
        lastAppliedFrames[windowId] = frame
        recentFrameWriteFailures.removeValue(forKey: windowId)
        retryBudgetByWindowId.removeValue(forKey: windowId)
        clearSettledRekeyMappings(to: windowId)
    }

    func removeWindowState(windowId: Int) -> [AXFrameTerminalDelivery] {
        let deliveries = cancelObserver(for: windowId)
        lastAppliedFrames.removeValue(forKey: windowId)
        pendingFrameWrites.removeValue(forKey: windowId)
        pendingFrameRequestIdByWindowId.removeValue(forKey: windowId)
        recentFrameWriteFailures.removeValue(forKey: windowId)
        retryBudgetByWindowId.removeValue(forKey: windowId)
        forceApplyWindowIds.remove(windowId)
        pruneRekeyMappingsAfterRemovingWindowState(for: windowId)
        return deliveries
    }

    func cancelFrameJob(windowId: Int) -> [AXFrameTerminalDelivery] {
        let deliveries = cancelObserver(for: windowId)
        pendingFrameWrites.removeValue(forKey: windowId)
        pendingFrameRequestIdByWindowId.removeValue(forKey: windowId)
        recentFrameWriteFailures.removeValue(forKey: windowId)
        retryBudgetByWindowId.removeValue(forKey: windowId)
        forceApplyWindowIds.remove(windowId)
        clearSettledRekeyMappings(to: windowId)
        return deliveries
    }

    func suppressFrameWrite(windowId: Int) -> [AXFrameTerminalDelivery] {
        let deliveries = cancelObserver(for: windowId)
        lastAppliedFrames.removeValue(forKey: windowId)
        pendingFrameWrites.removeValue(forKey: windowId)
        pendingFrameRequestIdByWindowId.removeValue(forKey: windowId)
        recentFrameWriteFailures.removeValue(forKey: windowId)
        retryBudgetByWindowId.removeValue(forKey: windowId)
        forceApplyWindowIds.remove(windowId)
        clearSettledRekeyMappings(to: windowId)
        return deliveries
    }

    func prepareFrameApplication(
        pid: pid_t,
        windowId: Int,
        frame: CGRect,
        isRetry: Bool,
        terminalObserver: AXFrameApplicationTerminalObserver?
    ) -> AXFrameEnqueueDecision {
        let cachedFrame = lastAppliedFrames[windowId]
        let pendingFrame = pendingFrameWrites[windowId]
        let hasRecentFailure = recentFrameWriteFailures[windowId] != nil
        let shouldForceApply = forceApplyWindowIds.remove(windowId) != nil
        if !shouldForceApply {
            if let pendingFrame,
               pendingFrame.approximatelyEqual(to: frame, tolerance: FrameTolerance.frameWrite)
            {
                if let terminalObserver,
                   !isRetry,
                   appendPendingFrameObserver(
                       terminalObserver,
                       for: windowId,
                       targetFrame: frame
                   )
                {
                    return AXFrameEnqueueDecision()
                }
                if terminalObserver == nil || isRetry {
                    return AXFrameEnqueueDecision()
                }
            } else if let cached = cachedFrame,
                      cached.approximatelyEqual(to: frame, tolerance: FrameTolerance.frameWrite),
                      !hasRecentFailure
            {
                if let terminalObserver {
                    return AXFrameEnqueueDecision(
                        deliveries: [
                            AXFrameTerminalDelivery(
                                result: successfulNoOpFrameApplyResult(
                                    requestId: makeNextFrameApplicationRequestId(),
                                    pid: pid,
                                    windowId: windowId,
                                    frame: frame,
                                    currentFrameHint: cachedFrame,
                                    observedFrame: cached
                                ),
                                observers: [terminalObserver]
                            )
                        ]
                    )
                }
                return AXFrameEnqueueDecision()
            }
        }

        var deliveries: [AXFrameTerminalDelivery] = []
        if !isRetry,
           let requestId = observerRequestIdByWindowId[windowId],
           let pendingObserver = pendingFrameObserversByRequestId[requestId],
           !pendingObserver.targetFrame.approximatelyEqual(to: frame, tolerance: FrameTolerance.frameWrite)
        {
            deliveries.append(contentsOf: discardPendingFrameObserver(for: windowId))
        }

        let existingObserverRequestId = observerRequestIdByWindowId[windowId]
        let requestId = makeNextFrameApplicationRequestId()
        pendingFrameWrites[windowId] = frame
        pendingFrameRequestIdByWindowId[windowId] = requestId
        recentFrameWriteFailures.removeValue(forKey: windowId)
        if let existingObserverRequestId,
           var pendingObserver = pendingFrameObserversByRequestId[existingObserverRequestId],
           pendingObserver.targetFrame.approximatelyEqual(to: frame, tolerance: FrameTolerance.frameWrite)
        {
            pendingFrameObserversByRequestId.removeValue(forKey: existingObserverRequestId)
            pendingObserver.windowId = windowId
            if let terminalObserver {
                pendingObserver.observers.append(terminalObserver)
            }
            pendingFrameObserversByRequestId[requestId] = pendingObserver
            observerRequestIdByWindowId[windowId] = requestId
        } else if let terminalObserver {
            pendingFrameObserversByRequestId[requestId] = PendingFrameObserver(
                windowId: windowId,
                pid: pid,
                targetFrame: frame,
                currentFrameHint: cachedFrame,
                observers: [terminalObserver]
            )
            observerRequestIdByWindowId[windowId] = requestId
        }
        if !isRetry {
            retryBudgetByWindowId[windowId] = 1
        }
        return AXFrameEnqueueDecision(
            request: AXFrameApplicationRequest(
                requestId: requestId,
                pid: pid,
                windowId: windowId,
                frame: frame,
                currentFrameHint: cachedFrame
            ),
            deliveries: deliveries,
            shouldCancelPendingRetry: !isRetry
        )
    }

    func handleFrameApplyResults(_ results: [AXFrameApplyResult]) -> AXFrameApplyOutcome {
        var outcome = AXFrameApplyOutcome()
        for result in results {
            let resolvedWindowId = resolveWindowId(for: result.windowId)
            let resultResolvedThroughRekey = resolvedWindowId != result.windowId
            let resolvedResult = resolvedWindowId == result.windowId ? result : result.rekeyed(to: resolvedWindowId)
            guard pendingFrameRequestIdByWindowId[resolvedWindowId] == resolvedResult.requestId,
                  let pendingFrame = pendingFrameWrites[resolvedWindowId],
                  pendingFrame.approximatelyEqual(to: resolvedResult.targetFrame, tolerance: FrameTolerance.frameWrite)
            else {
                continue
            }

            pendingFrameWrites.removeValue(forKey: resolvedWindowId)
            pendingFrameRequestIdByWindowId.removeValue(forKey: resolvedWindowId)

            if let confirmedFrame = resolvedResult.confirmedFrame {
                lastAppliedFrames[resolvedWindowId] = confirmedFrame
                recentFrameWriteFailures.removeValue(forKey: resolvedWindowId)
                retryBudgetByWindowId.removeValue(forKey: resolvedWindowId)
                outcome.deliveries.append(contentsOf: notifyPendingFrameObserver(with: resolvedResult))
                clearSettledRekeyMappings(to: resolvedWindowId)
                continue
            }

            if let failureReason = resolvedResult.writeResult.failureReason {
                recentFrameWriteFailures[resolvedWindowId] = failureReason
            }

            let remainingRetries = retryBudgetByWindowId[resolvedWindowId] ?? 0
            guard remainingRetries > 0,
                  shouldRetryFrameWrite(
                      after: resolvedResult,
                      resultResolvedThroughRekey: resultResolvedThroughRekey
                  )
            else {
                retryBudgetByWindowId.removeValue(forKey: resolvedWindowId)
                outcome.deliveries.append(contentsOf: notifyPendingFrameObserver(with: resolvedResult))
                clearSettledRekeyMappings(to: resolvedWindowId)
                continue
            }

            retryBudgetByWindowId[resolvedWindowId] = remainingRetries - 1
            forceApplyWindowIds.insert(resolvedWindowId)

            outcome.retries.append(
                AXFrameRetryRequest(
                    pid: resolvedResult.pid,
                    windowId: resolvedWindowId,
                    frame: resolvedResult.targetFrame
                )
            )
        }
        return outcome
    }

    func resolvedWindowId(for windowId: Int) -> Int {
        resolveWindowId(for: windowId)
    }

    func cancelAllPendingFrameState() -> [AXFrameTerminalDelivery] {
        let deliveries = pendingFrameObserversByRequestId.map { requestId, pendingObserver in
            let currentFrameHint = pendingFrameWrites[pendingObserver.windowId]
                ?? lastAppliedFrames[pendingObserver.windowId]
                ?? pendingObserver.currentFrameHint
            return AXFrameTerminalDelivery(
                result: AXFrameApplyResult(
                    requestId: requestId,
                    pid: pendingObserver.pid,
                    windowId: pendingObserver.windowId,
                    targetFrame: pendingObserver.targetFrame,
                    currentFrameHint: pendingObserver.currentFrameHint,
                    writeResult: .skipped(
                        targetFrame: pendingObserver.targetFrame,
                        currentFrameHint: currentFrameHint,
                        failureReason: .cancelled,
                        observedFrame: currentFrameHint
                    )
                ),
                observers: pendingObserver.observers
            )
        }

        pendingFrameObserversByRequestId.removeAll()
        observerRequestIdByWindowId.removeAll()
        pendingFrameWrites.removeAll()
        pendingFrameRequestIdByWindowId.removeAll()
        recentFrameWriteFailures.removeAll()
        retryBudgetByWindowId.removeAll()
        forceApplyWindowIds.removeAll()
        rekeyedWindowIdsByPreviousId.removeAll()

        return deliveries
    }

    private func cancelObserver(for windowId: Int) -> [AXFrameTerminalDelivery] {
        guard let requestId = observerRequestIdByWindowId.removeValue(forKey: windowId),
              let pendingObserver = pendingFrameObserversByRequestId.removeValue(forKey: requestId)
        else {
            return []
        }
        let currentFrameHint = pendingFrameWrites[windowId] ?? lastAppliedFrames[windowId]
        return [
            AXFrameTerminalDelivery(
                result: AXFrameApplyResult(
                    requestId: requestId,
                    pid: pendingObserver.pid,
                    windowId: pendingObserver.windowId,
                    targetFrame: pendingObserver.targetFrame,
                    currentFrameHint: pendingObserver.currentFrameHint,
                    writeResult: .skipped(
                        targetFrame: pendingObserver.targetFrame,
                        currentFrameHint: currentFrameHint,
                        failureReason: .cancelled,
                        observedFrame: currentFrameHint
                    )
                ),
                observers: pendingObserver.observers
            )
        ]
    }

    private func notifyPendingFrameObserver(with result: AXFrameApplyResult) -> [AXFrameTerminalDelivery] {
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

    private func shouldRetryFrameWrite(
        after result: AXFrameApplyResult,
        resultResolvedThroughRekey: Bool
    ) -> Bool {
        guard let failureReason = result.writeResult.failureReason else { return false }
        switch failureReason {
        case .cancelled:
            return resultResolvedThroughRekey
        case .suppressed:
            return false
        default:
            return true
        }
    }

    private func makeNextFrameApplicationRequestId() -> AXFrameRequestId {
        defer { nextFrameApplicationRequestId += 1 }
        return nextFrameApplicationRequestId
    }

    private func appendPendingFrameObserver(
        _ observer: @escaping AXFrameApplicationTerminalObserver,
        for windowId: Int,
        targetFrame: CGRect
    ) -> Bool {
        guard let requestId = observerRequestIdByWindowId[windowId],
              var pendingObserver = pendingFrameObserversByRequestId[requestId],
              pendingObserver.targetFrame.approximatelyEqual(to: targetFrame, tolerance: FrameTolerance.frameWrite)
        else {
            return false
        }

        pendingObserver.observers.append(observer)
        pendingFrameObserversByRequestId[requestId] = pendingObserver
        return true
    }

    private func discardPendingFrameObserver(for windowId: Int) -> [AXFrameTerminalDelivery] {
        cancelObserver(for: windowId)
    }

    private func successfulNoOpFrameApplyResult(
        requestId: AXFrameRequestId,
        pid: pid_t,
        windowId: Int,
        frame: CGRect,
        currentFrameHint: CGRect?,
        observedFrame: CGRect
    ) -> AXFrameApplyResult {
        AXFrameApplyResult(
            requestId: requestId,
            pid: pid,
            windowId: windowId,
            targetFrame: frame,
            currentFrameHint: currentFrameHint,
            writeResult: AXFrameWriteResult(
                targetFrame: frame,
                observedFrame: observedFrame,
                writeOrder: AXWindowService.frameWriteOrder(
                    currentFrame: currentFrameHint,
                    targetFrame: frame
                ),
                sizeError: .success,
                positionError: .success,
                failureReason: nil
            )
        )
    }

    private func resolveWindowId(for windowId: Int) -> Int {
        var resolvedWindowId = windowId
        var visitedWindowIds: Set<Int> = []
        while let rekeyedWindowId = rekeyedWindowIdsByPreviousId[resolvedWindowId],
              visitedWindowIds.insert(resolvedWindowId).inserted
        {
            resolvedWindowId = rekeyedWindowId
        }
        return resolvedWindowId
    }

    private func hasUnsettledFrameState(for windowId: Int) -> Bool {
        pendingFrameWrites[windowId] != nil
            || retryBudgetByWindowId[windowId] != nil
            || observerRequestIdByWindowId[windowId] != nil
    }

    private func clearSettledRekeyMappings(to windowId: Int) {
        guard !rekeyedWindowIdsByPreviousId.isEmpty,
              !hasUnsettledFrameState(for: windowId),
              rekeyedWindowIdsByPreviousId.values.contains(windowId)
        else { return }
        rekeyedWindowIdsByPreviousId = rekeyedWindowIdsByPreviousId.filter { _, mappedWindowId in
            mappedWindowId != windowId
        }
    }

    private func pruneRekeyMappingsAfterRemovingWindowState(for windowId: Int) {
        rekeyedWindowIdsByPreviousId = rekeyedWindowIdsByPreviousId.filter { previousWindowId, mappedWindowId in
            if mappedWindowId == windowId {
                return false
            }
            if previousWindowId == windowId {
                return hasUnsettledFrameState(for: mappedWindowId)
            }
            return true
        }
    }
}
