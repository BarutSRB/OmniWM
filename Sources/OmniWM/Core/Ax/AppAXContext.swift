import AppKit
import ApplicationServices
import Foundation
import os

final class LockedWindowIdSet: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<Int> = []

    func insert(_ id: Int) {
        lock.lock()
        ids.insert(id)
        lock.unlock()
    }

    func remove(_ id: Int) {
        lock.lock()
        ids.remove(id)
        lock.unlock()
    }

    func contains(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ids.contains(id)
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
    let requestId: AXFrameRequestId
    let pid: pid_t
    let windowId: Int
    let frame: CGRect
    let currentFrameHint: CGRect?
    let generation: Int
}

private final class AppAXContextCreationState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AppAXContext?, Error>?

    init(_ continuation: CheckedContinuation<AppAXContext?, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<AppAXContext?, Error>) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else { return false }
        continuation.resume(with: result)
        return true
    }
}

@MainActor
final class AppAXContext {
    let pid: pid_t
    let nsApp: NSRunningApplication

    private let axApp: ThreadGuardedValue<AXUIElement>
    private let windows: ThreadGuardedValue<[Int: AXUIElement]>
    private nonisolated(unsafe) var thread: Thread?
    private var activeFrameBatchJobs: [UUID: RunLoopJob] = [:]
    private let frameWriteGenerations = LockedWindowGenerationMap()
    let suppressedFrameWindowIds = LockedWindowIdSet()
    private let axObserver: ThreadGuardedValue<AXObserver?>
    private let focusedWindowObserver: ThreadGuardedValue<AXObserver?>
    private let subscribedWindows: ThreadGuardedValue<[Int: AXUIElement]>

    @MainActor static var onWindowDestroyed: ((pid_t, Int) -> Void)?
    @MainActor static var onWindowMiniaturized: ((pid_t, Int) -> Void)?
    @MainActor static var onFocusedWindowChanged: ((pid_t) -> Void)?

    @MainActor static var contexts: [pid_t: AppAXContext] = [:]
    @MainActor private static var inFlightCreations: [pid_t: Task<AppAXContext?, Error>] = [:]
    @MainActor static var contextFactoryForTests: ((NSRunningApplication) async throws -> AppAXContext?)?

    private nonisolated init(
        _ nsApp: NSRunningApplication,
        _ axApp: ThreadGuardedValue<AXUIElement>,
        _ windows: ThreadGuardedValue<[Int: AXUIElement]>,
        _ observer: ThreadGuardedValue<AXObserver?>,
        _ focusedWindowObserver: ThreadGuardedValue<AXObserver?>,
        _ subscribedWindows: ThreadGuardedValue<[Int: AXUIElement]>,
        _ thread: Thread
    ) {
        self.nsApp = nsApp
        pid = nsApp.processIdentifier
        self.axApp = axApp
        self.windows = windows
        axObserver = observer
        self.focusedWindowObserver = focusedWindowObserver
        self.subscribedWindows = subscribedWindows
        self.thread = thread
    }

    @MainActor
    static func getOrCreate(_ nsApp: NSRunningApplication) async throws -> AppAXContext? {
        let pid = nsApp.processIdentifier

        if let existing = contexts[pid] { return existing }
        if contextFactoryForTests == nil, pid == ProcessInfo.processInfo.processIdentifier { return nil }

        try Task.checkCancellation()

        if let inFlight = inFlightCreations[pid] {
            return try await inFlight.value
        }

        let task = Task<AppAXContext?, Error> { @MainActor in
            defer { inFlightCreations.removeValue(forKey: pid) }

            let context: AppAXContext?
            if let contextFactoryForTests {
                context = try await contextFactoryForTests(nsApp)
            } else {
                context = try await createContext(nsApp)
            }

            if let context {
                contexts[pid] = context
                WMLog.ax.info("AX context created pid=\(pid)")
            }
            return context
        }
        inFlightCreations[pid] = task

        return try await task.value
    }

    @MainActor
    private static func createContext(_ nsApp: NSRunningApplication) async throws -> AppAXContext? {
        let pid = nsApp.processIdentifier

        return try await withCheckedThrowingContinuation { continuation in
            let state = AppAXContextCreationState(continuation)
            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(2))
                _ = state.resume(with: .success(nil))
            }

            let thread = Thread {
                $appThreadToken.withValue(AppThreadToken(pid: pid)) {
                    let axApp = AXUIElementCreateApplication(pid)

                    var observer: AXObserver?
                    AXObserverCreate(pid, axWindowNotificationCallback, &observer)

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
                    let guardedWindows = ThreadGuardedValue([Int: AXUIElement]())
                    let guardedObserver = ThreadGuardedValue(observer)
                    let guardedFocusedWindowObserver = ThreadGuardedValue(focusObserver)
                    let guardedSubscribedWindows = ThreadGuardedValue([Int: AXUIElement]())
                    let currentThread = Thread.current

                    scheduleOnMainRunLoop {
                        timeoutTask.cancel()

                        let context = AppAXContext(
                            nsApp,
                            guardedAxApp,
                            guardedWindows,
                            guardedObserver,
                            guardedFocusedWindowObserver,
                            guardedSubscribedWindows,
                            currentThread
                        )
                        if state.resume(with: .success(context)) {
                            return
                        }

                        context.destroy()
                    }

                    let port = NSMachPort()
                    RunLoop.current.add(port, forMode: .default)

                    CFRunLoopRun()
                }
            }
            thread.name = "OmniWM-AX-\(nsApp.bundleIdentifier ?? "pid:\(pid)")"
            thread.start()
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

    nonisolated static func handleWindowMiniaturizedCallback(
        pid: pid_t,
        refcon: UnsafeMutableRawPointer?,
        handler: (@MainActor @Sendable (pid_t, Int) -> Void)? = nil
    ) {
        guard let windowId = destroyNotificationWindowId(from: refcon) else {
            assertionFailure("Received AX miniaturize callback without a valid windowId refcon")
            return
        }

        scheduleOnMainRunLoop {
            if let handler {
                handler(pid, windowId)
            } else {
                AppAXContext.onWindowMiniaturized?(pid, windowId)
            }
        }
    }

    private nonisolated static func addWindowNotifications(
        observer: AXObserver,
        element: AXUIElement,
        windowId: Int
    ) -> Bool {
        guard let refcon = destroyNotificationRefcon(for: windowId) else { return false }
        let destroyResult = AXObserverAddNotification(
            observer,
            element,
            kAXUIElementDestroyedNotification as CFString,
            refcon
        )
        AXObserverAddNotification(
            observer,
            element,
            kAXWindowMiniaturizedNotification as CFString,
            refcon
        )
        return destroyResult == .success
    }

    private nonisolated static func removeWindowNotifications(
        observer: AXObserver,
        element: AXUIElement
    ) {
        AXObserverRemoveNotification(
            observer,
            element,
            kAXUIElementDestroyedNotification as CFString
        )
        AXObserverRemoveNotification(
            observer,
            element,
            kAXWindowMiniaturizedNotification as CFString
        )
    }

    private nonisolated static func removeMissingWindowSubscription(
        windowId: Int,
        existingElement: AXUIElement?,
        observer: AXObserver?,
        subscribedWindows: ThreadGuardedValue<[Int: AXUIElement]>
    ) -> Bool {
        if let uintWindowId = UInt32(exactly: windowId),
           AXWindowService.pinnedWindowId(for: uintWindowId) == CGWindowID(uintWindowId)
        {
            return false
        }

        let element = subscribedWindows[windowId] ?? existingElement
        subscribedWindows[windowId] = nil
        if let observer, let element {
            AppAXContext.removeWindowNotifications(observer: observer, element: element)
        }
        return true
    }

    func getWindowsAsync() async throws -> [(AXWindowRef, Int)] {
        guard let thread else { return [] }
        nonisolated(unsafe) let appThread = thread

        let (results, deadWindowIds) = try await appThread.runInLoop { [
            axApp,
            windows,
            axObserver,
            subscribedWindows
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
                let role: String? = if roleResult == .success {
                    roleValue as? String
                } else {
                    nil
                }

                var subrole: String?
                if role != kAXWindowRole as String {
                    var subroleValue: CFTypeRef?
                    let subroleResult = AXUIElementCopyAttributeValue(
                        element,
                        kAXSubroleAttribute as CFString,
                        &subroleValue
                    )
                    if subroleResult == .success {
                        subrole = subroleValue as? String
                    }
                }

                guard AXWindowService.shouldTreatAsTopLevelWindow(role: role, subrole: subrole) else {
                    continue
                }

                let axRef = AXWindowRef(element: element, windowId: windowId)
                newWindows[windowId] = element
                seenIds.insert(windowId)
                results.append((axRef, windowId))

                if subscribedWindows[windowId] == nil, let obs = axObserver.value {
                    if AppAXContext.addWindowNotifications(observer: obs, element: element, windowId: windowId) {
                        subscribedWindows[windowId] = element
                    }
                }
            }

            var deadIds: [Int] = []
            windows.forEachKey { existingId in
                if !seenIds.contains(existingId) {
                    let existingElement = windows[existingId]
                    let didRemoveSubscription = AppAXContext.removeMissingWindowSubscription(
                        windowId: existingId,
                        existingElement: existingElement,
                        observer: axObserver.value,
                        subscribedWindows: subscribedWindows
                    )
                    if didRemoveSubscription {
                        deadIds.append(existingId)
                    } else if let existingElement {
                        newWindows[existingId] = existingElement
                    }
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

        appThread.runInLoopAsync { [windows, axObserver, subscribedWindows] _ in
            if let oldElement = subscribedWindows[oldWindowId],
               let observer = axObserver.value
            {
                AppAXContext.removeWindowNotifications(observer: observer, element: oldElement)
            }
            subscribedWindows[oldWindowId] = nil

            windows[oldWindowId] = nil
            windows[newWindow.windowId] = newWindow.element

            if subscribedWindows[newWindow.windowId] == nil,
               let observer = axObserver.value,
               AppAXContext.addWindowNotifications(
                   observer: observer,
                   element: newWindow.element,
                   windowId: newWindow.windowId
               )
            {
                subscribedWindows[newWindow.windowId] = newWindow.element
            }
        }
    }

    func removeWindowState(windowId: Int) {
        cancelFrameJob(for: windowId)
        unsuppressFrameWrites(for: [windowId])
        guard let thread else { return }
        nonisolated(unsafe) let appThread = thread

        appThread.runInLoopAsync { [windows, axObserver, subscribedWindows] _ in
            let existingElement = windows.value[windowId]
            if let element = subscribedWindows[windowId] ?? existingElement,
               let observer = axObserver.value
            {
                AppAXContext.removeWindowNotifications(observer: observer, element: element)
            }
            subscribedWindows[windowId] = nil
            windows[windowId] = nil
        }
    }

    func subscribedWindowCountForTests() async -> Int {
        guard let thread else { return 0 }
        nonisolated(unsafe) let appThread = thread
        return (try? await appThread.runInLoop { [subscribedWindows] _ in
            subscribedWindows.value.count
        }) ?? 0
    }

    func installSubscribedWindowsForTests(_ windowRefs: [AXWindowRef]) async throws {
        guard let thread else { return }
        nonisolated(unsafe) let appThread = thread
        _ = try await appThread.runInLoop { [subscribedWindows] _ in
            subscribedWindows.value = Dictionary(uniqueKeysWithValues: windowRefs.map { ($0.windowId, $0.element) })
        }
    }

    func installWindowAndSubscriptionForTests(_ windowRef: AXWindowRef) async throws {
        guard let thread else { return }
        nonisolated(unsafe) let appThread = thread
        _ = try await appThread.runInLoop { [windows, subscribedWindows] _ in
            windows.value[windowRef.windowId] = windowRef.element
            subscribedWindows.value[windowRef.windowId] = windowRef.element
        }
    }

    func removeMissingWindowForTests(windowId: Int) async throws {
        guard let thread else { return }
        nonisolated(unsafe) let appThread = thread
        _ = try await appThread.runInLoop { [windows, axObserver, subscribedWindows] _ in
            let didRemoveSubscription = AppAXContext.removeMissingWindowSubscription(
                windowId: windowId,
                existingElement: windows[windowId],
                observer: axObserver.value,
                subscribedWindows: subscribedWindows
            )
            if didRemoveSubscription {
                windows[windowId] = nil
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
        _ frames: [AXFrameApplicationRequest],
        completion: @escaping @MainActor ([AXFrameApplyResult]) -> Void
    ) {
        guard let thread else {
            completion(
                frames.map {
                    AXFrameApplyResult(
                        requestId: $0.requestId,
                        pid: $0.pid,
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
                requestId: $0.requestId,
                pid: $0.pid,
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
                            requestId: request.requestId,
                            pid: request.pid,
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
                            requestId: request.requestId,
                            pid: request.pid,
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
                            requestId: request.requestId,
                            pid: request.pid,
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
        WMLog.ax.info("AX context destroyed pid=\(self.pid)")
        AppAXContext.contexts.removeValue(forKey: self.pid)

        for (_, job) in activeFrameBatchJobs {
            job.cancel()
        }
        activeFrameBatchJobs = [:]

        nonisolated(unsafe) let appThread = thread
        appThread?.runInLoopAsync { [windows, axApp, axObserver, focusedWindowObserver, subscribedWindows] _ in
            let subscribed = subscribedWindows.valueIfExists ?? [:]
            if let obs = axObserver.valueIfExists.flatMap({ $0 }) {
                for (_, element) in subscribed {
                    AppAXContext.removeWindowNotifications(observer: obs, element: element)
                }
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
            }
            if let focusObs = focusedWindowObserver.valueIfExists.flatMap({ $0 }) {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(focusObs), .defaultMode)
            }
            subscribedWindows.destroy()
            axObserver.destroy()
            focusedWindowObserver.destroy()
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
                    let guardedWindows = ThreadGuardedValue([Int: AXUIElement]())
                    let guardedObserver = ThreadGuardedValue<AXObserver?>(nil)
                    let guardedFocusedWindowObserver = ThreadGuardedValue<AXObserver?>(nil)
                    let guardedSubscribedWindows = ThreadGuardedValue([Int: AXUIElement]())
                    let currentThread = Thread.current

                    Task { @MainActor in
                        continuation.resume(
                            returning: AppAXContext(
                                nsApp,
                                guardedAxApp,
                                guardedWindows,
                                guardedObserver,
                                guardedFocusedWindowObserver,
                                guardedSubscribedWindows,
                                currentThread
                            )
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
                requestId: request.requestId,
                pid: pid,
                windowId: windowId,
                targetFrame: targetFrame,
                currentFrameHint: currentFrameHint,
                writeResult: retryResult
            )
        }
        return AXFrameApplyResult(
            requestId: request.requestId,
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
            requestId: request.requestId,
            pid: pid,
            windowId: windowId,
            targetFrame: targetFrame,
            currentFrameHint: currentFrameHint,
            writeResult: refreshedResult
        )
    }

    return AXFrameApplyResult(
        requestId: request.requestId,
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

private func axWindowNotificationCallback(
    _: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    let notificationName = notification as String
    let isDestroyed = notificationName == (kAXUIElementDestroyedNotification as String)
    let isMiniaturized = notificationName == (kAXWindowMiniaturizedNotification as String)
    guard isDestroyed || isMiniaturized else { return }

    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return }

    if isDestroyed {
        AppAXContext.handleWindowDestroyedCallback(pid: pid, refcon: refcon)
    } else {
        AppAXContext.handleWindowMiniaturizedCallback(pid: pid, refcon: refcon)
    }
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
