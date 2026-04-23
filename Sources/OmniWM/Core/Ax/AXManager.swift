// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import ApplicationServices
import Foundation

private let perAppTimeout: TimeInterval = 0.5

enum FrameConfirmResult: String, Sendable {
    case cachedNoOp = "cached_noop"
    case confirmedWrite = "confirmed_write"
}

@MainActor
final class AXManager {
    typealias FrameApplicationTerminalObserver = @MainActor (AXFrameApplyResult) -> Void

    struct FullRescanEnumerationSnapshot {
        let windows: [(AXWindowRef, pid_t, Int)]
        let failedPIDs: Set<pid_t>

        static let empty = FullRescanEnumerationSnapshot(windows: [], failedPIDs: [])
    }

    private static let systemUIBundleIds: Set<String> = [
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.Spotlight"
    ]

    private var appTerminationObserver: NSObjectProtocol?
    private var appLaunchObserver: NSObjectProtocol?
    var onAppLaunched: ((NSRunningApplication) -> Void)?
    var onAppTerminated: ((pid_t) -> Void)?
    var currentWindowsAsyncOverride: (@MainActor () async -> [(AXWindowRef, pid_t, Int)])?
    var fullRescanEnumerationOverrideForTests: (@MainActor () async -> FullRescanEnumerationSnapshot)?
    var frameApplyOverrideForTests: (([AXFrameApplicationRequest]) -> [AXFrameApplyResult])?
    var onFrameConfirmed: ((pid_t, Int, CGRect, FrameConfirmResult) -> Void)?

    private struct PendingFrameObserver {
        var windowId: Int
        let pid: pid_t
        let targetFrame: CGRect
        let currentFrameHint: CGRect?
        var observers: [FrameApplicationTerminalObserver]
    }

    private var framesByPidBuffer: [pid_t: [AXFrameApplicationRequest]] = [:]
    private var lastAppliedFrames: [Int: CGRect] = [:]
    private var pendingFrameWrites: [Int: CGRect] = [:]
    private var recentFrameWriteFailures: [Int: AXFrameWriteFailureReason] = [:]
    private var retryBudgetByWindowId: [Int: Int] = [:]
    private var forceApplyWindowIds: Set<Int> = []
    private var pendingFrameObserversByRequestId: [AXFrameRequestId: PendingFrameObserver] = [:]
    private var observerRequestIdByWindowId: [Int: AXFrameRequestId] = [:]
    private var rekeyedWindowIdsByPreviousId: [Int: Int] = [:]
    private var nextFrameApplicationRequestId: AXFrameRequestId = 1


    private(set) var inactiveWorkspaceWindowIds: Set<Int> = []

    init() {
        setupTerminationObserver()
        setupLaunchObserver()
    }

    private func setupTerminationObserver() {
        appTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let pid = app.processIdentifier
            Task { @MainActor in
                self?.onAppTerminated?(pid)
                if let context = AppAXContext.contexts[pid] {
                    context.destroy()
                }
            }
        }
    }

    private func setupLaunchObserver() {
        appLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            Task { @MainActor in
                self?.onAppLaunched?(app)
            }
        }
    }

    func updateInactiveWorkspaceWindows(
        allEntries: [(workspaceId: WorkspaceDescriptor.ID, windowId: Int)],
        activeWorkspaceIds: Set<WorkspaceDescriptor.ID>
    ) {
        inactiveWorkspaceWindowIds.removeAll(keepingCapacity: true)
        for (wsId, windowId) in allEntries {
            if !activeWorkspaceIds.contains(wsId) {
                inactiveWorkspaceWindowIds.insert(windowId)
            }
        }
    }

    func markWindowActive(_ windowId: Int) {
        inactiveWorkspaceWindowIds.remove(windowId)
    }

    func markWindowInactive(_ windowId: Int) {
        inactiveWorkspaceWindowIds.insert(windowId)
    }

    func forceApplyNextFrame(for windowId: Int) {
        forceApplyWindowIds.insert(windowId)
    }

    func lastAppliedFrame(for windowId: Int) -> CGRect? {
        lastAppliedFrames[windowId]
    }

    func recentFrameWriteFailure(for windowId: Int) -> AXFrameWriteFailureReason? {
        recentFrameWriteFailures[windowId]
    }

    func hasContext(for pid: pid_t) -> Bool {
        AppAXContext.contexts[pid] != nil
    }

    var usesFrameApplyOverrideForTests: Bool {
        frameApplyOverrideForTests != nil
    }

    func hasPendingFrameWrite(for windowId: Int) -> Bool {
        pendingFrameWrites[windowId] != nil
    }

    func shouldPreferObservedFrame(for windowId: Int) -> Bool {
        pendingFrameWrites[windowId] != nil || recentFrameWriteFailures[windowId] != nil
    }

    func clearInactiveWorkspaceWindows() {
        inactiveWorkspaceWindowIds.removeAll()
    }

    func rekeyWindowState(pid: pid_t, oldWindowId: Int, newWindow: AXWindowRef) {
        let newWindowId = newWindow.windowId
        guard oldWindowId != newWindowId else { return }
        rekeyedWindowIdsByPreviousId[oldWindowId] = newWindowId
        let remappedWindowIds = rekeyedWindowIdsByPreviousId.compactMap { previousWindowId, mappedWindowId in
            mappedWindowId == oldWindowId ? previousWindowId : nil
        }
        for previousWindowId in remappedWindowIds {
            rekeyedWindowIdsByPreviousId[previousWindowId] = newWindowId
        }

        if inactiveWorkspaceWindowIds.remove(oldWindowId) != nil {
            inactiveWorkspaceWindowIds.insert(newWindowId)
        }

        if let frame = lastAppliedFrames.removeValue(forKey: oldWindowId) {
            lastAppliedFrames[newWindowId] = frame
        }

        if let frame = pendingFrameWrites.removeValue(forKey: oldWindowId) {
            pendingFrameWrites[newWindowId] = frame
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

        AppAXContext.contexts[pid]?.rekeyWindow(oldWindowId: oldWindowId, newWindow: newWindow)
    }

    func confirmFrameWrite(for windowId: Int, pid: pid_t? = nil, frame: CGRect) {
        lastAppliedFrames[windowId] = frame
        recentFrameWriteFailures.removeValue(forKey: windowId)
        retryBudgetByWindowId.removeValue(forKey: windowId)
        if let pid {
            onFrameConfirmed?(pid, windowId, frame, .confirmedWrite)
        }
    }

    func setPendingFrameWriteForTests(windowId: Int, frame: CGRect?) {
        if let frame {
            pendingFrameWrites[windowId] = frame
        } else {
            pendingFrameWrites.removeValue(forKey: windowId)
        }
    }

    func cleanup() {
        if let observer = appTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appTerminationObserver = nil
        }
        if let observer = appLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appLaunchObserver = nil
        }

        Task { @MainActor in
            for (_, context) in AppAXContext.contexts {
                context.destroy()
            }
        }
    }

    func windowsForApp(_ app: NSRunningApplication) async -> [(AXWindowRef, pid_t, Int)] {
        guard shouldTrack(app) else { return [] }
        do {
            guard let context = try await AppAXContext.getOrCreate(app) else { return [] }
            let appWindows = try await withTimeoutOrNil(seconds: perAppTimeout) {
                try await context.getWindowsAsync()
            }
            if let windows = appWindows {
                return windows.map { ($0.0, app.processIdentifier, $0.1) }
            }
        } catch {}
        return []
    }

    func requestPermission() -> Bool {
        if AccessibilityPermissionMonitor.shared.isGranted { return true }

        let options: NSDictionary = [axTrustedCheckOptionPrompt as NSString: true]
        _ = AXIsProcessTrustedWithOptions(options)

        return AccessibilityPermissionMonitor.shared.isGranted
    }

    func currentWindowsAsync() async -> [(AXWindowRef, pid_t, Int)] {
        return await fullRescanEnumerationSnapshot().windows
    }

    func fullRescanEnumerationSnapshot() async -> FullRescanEnumerationSnapshot {
        AppAXContext.garbageCollect()
        if let fullRescanEnumerationOverrideForTests {
            return await fullRescanEnumerationOverrideForTests()
        }
        if let currentWindowsAsyncOverride {
            return .init(windows: await currentWindowsAsyncOverride(), failedPIDs: [])
        }

        let visibleWindows = SkyLight.shared.queryAllVisibleWindows()
        let pidsWithWindows = Set(visibleWindows.map { $0.pid })

        let apps = NSWorkspace.shared.runningApplications.filter {
            shouldTrack($0) && pidsWithWindows.contains($0.processIdentifier)
        }

        return await withTaskGroup(
            of: (pid: pid_t, windows: [(AXWindowRef, pid_t, Int)], failed: Bool).self
        ) { group in
            for app in apps {
                group.addTask {
                    do {
                        guard let context = try await AppAXContext.getOrCreate(app) else {
                            return (app.processIdentifier, [], true)
                        }

                        let appWindows = try await self.withTimeoutOrNil(seconds: perAppTimeout) {
                            try await context.getWindowsAsync()
                        }

                        if let windows = appWindows {
                            return (
                                app.processIdentifier,
                                windows.map { ($0.0, app.processIdentifier, $0.1) },
                                false
                            )
                        }
                    } catch {
                    }
                    return (app.processIdentifier, [], true)
                }
            }

            var results: [(AXWindowRef, pid_t, Int)] = []
            var failedPIDs: Set<pid_t> = []
            for await result in group {
                results.append(contentsOf: result.windows)
                if result.failed {
                    failedPIDs.insert(result.pid)
                }
            }
            return .init(windows: results, failedPIDs: failedPIDs)
        }
    }

    func applyFramesParallel(
        _ frames: [(pid: pid_t, windowId: Int, frame: CGRect)],
        terminalObserver: FrameApplicationTerminalObserver? = nil
    ) {
        enqueueFrameApplications(frames, isRetry: false, terminalObserver: terminalObserver)
    }

    private func enqueueFrameApplications(
        _ frames: [(pid: pid_t, windowId: Int, frame: CGRect)],
        isRetry: Bool,
        terminalObserver: FrameApplicationTerminalObserver? = nil
    ) {
        for key in framesByPidBuffer.keys {
            framesByPidBuffer[key]?.removeAll(keepingCapacity: true)
        }

        for (pid, windowId, frame) in frames {
            if inactiveWorkspaceWindowIds.contains(windowId) {
                continue
            }
            let cachedFrame = lastAppliedFrames[windowId]
            let pendingFrame = pendingFrameWrites[windowId]
            let hasRecentFailure = recentFrameWriteFailures[windowId] != nil
            let shouldForceApply = forceApplyWindowIds.remove(windowId) != nil
            if !shouldForceApply {
                if let pendingFrame,
                   pendingFrame.approximatelyEqual(to: frame, tolerance: 0.5)
                {
                    if let terminalObserver,
                       !isRetry,
                       appendPendingFrameObserver(
                           terminalObserver,
                           for: windowId,
                           targetFrame: frame
                       )
                    {
                        continue
                    }
                    if terminalObserver == nil || isRetry {
                        continue
                    }
                } else if let cached = cachedFrame,
                   cached.approximatelyEqual(to: frame, tolerance: 0.5),
                   !hasRecentFailure
                {
                    if let terminalObserver {
                        terminalObserver(
                            successfulNoOpFrameApplyResult(
                                requestId: makeNextFrameApplicationRequestId(),
                                pid: pid,
                                windowId: windowId,
                                frame: frame,
                                currentFrameHint: cachedFrame,
                                observedFrame: cached
                            )
                        )
                    }
                    onFrameConfirmed?(pid, windowId, cached, .cachedNoOp)
                    continue
                }
            }

            if !isRetry,
               let requestId = observerRequestIdByWindowId[windowId],
               let pendingObserver = pendingFrameObserversByRequestId[requestId],
               !pendingObserver.targetFrame.approximatelyEqual(to: frame, tolerance: 0.5)
            {
                discardPendingFrameObserver(for: windowId)
            }

            let existingObserverRequestId = observerRequestIdByWindowId[windowId]
            let requestId = makeNextFrameApplicationRequestId()
            pendingFrameWrites[windowId] = frame
            recentFrameWriteFailures.removeValue(forKey: windowId)
            if isRetry,
               let existingObserverRequestId,
               var pendingObserver = pendingFrameObserversByRequestId[existingObserverRequestId],
               pendingObserver.targetFrame.approximatelyEqual(to: frame, tolerance: 0.5)
            {
                pendingFrameObserversByRequestId.removeValue(forKey: existingObserverRequestId)
                pendingObserver.windowId = windowId
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
            if framesByPidBuffer[pid] == nil {
                framesByPidBuffer[pid] = []
                framesByPidBuffer[pid]?.reserveCapacity(8)
            }
            framesByPidBuffer[pid]?.append(
                AXFrameApplicationRequest(
                    requestId: requestId,
                    pid: pid,
                    windowId: windowId,
                    frame: frame,
                    currentFrameHint: cachedFrame
                )
            )
        }

        if let frameApplyOverrideForTests {
            let requestsForTests = framesByPidBuffer.values.flatMap { $0 }
            guard !requestsForTests.isEmpty else { return }
            handleFrameApplyResults(frameApplyOverrideForTests(requestsForTests))
            return
        }

        for (pid, appFrames) in framesByPidBuffer where !appFrames.isEmpty {
            guard let context = AppAXContext.contexts[pid] else {
                handleFrameApplyResults(
                    appFrames.map {
                        AXFrameApplyResult(
                            requestId: $0.requestId,
                            pid: pid,
                            windowId: $0.windowId,
                            targetFrame: $0.frame,
                            currentFrameHint: $0.currentFrameHint,
                            writeResult: .skipped(
                                targetFrame: $0.frame,
                                currentFrameHint: $0.currentFrameHint,
                                failureReason: .contextUnavailable
                            )
                        )
                    }
                )
                continue
            }
            context.setFramesBatch(appFrames) { [weak self] results in
                self?.handleFrameApplyResults(results)
            }
        }
    }

    func cancelPendingFrameJobs(_ entries: [(pid: pid_t, windowId: Int)]) {
        for (pid, windowId) in entries {
            AppAXContext.contexts[pid]?.cancelFrameJob(for: windowId)
        }
    }

    func suppressFrameWrites(_ entries: [(pid: pid_t, windowId: Int)]) {
        var cancelledResults: [(PendingFrameObserver, AXFrameApplyResult)] = []
        for (_, windowId) in entries {
            let currentFrameHint = pendingFrameWrites[windowId] ?? lastAppliedFrames[windowId]
            if let requestId = observerRequestIdByWindowId.removeValue(forKey: windowId),
               let pendingObserver = pendingFrameObserversByRequestId.removeValue(forKey: requestId)
            {
                cancelledResults.append((
                    pendingObserver,
                    AXFrameApplyResult(
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
                    )
                ))
            }
            lastAppliedFrames.removeValue(forKey: windowId)
            pendingFrameWrites.removeValue(forKey: windowId)
            recentFrameWriteFailures.removeValue(forKey: windowId)
            retryBudgetByWindowId.removeValue(forKey: windowId)
            forceApplyWindowIds.remove(windowId)
        }
        for (pid, windowIds) in groupedWindowIdsByPid(entries) {
            AppAXContext.contexts[pid]?.suppressFrameWrites(for: windowIds)
        }
        for (pendingObserver, result) in cancelledResults {
            let deliveredResult = pendingObserver.windowId == result.windowId
                ? result
                : result.rekeyed(to: pendingObserver.windowId)
            for observer in pendingObserver.observers {
                observer(deliveredResult)
            }
        }
    }

    func unsuppressFrameWrites(_ entries: [(pid: pid_t, windowId: Int)]) {
        for (pid, windowIds) in groupedWindowIdsByPid(entries) {
            AppAXContext.contexts[pid]?.unsuppressFrameWrites(for: windowIds)
        }
    }

    func applyPositionsViaSkyLight(
        _ positions: [(windowId: Int, origin: CGPoint)],
        allowInactive: Bool = false
    ) {
        let filtered = allowInactive
            ? positions
            : positions.filter { !inactiveWorkspaceWindowIds.contains($0.windowId) }
        guard !filtered.isEmpty else { return }
        let batchPositions = filtered.map {
            (windowId: UInt32($0.windowId), origin: ScreenCoordinateSpace.toWindowServer(point: $0.origin))
        }
        SkyLight.shared.batchMoveWindows(batchPositions)
    }

    private func withTimeoutOrNil<T: Sendable>(
        seconds: TimeInterval,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T? {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }

            if let result = try await group.next() {
                group.cancelAll()
                return result
            }
            return nil
        }
    }

    private func shouldTrack(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated, app.activationPolicy != .prohibited else { return false }

        if let bundleId = app.bundleIdentifier, Self.systemUIBundleIds.contains(bundleId) {
            return false
        }

        return true
    }

    private func groupedWindowIdsByPid(
        _ entries: [(pid: pid_t, windowId: Int)]
    ) -> [pid_t: [Int]] {
        var grouped: [pid_t: [Int]] = [:]
        for (pid, windowId) in entries {
            grouped[pid, default: []].append(windowId)
        }
        return grouped
    }

    private func handleFrameApplyResults(_ results: [AXFrameApplyResult]) {
        for result in results {
            let resolvedWindowId = resolveWindowId(for: result.windowId)
            let resolvedResult = resolvedWindowId == result.windowId ? result : result.rekeyed(to: resolvedWindowId)
            guard let pendingFrame = pendingFrameWrites[resolvedWindowId],
                  pendingFrame.approximatelyEqual(to: resolvedResult.targetFrame, tolerance: 0.5)
            else {
                continue
            }

            pendingFrameWrites.removeValue(forKey: resolvedWindowId)

            if let confirmedFrame = resolvedResult.confirmedFrame {
                lastAppliedFrames[resolvedWindowId] = confirmedFrame
                recentFrameWriteFailures.removeValue(forKey: resolvedWindowId)
                retryBudgetByWindowId.removeValue(forKey: resolvedWindowId)
                onFrameConfirmed?(
                    resolvedResult.pid,
                    resolvedWindowId,
                    confirmedFrame,
                    .confirmedWrite
                )
                notifyPendingFrameObserver(with: resolvedResult)
                continue
            }

            if let failureReason = resolvedResult.writeResult.failureReason {
                recentFrameWriteFailures[resolvedWindowId] = failureReason
            }

            let remainingRetries = retryBudgetByWindowId[resolvedWindowId] ?? 0
            guard remainingRetries > 0,
                  shouldRetryFrameWrite(after: resolvedResult)
            else {
                retryBudgetByWindowId.removeValue(forKey: resolvedWindowId)
                notifyPendingFrameObserver(with: resolvedResult)
                continue
            }

            retryBudgetByWindowId[resolvedWindowId] = remainingRetries - 1
            forceApplyWindowIds.insert(resolvedWindowId)

            let pid = resolvedResult.pid
            let frame = resolvedResult.targetFrame
            Task { @MainActor [weak self] in
                guard let self else { return }
                let currentWindowId = self.resolveWindowId(for: resolvedWindowId)
                guard self.pendingFrameWrites[currentWindowId] == nil else { return }
                self.enqueueFrameApplications([(pid, currentWindowId, frame)], isRetry: true)
            }
        }
    }

    private func notifyPendingFrameObserver(with result: AXFrameApplyResult) {
        guard let pendingObserver = pendingFrameObserversByRequestId.removeValue(forKey: result.requestId) else {
            return
        }
        if observerRequestIdByWindowId[pendingObserver.windowId] == result.requestId {
            observerRequestIdByWindowId.removeValue(forKey: pendingObserver.windowId)
        }
        let deliveredResult = pendingObserver.windowId == result.windowId
            ? result
            : result.rekeyed(to: pendingObserver.windowId)
        for observer in pendingObserver.observers {
            observer(deliveredResult)
        }
    }

    private func shouldRetryFrameWrite(after result: AXFrameApplyResult) -> Bool {
        guard let failureReason = result.writeResult.failureReason else { return false }
        switch failureReason {
        case .cancelled, .suppressed, .invalidTargetFrame:
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
        _ observer: @escaping FrameApplicationTerminalObserver,
        for windowId: Int,
        targetFrame: CGRect
    ) -> Bool {
        guard let requestId = observerRequestIdByWindowId[windowId],
              var pendingObserver = pendingFrameObserversByRequestId[requestId],
              pendingObserver.targetFrame.approximatelyEqual(to: targetFrame, tolerance: 0.5)
        else {
            return false
        }

        pendingObserver.observers.append(observer)
        pendingFrameObserversByRequestId[requestId] = pendingObserver
        return true
    }

    private func discardPendingFrameObserver(for windowId: Int) {
        guard let requestId = observerRequestIdByWindowId.removeValue(forKey: windowId) else {
            return
        }
        pendingFrameObserversByRequestId.removeValue(forKey: requestId)
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
}
