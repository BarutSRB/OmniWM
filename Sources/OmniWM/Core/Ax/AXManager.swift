// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private let perAppTimeout: TimeInterval = 0.5

@MainActor
final class AXManager {
    typealias FrameApplicationTerminalObserver = AXFrameApplicationTerminalObserver

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
    var onTerminalFrameRefusal: ((AXFrameTerminalRefusal) -> Void)?

    private let frameLedger = AXFrameApplicationLedger()
    private var framesByPidBuffer: [pid_t: [AXFrameApplicationRequest]] = [:]
    private var frameApplicationBufferInUse = false
    private var pendingFrameRetryTasksByWindowId: [Int: Task<Void, Never>] = [:]
    private var pendingFrameRetryGenerationByWindowId: [Int: UInt64] = [:]
    private var nextFrameRetryGeneration: UInt64 = 1

    /// Window IDs belonging to inactive workspaces — checked LIVE in applyFramesParallel.
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
        activeWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        nativeInactiveWindowIds: Set<Int> = []
    ) {
        inactiveWorkspaceWindowIds.removeAll(keepingCapacity: true)
        for (wsId, windowId) in allEntries {
            if !activeWorkspaceIds.contains(wsId) {
                inactiveWorkspaceWindowIds.insert(windowId)
            }
        }
        inactiveWorkspaceWindowIds.formUnion(nativeInactiveWindowIds)
    }

    func markWindowActive(_ windowId: Int) {
        inactiveWorkspaceWindowIds.remove(windowId)
    }

    func markWindowInactive(_ windowId: Int) {
        inactiveWorkspaceWindowIds.insert(windowId)
    }

    func forceApplyNextFrame(for windowId: Int) {
        frameLedger.forceApplyNextFrame(for: windowId)
    }

    func lastAppliedFrame(for windowId: Int) -> CGRect? {
        frameLedger.lastAppliedFrame(for: windowId)
    }

    func recentFrameWriteFailure(for windowId: Int) -> AXFrameWriteFailureReason? {
        frameLedger.recentFrameWriteFailure(for: windowId)
    }

    func hasContext(for pid: pid_t) -> Bool {
        AppAXContext.contexts[pid] != nil
    }

    func hasPendingFrameWrite(for windowId: Int) -> Bool {
        frameLedger.hasPendingFrameWrite(for: windowId)
    }

    func pendingFrameWrite(for windowId: Int) -> CGRect? {
        frameLedger.pendingFrameWrite(for: windowId)
    }

    func shouldSuppressFrameChangeRelayout(for windowId: Int, observedFrame: CGRect?) -> Bool {
        frameLedger.shouldSuppressFrameChangeRelayout(for: windowId, observedFrame: observedFrame)
    }

    func clearInactiveWorkspaceWindows() {
        inactiveWorkspaceWindowIds.removeAll()
    }

    func rekeyWindowState(pid: pid_t, oldWindowId: Int, newWindow: AXWindowRef) {
        let newWindowId = newWindow.windowId
        guard oldWindowId != newWindowId else { return }
        AppAXContext.contexts[pid]?.rekeyWindow(oldWindowId: oldWindowId, newWindow: newWindow)
        frameLedger.rekeyWindowState(oldWindowId: oldWindowId, newWindowId: newWindowId)

        if inactiveWorkspaceWindowIds.remove(oldWindowId) != nil {
            inactiveWorkspaceWindowIds.insert(newWindowId)
        }

        if let retryTask = pendingFrameRetryTasksByWindowId.removeValue(forKey: oldWindowId) {
            pendingFrameRetryTasksByWindowId[newWindowId] = retryTask
        }
        if let retryGeneration = pendingFrameRetryGenerationByWindowId.removeValue(forKey: oldWindowId) {
            pendingFrameRetryGenerationByWindowId[newWindowId] = retryGeneration
        }
    }

    func confirmFrameWrite(for windowId: Int, frame: CGRect) {
        frameLedger.confirmFrameWrite(for: windowId, frame: frame)
    }

    func removeWindowState(pid: pid_t, windowId: Int) {
        AppAXContext.contexts[pid]?.removeWindowState(windowId: windowId)

        let deliveries = frameLedger.removeWindowState(windowId: windowId)
        cancelPendingFrameRetry(for: windowId)
        inactiveWorkspaceWindowIds.remove(windowId)

        for delivery in deliveries {
            delivery.deliver()
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

        cancelAllPendingFrameState()

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

        let visibleWindows = SkyLight.shared.queryAllVisibleWindows()
        var pidsWithWindows = Set(visibleWindows.map { $0.pid })

        // Some Electron apps are missed by the broad SLS enumeration but are
        // visible through CGWindowList. Add regular rendered windows from the
        // public API without changing apps already discovered through SLS.
        if let cgWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] {
            for window in cgWindows {
                guard let pidNumber = window[kCGWindowOwnerPID as String] as? Int,
                      let layer = window[kCGWindowLayer as String] as? Int,
                      layer == 0,
                      let alpha = window[kCGWindowAlpha as String] as? Double,
                      alpha > 0
                else { continue }
                pidsWithWindows.insert(pid_t(pidNumber))
            }
        }

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
        terminalObserver: FrameApplicationTerminalObserver? = nil,
        verify: Bool = true
    ) {
        enqueueFrameApplications(frames, isRetry: false, verify: verify, terminalObserver: terminalObserver)
    }

    private func enqueueFrameApplications(
        _ frames: [(pid: pid_t, windowId: Int, frame: CGRect)],
        isRetry: Bool,
        verify: Bool = true,
        terminalObserver: FrameApplicationTerminalObserver? = nil
    ) {
        if frameApplicationBufferInUse {
            var framesByPid: [pid_t: [AXFrameApplicationRequest]] = [:]
            framesByPid.reserveCapacity(min(frames.count, 8))
            enqueueFrameApplicationsUsingBuffer(
                frames,
                isRetry: isRetry,
                verify: verify,
                terminalObserver: terminalObserver,
                framesByPid: &framesByPid
            )
            return
        }

        frameApplicationBufferInUse = true
        defer {
            for key in Array(framesByPidBuffer.keys) {
                framesByPidBuffer[key]?.removeAll(keepingCapacity: true)
            }
            frameApplicationBufferInUse = false
        }

        enqueueFrameApplicationsUsingBuffer(
            frames,
            isRetry: isRetry,
            verify: verify,
            terminalObserver: terminalObserver,
            framesByPid: &framesByPidBuffer
        )
    }

    private func enqueueFrameApplicationsUsingBuffer(
        _ frames: [(pid: pid_t, windowId: Int, frame: CGRect)],
        isRetry: Bool,
        verify: Bool,
        terminalObserver: FrameApplicationTerminalObserver?,
        framesByPid: inout [pid_t: [AXFrameApplicationRequest]]
    ) {
        framesByPid.reserveCapacity(min(frames.count, 8))
        var deferredDeliveries: [AXFrameTerminalDelivery] = []

        for (pid, windowId, frame) in frames {
            if inactiveWorkspaceWindowIds.contains(windowId) {
                continue
            }
            let decision = frameLedger.prepareFrameApplication(
                pid: pid,
                windowId: windowId,
                frame: frame,
                isRetry: isRetry,
                verify: verify,
                terminalObserver: terminalObserver
            )
            if decision.shouldCancelPendingRetry {
                cancelPendingFrameRetry(for: windowId)
            }
            deferredDeliveries.append(contentsOf: decision.deliveries)
            guard let request = decision.request else { continue }
            if framesByPid[pid] == nil {
                framesByPid[pid] = []
                framesByPid[pid]?.reserveCapacity(8)
            }
            framesByPid[pid]?.append(request)
        }

        for (pid, appFrames) in framesByPid where !appFrames.isEmpty {
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

        for delivery in deferredDeliveries {
            delivery.deliver()
        }
    }

    func cancelPendingFrameJobs(_ entries: [(pid: pid_t, windowId: Int)]) {
        var deliveries: [AXFrameTerminalDelivery] = []
        for (pid, windowId) in uniqueFrameEntries(entries) {
            AppAXContext.contexts[pid]?.cancelFrameJob(for: windowId)
            deliveries.append(contentsOf: frameLedger.cancelFrameJob(windowId: windowId))
            cancelPendingFrameRetry(for: windowId)
        }
        for delivery in deliveries {
            delivery.deliver()
        }
    }

    func suppressFrameWrites(_ entries: [(pid: pid_t, windowId: Int)]) {
        var deliveries: [AXFrameTerminalDelivery] = []
        let entries = uniqueFrameEntries(entries)
        for (pid, windowIds) in groupedWindowIdsByPid(entries) {
            AppAXContext.contexts[pid]?.suppressFrameWrites(for: windowIds)
        }
        for (_, windowId) in entries {
            deliveries.append(contentsOf: frameLedger.suppressFrameWrite(windowId: windowId))
            cancelPendingFrameRetry(for: windowId)
        }
        for delivery in deliveries {
            delivery.deliver()
        }
    }

    func unsuppressFrameWrites(_ entries: [(pid: pid_t, windowId: Int)]) {
        for (pid, windowIds) in groupedWindowIdsByPid(uniqueFrameEntries(entries)) {
            AppAXContext.contexts[pid]?.unsuppressFrameWrites(for: windowIds)
        }
    }

    private func uniqueFrameEntries(_ entries: [(pid: pid_t, windowId: Int)]) -> [(pid: pid_t, windowId: Int)] {
        var uniqueEntries: [(pid: pid_t, windowId: Int)] = []
        uniqueEntries.reserveCapacity(entries.count)
        var seen: Set<WindowToken> = []
        for entry in entries {
            let token = WindowToken(pid: entry.pid, windowId: entry.windowId)
            guard seen.insert(token).inserted else { continue }
            uniqueEntries.append(entry)
        }
        return uniqueEntries
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
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }

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
        let outcome = frameLedger.handleFrameApplyResults(results)
        for retry in outcome.retries {
            scheduleFrameRetry(pid: retry.pid, windowId: retry.windowId, frame: retry.frame)
        }
        for delivery in outcome.deliveries {
            delivery.deliver()
        }
        for refusal in outcome.terminalRefusals {
            onTerminalFrameRefusal?(refusal)
        }
    }

    private func scheduleFrameRetry(pid: pid_t, windowId: Int, frame: CGRect) {
        cancelPendingFrameRetry(for: windowId)
        let generation = nextFrameRetryGeneration
        nextFrameRetryGeneration &+= 1
        pendingFrameRetryGenerationByWindowId[windowId] = generation
        pendingFrameRetryTasksByWindowId[windowId] = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            let currentWindowId = self.frameLedger.resolvedWindowId(for: windowId)
            guard self.pendingFrameRetryGenerationByWindowId[currentWindowId] == generation else { return }
            guard !self.frameLedger.hasPendingFrameWrite(for: currentWindowId) else { return }
            self.pendingFrameRetryGenerationByWindowId.removeValue(forKey: currentWindowId)
            self.pendingFrameRetryTasksByWindowId.removeValue(forKey: currentWindowId)
            self.enqueueFrameApplications([(pid, currentWindowId, frame)], isRetry: true)
        }
    }

    @discardableResult
    private func cancelPendingFrameRetry(for windowId: Int) -> Bool {
        guard let task = pendingFrameRetryTasksByWindowId.removeValue(forKey: windowId) else {
            pendingFrameRetryGenerationByWindowId.removeValue(forKey: windowId)
            return false
        }
        task.cancel()
        pendingFrameRetryGenerationByWindowId.removeValue(forKey: windowId)
        return true
    }

    private func cancelAllPendingFrameState() {
        for (_, task) in pendingFrameRetryTasksByWindowId {
            task.cancel()
        }
        pendingFrameRetryTasksByWindowId.removeAll()
        pendingFrameRetryGenerationByWindowId.removeAll()

        let deliveries = frameLedger.cancelAllPendingFrameState()
        for delivery in deliveries {
            delivery.deliver()
        }
    }
}
