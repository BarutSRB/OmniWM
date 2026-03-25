import AppKit
import ApplicationServices
import Foundation

final class LockedWindowIdSet: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<Int> = []

    func insert(_ id: Int) {
        lock.lock(); ids.insert(id); lock.unlock()
    }
    func remove(_ id: Int) {
        lock.lock(); ids.remove(id); lock.unlock()
    }
    func contains(_ id: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }; return ids.contains(id)
    }
}

final class LockedWindowGenerationMap: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [Int: Int] = [:]

    func nextGeneration(for id: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let next = (generations[id] ?? 0) + 1
        generations[id] = next
        return next
    }

    func isCurrent(_ generation: Int, for id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generations[id] == generation
    }

    func remove(_ id: Int) {
        lock.lock()
        generations.removeValue(forKey: id)
        lock.unlock()
    }

    func moveValue(from oldId: Int, to newId: Int) {
        lock.lock()
        let generation = generations.removeValue(forKey: oldId)
        if let generation {
            generations[newId] = generation
        }
        lock.unlock()
    }
}

private struct AppAXFrameWriteRequest: Sendable {
    let windowId: Int
    let frame: CGRect
    let currentFrameHint: CGRect?
    let generation: Int
}

@MainActor
final class AppAXContext {
    let pid: pid_t
    let nsApp: NSRunningApplication

    private let axApp: ThreadGuardedValue<AXUIElement>
    private let windows: ThreadGuardedValue<[Int: AXUIElement]>
    nonisolated(unsafe) private var thread: Thread?
    private var activeFrameBatchJobs: [UUID: RunLoopJob] = [:]
    private let frameWriteGenerations = LockedWindowGenerationMap()
    let suppressedFrameWindowIds = LockedWindowIdSet()
    private let axObserver: ThreadGuardedValue<AXObserver?>
    private let subscribedWindowIds: ThreadGuardedValue<Set<Int>>

    @MainActor static var onWindowDestroyed: ((pid_t, Int) -> Void)?
    @MainActor static var onFocusedWindowChanged: ((pid_t) -> Void)?

    @MainActor static var contexts: [pid_t: AppAXContext] = [:]
    @MainActor private static var wipPids: Set<pid_t> = []
    @MainActor private static var pendingContinuations: [pid_t: [CheckedContinuation<AppAXContext?, Error>]] = [:]
    @MainActor private static var timeoutTasks: [pid_t: Task<Void, Never>] = [:]

    nonisolated private init(
        _ nsApp: NSRunningApplication,
        _ axApp: ThreadGuardedValue<AXUIElement>,
        _ observer: ThreadGuardedValue<AXObserver?>,
        _ thread: Thread
    ) {
        self.nsApp = nsApp
        pid = nsApp.processIdentifier
        self.axApp = axApp
        windows = .init([:])
        axObserver = observer
        subscribedWindowIds = .init([])
        self.thread = thread
    }

    @MainActor
    static func getOrCreate(_ nsApp: NSRunningApplication) async throws -> AppAXContext? {
        let pid = nsApp.processIdentifier

        if pid == ProcessInfo.processInfo.processIdentifier { return nil }

        if let existing = contexts[pid] { return existing }

        try Task.checkCancellation()

        if wipPids.contains(pid) {
            let result: AppAXContext? = try await withThrowingTaskGroup(of: AppAXContext?.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { continuation in
                        Task { @MainActor in
                            pendingContinuations[pid, default: []].append(continuation)
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .milliseconds(500))
                    return nil
                }
                guard let r = try await group.next() else { return nil }
                group.cancelAll()
                return r
            }
            return result
        }

        wipPids.insert(pid)

        timeoutTasks[pid] = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                if contexts[pid] == nil, wipPids.contains(pid) {
                    wipPids.remove(pid)
                    timeoutTasks.removeValue(forKey: pid)
                    for cont in pendingContinuations.removeValue(forKey: pid) ?? [] {
                        cont.resume(returning: nil)
                    }
                }
            }
        }

        let thread = Thread {
            $appThreadToken.withValue(AppThreadToken(pid: pid)) {
                let axApp = AXUIElementCreateApplication(pid)

                var observer: AXObserver?
                AXObserverCreate(pid, axWindowDestroyedCallback, &observer)

                if let obs = observer {
                    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
                }

                var focusObserver: AXObserver?
                AXObserverCreate(pid, axFocusedWindowChangedCallback, &focusObserver)

                if let focusObs = focusObserver {
                    AXObserverAddNotification(
                        focusObs,
                        axApp,
                        kAXFocusedWindowChangedNotification as CFString,
                        nil
                    )
                    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(focusObs), .defaultMode)
                }

                let guardedAxApp = ThreadGuardedValue(axApp)
                let guardedObserver = ThreadGuardedValue(observer)
                let currentThread = Thread.current

                Task { @MainActor in
                    let context = AppAXContext(nsApp, guardedAxApp, guardedObserver, currentThread)
                    contextDidCreate(context, pid: pid)
                }

                let port = NSMachPort()
                RunLoop.current.add(port, forMode: .default)

                CFRunLoopRun()
            }
        }
        thread.name = "OmniWM-AX-\(nsApp.bundleIdentifier ?? "pid:\(pid)")"
        thread.start()

        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuations[pid, default: []].append(continuation)
        }
    }

    @MainActor
    private static func contextDidCreate(_ context: AppAXContext, pid: pid_t) {
        contexts[pid] = context
        wipPids.remove(pid)
        timeoutTasks.removeValue(forKey: pid)?.cancel()
        for continuation in pendingContinuations.removeValue(forKey: pid) ?? [] {
            continuation.resume(returning: context)
        }
    }

    nonisolated static func destroyNotificationRefcon(for windowId: Int) -> UnsafeMutableRawPointer? {
        guard windowId > 0 else { return nil }
        return UnsafeMutableRawPointer(bitPattern: windowId)
    }

    nonisolated static func destroyNotificationWindowId(
        from refcon: UnsafeMutableRawPointer?
    ) -> Int? {
        guard let refcon else { return nil }
        let windowId = Int(bitPattern: refcon)
        guard windowId > 0 else { return nil }
        return windowId
    }

    nonisolated static func handleWindowDestroyedCallback(
        pid: pid_t,
        refcon: UnsafeMutableRawPointer?,
        handler: (@MainActor @Sendable (pid_t, Int) -> Void)? = nil
    ) {
        guard let windowId = destroyNotificationWindowId(from: refcon) else {
            assertionFailure("Received AX destroy callback without a valid windowId refcon")
            return
        }

        scheduleOnMainRunLoop {
            if let handler {
                handler(pid, windowId)
            } else {
                AppAXContext.onWindowDestroyed?(pid, windowId)
            }
        }
    }

    func getWindowsAsync() async throws -> [(AXWindowRef, Int)] {
        guard let thread else { return [] }
        nonisolated(unsafe) let appThread = thread

        let (results, deadWindowIds) = try await appThread.runInLoop { [
            axApp,
            windows,
            axObserver,
            subscribedWindowIds
        ] job -> (
            [(AXWindowRef, Int)],
            [Int]
        ) in
            var results: [(AXWindowRef, Int)] = []

            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                axApp.value,
                kAXWindowsAttribute as CFString,
                &value
            )

            guard result == .success, let windowElements = value as? [AXUIElement] else {
                return (results, [])
            }

            var seenIds = Set<Int>(minimumCapacity: windowElements.count)
            var newWindows: [Int: AXUIElement] = Dictionary(minimumCapacity: windowElements.count)

            for element in windowElements {
                try job.checkCancellation()

                var windowIdRaw: CGWindowID = 0
                let idResult = _AXUIElementGetWindow(element, &windowIdRaw)
                let windowId = Int(windowIdRaw)
                guard idResult == .success else { continue }

                var roleValue: CFTypeRef?
                let roleResult = AXUIElementCopyAttributeValue(
                    element,
                    kAXRoleAttribute as CFString,
                    &roleValue
                )
                guard roleResult == .success,
                      let role = roleValue as? String,
                      role == kAXWindowRole as String else { continue }

                let axRef = AXWindowRef(element: element, windowId: windowId)
                newWindows[windowId] = element
                seenIds.insert(windowId)
                results.append((axRef, windowId))

                if !subscribedWindowIds.contains(windowId), let obs = axObserver.value {
                    guard let destroyRefcon = AppAXContext.destroyNotificationRefcon(for: windowId) else {
                        continue
                    }
                    let subResult = AXObserverAddNotification(
                        obs,
                        element,
                        kAXUIElementDestroyedNotification as CFString,
                        destroyRefcon
                    )
                    if subResult == .success {
                        subscribedWindowIds.insert(windowId)
                    }
                }
            }

            var deadIds: [Int] = []
            windows.forEachKey { existingId in
                if !seenIds.contains(existingId) {
                    deadIds.append(existingId)
                    subscribedWindowIds.remove(existingId)
                }
            }

            windows.value = newWindows
            return (results, deadIds)
        }

        for deadWindowId in deadWindowIds {
            frameWriteGenerations.remove(deadWindowId)
            unsuppressFrameWrites(for: [deadWindowId])
        }

        return results
    }

    func cancelFrameJob(for windowId: Int) {
        _ = frameWriteGenerations.nextGeneration(for: windowId)
    }

    func rekeyWindow(oldWindowId: Int, newWindow: AXWindowRef) {
        guard oldWindowId != newWindow.windowId else { return }
        frameWriteGenerations.moveValue(from: oldWindowId, to: newWindow.windowId)

        if suppressedFrameWindowIds.contains(oldWindowId) {
            suppressedFrameWindowIds.remove(oldWindowId)
            suppressedFrameWindowIds.insert(newWindow.windowId)
        }

        guard let thread else { return }
        nonisolated(unsafe) let appThread = thread

        appThread.runInLoopAsync { [windows, axObserver, subscribedWindowIds] _ in
            windows.value.removeValue(forKey: oldWindowId)
            windows.value[newWindow.windowId] = newWindow.element

            subscribedWindowIds.remove(oldWindowId)
            if !subscribedWindowIds.contains(newWindow.windowId),
               let observer = axObserver.value,
               let destroyRefcon = AppAXContext.destroyNotificationRefcon(for: newWindow.windowId)
            {
                let result = AXObserverAddNotification(
                    observer,
                    newWindow.element,
                    kAXUIElementDestroyedNotification as CFString,
                    destroyRefcon
                )
                if result == .success {
                    subscribedWindowIds.insert(newWindow.windowId)
                }
            }
        }
    }

    func suppressFrameWrites(for windowIds: [Int]) {
        guard !windowIds.isEmpty else { return }
        for windowId in windowIds {
            suppressedFrameWindowIds.insert(windowId)
        }
    }

    func unsuppressFrameWrites(for windowIds: [Int]) {
        guard !windowIds.isEmpty else { return }
        for windowId in windowIds {
            suppressedFrameWindowIds.remove(windowId)
        }
    }

    func setFramesBatch(
        _ frames: [(windowId: Int, frame: CGRect, currentFrameHint: CGRect?)],
        completion: @escaping @MainActor ([AXFrameApplyResult]) -> Void
    ) {
        guard let thread else {
            completion(
                frames.map {
                    AXFrameApplyResult(
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
            return
        }
        nonisolated(unsafe) let appThread = thread
        let requests = frames.map {
            AppAXFrameWriteRequest(
                windowId: $0.windowId,
                frame: $0.frame,
                currentFrameHint: $0.currentFrameHint,
                generation: frameWriteGenerations.nextGeneration(for: $0.windowId)
            )
        }
        let suppression = suppressedFrameWindowIds
        let generations = frameWriteGenerations
        let batchId = UUID()
        let currentPid = pid

        let batchJob = appThread.runInLoopAsync { [axApp, windows] job in
            let enhancedUIKey = "AXEnhancedUserInterface" as CFString
            var wasEnabled = false
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp.value, enhancedUIKey, &value) == .success,
               let boolValue = value as? Bool
            {
                wasEnabled = boolValue
            }

            if wasEnabled {
                AXUIElementSetAttributeValue(axApp.value, enhancedUIKey, kCFBooleanFalse)
            }

            defer {
                if wasEnabled {
                    AXUIElementSetAttributeValue(axApp.value, enhancedUIKey, kCFBooleanTrue)
                }
            }

            var results: [AXFrameApplyResult] = []
            results.reserveCapacity(requests.count)

            for request in requests {
                if job.isCancelled {
                    results.append(
                        AXFrameApplyResult(
                            pid: currentPid,
                            windowId: request.windowId,
                            targetFrame: request.frame,
                            currentFrameHint: request.currentFrameHint,
                            writeResult: .skipped(
                                targetFrame: request.frame,
                                currentFrameHint: request.currentFrameHint,
                                failureReason: .cancelled
                            )
                        )
                    )
                    continue
                }
                if !generations.isCurrent(request.generation, for: request.windowId) {
                    results.append(
                        AXFrameApplyResult(
                            pid: currentPid,
                            windowId: request.windowId,
                            targetFrame: request.frame,
                            currentFrameHint: request.currentFrameHint,
                            writeResult: .skipped(
                                targetFrame: request.frame,
                                currentFrameHint: request.currentFrameHint,
                                failureReason: .cancelled
                            )
                        )
                    )
                    continue
                }
                if suppression.contains(request.windowId) {
                    results.append(
                        AXFrameApplyResult(
                            pid: currentPid,
                            windowId: request.windowId,
                            targetFrame: request.frame,
                            currentFrameHint: request.currentFrameHint,
                            writeResult: .skipped(
                                targetFrame: request.frame,
                                currentFrameHint: request.currentFrameHint,
                                failureReason: .suppressed
                            )
                        )
                    )
                    continue
                }
                results.append(
                    applyFrameWriteRequest(
                        request,
                        pid: currentPid,
                        windows: windows
                    )
                )
            }

            scheduleOnMainRunLoop { [weak self] in
                self?.activeFrameBatchJobs.removeValue(forKey: batchId)
                completion(results)
            }
        }
        activeFrameBatchJobs[batchId] = batchJob
    }

    func destroy() {
        AppAXContext.contexts.removeValue(forKey: pid)

        for (_, job) in activeFrameBatchJobs {
            job.cancel()
        }
        activeFrameBatchJobs = [:]

        nonisolated(unsafe) let appThread = thread
        appThread?.runInLoopAsync { [windows, axApp, axObserver, subscribedWindowIds] _ in
            if let obs = axObserver.valueIfExists.flatMap({ $0 }) {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
            }
            subscribedWindowIds.destroy()
            axObserver.destroy()
            windows.destroy()
            axApp.destroy()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        thread = nil
    }

    static func makeForTests(
        processIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
    ) async -> AppAXContext? {
        let nsApp = NSRunningApplication(processIdentifier: processIdentifier)
            ?? NSWorkspace.shared.frontmostApplication
            ?? NSWorkspace.shared.runningApplications.first(where: { !$0.isTerminated })
        guard let nsApp else {
            return nil
        }
        let resolvedPid = nsApp.processIdentifier

        return await withCheckedContinuation { continuation in
            let thread = Thread {
                $appThreadToken.withValue(AppThreadToken(pid: resolvedPid)) {
                    let axApp = AXUIElementCreateApplication(resolvedPid)
                    let guardedAxApp = ThreadGuardedValue(axApp)
                    let guardedObserver = ThreadGuardedValue<AXObserver?>(nil)
                    let currentThread = Thread.current

                    Task { @MainActor in
                        continuation.resume(
                            returning: AppAXContext(nsApp, guardedAxApp, guardedObserver, currentThread)
                        )
                    }

                    let port = NSMachPort()
                    RunLoop.current.add(port, forMode: .default)
                    CFRunLoopRun()
                }
            }
            thread.name = "OmniWM-AX-Test-\(resolvedPid)"
            thread.start()
        }
    }

    func installWindowsForTests(_ windowRefs: [AXWindowRef]) async throws {
        guard let thread else { return }
        nonisolated(unsafe) let appThread = thread
        _ = try await appThread.runInLoop { [windows] _ in
            windows.value = Dictionary(uniqueKeysWithValues: windowRefs.map { ($0.windowId, $0.element) })
        }
    }

    static func garbageCollect() {
        for (_, context) in contexts {
            if context.nsApp.isTerminated {
                context.destroy()
            }
        }
    }

}

private func applyFrameWriteRequest(
    _ request: AppAXFrameWriteRequest,
    pid: pid_t,
    windows: ThreadGuardedValue<[Int: AXUIElement]>
) -> AXFrameApplyResult {
    let targetFrame = request.frame
    let currentFrameHint = request.currentFrameHint
    let windowId = request.windowId

    if let element = windows[windowId] {
        let axRef = AXWindowRef(element: element, windowId: windowId)
        let initialResult = AXWindowService.setFrame(
            axRef,
            frame: targetFrame,
            currentFrameHint: currentFrameHint
        )
        if initialResult.shouldRetryAfterRefresh,
           let refreshedAXRef = AXWindowService.axWindowRef(for: UInt32(windowId), pid: pid)
        {
            windows[windowId] = refreshedAXRef.element
            let retryResult = AXWindowService.setFrame(
                refreshedAXRef,
                frame: targetFrame,
                currentFrameHint: currentFrameHint
            )
            return AXFrameApplyResult(
                pid: pid,
                windowId: windowId,
                targetFrame: targetFrame,
                currentFrameHint: currentFrameHint,
                writeResult: retryResult
            )
        }
        return AXFrameApplyResult(
            pid: pid,
            windowId: windowId,
            targetFrame: targetFrame,
            currentFrameHint: currentFrameHint,
            writeResult: initialResult
        )
    }

    if let refreshedAXRef = AXWindowService.axWindowRef(for: UInt32(windowId), pid: pid) {
        windows[windowId] = refreshedAXRef.element
        let refreshedResult = AXWindowService.setFrame(
            refreshedAXRef,
            frame: targetFrame,
            currentFrameHint: currentFrameHint
        )
        return AXFrameApplyResult(
            pid: pid,
            windowId: windowId,
            targetFrame: targetFrame,
            currentFrameHint: currentFrameHint,
            writeResult: refreshedResult
        )
    }

    return AXFrameApplyResult(
        pid: pid,
        windowId: windowId,
        targetFrame: targetFrame,
        currentFrameHint: currentFrameHint,
        writeResult: .skipped(
            targetFrame: targetFrame,
            currentFrameHint: currentFrameHint,
            failureReason: .cacheMiss
        )
    )
}

private func axWindowDestroyedCallback(
    _: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard (notification as String) == (kAXUIElementDestroyedNotification as String) else { return }

    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return }

    AppAXContext.handleWindowDestroyedCallback(pid: pid, refcon: refcon)
}

private func axFocusedWindowChangedCallback(
    _: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _: UnsafeMutableRawPointer?
) {
    guard (notification as String) == (kAXFocusedWindowChangedNotification as String) else { return }

    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return }

    scheduleOnMainRunLoop {
        AppAXContext.onFocusedWindowChanged?(pid)
    }
}

private func scheduleOnMainRunLoop(_ work: @escaping @MainActor () -> Void) {
    let mainRunLoop = CFRunLoopGetMain()
    CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) {
        MainActor.assumeIsolated {
            work()
        }
    }
    CFRunLoopWakeUp(mainRunLoop)
}
