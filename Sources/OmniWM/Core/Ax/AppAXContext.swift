// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Foundation

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

    func invalidateAndMoveValue(from oldId: Int, to newId: Int) {
        lock.lock()
        let generation = (generations.removeValue(forKey: oldId) ?? 0) + 1
        generations[newId] = generation
        lock.unlock()
    }
}

private func axCallbackObserverKey(_ observer: AXObserver) -> UInt {
    UInt(bitPattern: Unmanaged.passUnretained(observer).toOpaque())
}

private struct AppAXFrameWriteRequest: Sendable {
    let requestId: AXFrameRequestId
    let pid: pid_t
    let windowId: Int
    let frame: CGRect
    let currentFrameHint: CGRect?
    let generation: Int
    let verify: Bool
}

private final class AppAXContextCreationState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AppAXContext?, Error>?

    init(_ continuation: CheckedContinuation<AppAXContext?, Error>) {
        self.continuation = continuation
    }

    func takeContinuation() -> CheckedContinuation<AppAXContext?, Error>? {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        return continuation
    }
}

@MainActor
final class AppAXContext {
    let pid: pid_t
    let nsApp: NSRunningApplication

    private let axApp: ThreadGuardedValue<AXUIElement>
    private let windows: ThreadGuardedValue<[Int: AXUIElement]>
    private nonisolated(unsafe) var thread: Thread?
    nonisolated var axThread: Thread? {
        thread
    }

    private var activeFrameBatchJobs: [UUID: RunLoopJob] = [:]
    private let frameWriteGenerations = LockedWindowGenerationMap()
    let suppressedFrameWindowIds = LockedWindowIdSet()
    private let axObserver: ThreadGuardedValue<AXObserver?>
    private let focusedWindowObserver: ThreadGuardedValue<AXObserver?>
    private let subscribedWindows: ThreadGuardedValue<[Int: AXUIElement]>
    private let axObserverCallbackKey: UInt?
    private let focusedWindowObserverCallbackKey: UInt?
    private let callbackGeneration: UInt64

    @MainActor static var contexts: [pid_t: AppAXContext] = [:]
    @MainActor private static var inFlightCreations: [pid_t: (
        generation: UInt64,
        task: Task<AppAXContext?, Error>
    )] = [:]

    private nonisolated init(
        _ nsApp: NSRunningApplication,
        _ axApp: ThreadGuardedValue<AXUIElement>,
        _ windows: ThreadGuardedValue<[Int: AXUIElement]>,
        _ observer: ThreadGuardedValue<AXObserver?>,
        _ focusedWindowObserver: ThreadGuardedValue<AXObserver?>,
        _ subscribedWindows: ThreadGuardedValue<[Int: AXUIElement]>,
        _ axObserverCallbackKey: UInt?,
        _ focusedWindowObserverCallbackKey: UInt?,
        _ callbackGeneration: UInt64,
        _ thread: Thread
    ) {
        self.nsApp = nsApp
        pid = nsApp.processIdentifier
        self.axApp = axApp
        self.windows = windows
        axObserver = observer
        self.focusedWindowObserver = focusedWindowObserver
        self.subscribedWindows = subscribedWindows
        self.axObserverCallbackKey = axObserverCallbackKey
        self.focusedWindowObserverCallbackKey = focusedWindowObserverCallbackKey
        self.callbackGeneration = callbackGeneration
        self.thread = thread
    }

    @MainActor
    static func getOrCreate(_ nsApp: NSRunningApplication) async throws -> AppAXContext? {
        let pid = nsApp.processIdentifier

        if let existing = contexts[pid] { return existing }
        if pid == ProcessInfo.processInfo.processIdentifier { return nil }

        try Task.checkCancellation()

        if let inFlight = inFlightCreations[pid] {
            return try await inFlight.task.value
        }

        let generation = appAXCallbackGenerationRegistry.currentGeneration
        let task = Task<AppAXContext?, Error> { @MainActor in
            defer {
                if inFlightCreations[pid]?.generation == generation {
                    inFlightCreations.removeValue(forKey: pid)
                }
            }

            let context = try await createContext(nsApp, generation: generation)
            guard appAXCallbackGenerationRegistry.isCurrent(generation) else {
                context?.destroy()
                return nil
            }
            if let context {
                contexts[pid] = context
            }
            return context
        }
        inFlightCreations[pid] = (generation: generation, task: task)

        return try await task.value
    }

    @MainActor
    static func shutdownAll() {
        appAXCallbackGenerationRegistry.advance()
        for (_, inFlight) in inFlightCreations {
            inFlight.task.cancel()
        }
        inFlightCreations.removeAll()
        for (_, context) in contexts {
            context.destroy()
        }
    }

    @MainActor
    private static func createContext(
        _ nsApp: NSRunningApplication,
        generation: UInt64
    ) async throws -> AppAXContext? {
        let pid = nsApp.processIdentifier

        return try await withCheckedThrowingContinuation { continuation in
            let state = AppAXContextCreationState(continuation)
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                state.takeContinuation()?.resume(returning: nil)
            }

            let thread = Thread {
                $appThreadToken.withValue(AppThreadToken(pid: pid)) {
                    let axApp = AXUIElementCreateApplication(pid)

                    var observer: AXObserver?
                    if AXObserverCreate(pid, axWindowNotificationCallback, &observer) != .success {
                        FallbackFiringRecorder.shared.note(.ax, "observerCreateFailed")
                    }

                    if let obs = observer {
                        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
                    } else {
                        FallbackFiringRecorder.shared.note(.ax, "observerRunLoopSourceSkipped")
                    }

                    var focusObserver: AXObserver?
                    if AXObserverCreate(pid, axFocusedWindowChangedCallback, &focusObserver) != .success {
                        FallbackFiringRecorder.shared.note(.ax, "focusObserverCreateFailed")
                    }

                    if let focusObs = focusObserver {
                        if AXObserverAddNotification(
                            focusObs,
                            axApp,
                            kAXFocusedWindowChangedNotification as CFString,
                            nil
                        ) != .success {
                            FallbackFiringRecorder.shared.note(.ax, "focusedWindowSubscribeFailed")
                        }
                        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(focusObs), .defaultMode)
                    } else {
                        FallbackFiringRecorder.shared.note(.ax, "focusObserverRunLoopSourceSkipped")
                    }

                    let guardedAxApp = ThreadGuardedValue(axApp)
                    let guardedWindows = ThreadGuardedValue([Int: AXUIElement]())
                    let guardedObserver = ThreadGuardedValue(observer)
                    let guardedFocusedWindowObserver = ThreadGuardedValue(focusObserver)
                    let guardedSubscribedWindows = ThreadGuardedValue([Int: AXUIElement]())
                    let observerCallbackKey = observer.map(axCallbackObserverKey)
                    let focusedWindowObserverCallbackKey = focusObserver.map(axCallbackObserverKey)
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
                            observerCallbackKey,
                            focusedWindowObserverCallbackKey,
                            generation,
                            currentThread
                        )
                        guard let continuation = state.takeContinuation() else {
                            context.destroy()
                            return
                        }

                        if let observerCallbackKey {
                            appAXCallbackGenerationRegistry.register(
                                observerKey: observerCallbackKey,
                                generation: generation
                            )
                        }
                        if let focusedWindowObserverCallbackKey {
                            appAXCallbackGenerationRegistry.register(
                                observerKey: focusedWindowObserverCallbackKey,
                                generation: generation
                            )
                        }
                        continuation.resume(returning: context)
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
        element: AXUIElement,
        observerKey: UInt,
        refcon: UnsafeMutableRawPointer?
    ) {
        guard let windowId = destroyNotificationWindowId(from: refcon) else {
            assertionFailure("Received AX destroy callback without a valid windowId refcon")
            return
        }
        appAXCallbackGenerationRegistry.performIfCurrent(observerKey: observerKey) {
            EventIntake.post(
                .axWindowDestroyed(
                    pid: pid,
                    axRef: AXWindowRef(element: element, windowId: windowId)
                )
            )
        }
    }

    nonisolated static func handleWindowMiniaturizedCallback(
        pid: pid_t,
        observerKey: UInt,
        refcon: UnsafeMutableRawPointer?
    ) {
        guard let windowId = destroyNotificationWindowId(from: refcon) else {
            assertionFailure("Received AX miniaturize callback without a valid windowId refcon")
            return
        }
        appAXCallbackGenerationRegistry.performIfCurrent(observerKey: observerKey) {
            EventIntake.post(.axWindowMiniaturized(pid: pid, windowId: windowId))
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
        if destroyResult != .success {
            FallbackFiringRecorder.shared.note(.ax, "destroySubscribeFailed")
        }
        if AXObserverAddNotification(
            observer,
            element,
            kAXWindowMiniaturizedNotification as CFString,
            refcon
        ) != .success {
            FallbackFiringRecorder.shared.note(.ax, "miniaturizeSubscribeFailed")
        }
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
        subscribedElement: AXUIElement?
    ) -> Bool {
        if let uintWindowId = UInt32(exactly: windowId),
           AXWindowService.hasPinnedAXElement(for: uintWindowId)
        {
            return false
        }

        let element = subscribedElement ?? existingElement
        if let observer, let element {
            AppAXContext.removeWindowNotifications(observer: observer, element: element)
        }
        return true
    }

    func getWindowsAsync(timeoutSeconds: TimeInterval = 0.5) async throws -> [AXEnumeratedWindow] {
        guard let thread else {
            throw AXWindowEnumerationError.contextUnavailable
        }
        nonisolated(unsafe) let appThread = thread

        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        let timeout = Duration.milliseconds(Int64(timeoutSeconds * 1_000))
        let (results, deadWindowIds) = try await appThread.runInLoop(timeout: timeout) { [
            pid,
            axApp,
            windows,
            axObserver,
            subscribedWindows
        ] job -> (
            [AXEnumeratedWindow],
            [Int]
        ) in
            let windowElements = try AXWindowEnumerationInspector.applicationWindowElements(
                axApp.value,
                deadline: deadline,
                checkCancellation: { try job.checkCancellation() }
            )
            var results: [AXEnumeratedWindow] = []
            results.reserveCapacity(windowElements.count)
            var seenIds = Set<Int>(minimumCapacity: windowElements.count)
            var newWindows: [Int: AXUIElement] = Dictionary(minimumCapacity: windowElements.count)

            for element in windowElements {
                try job.checkCancellation()
                guard let enumeratedWindow = try AXWindowEnumerationInspector.inspect(
                    element,
                    deadline: deadline,
                    checkCancellation: { try job.checkCancellation() }
                ) else {
                    continue
                }
                let windowId = enumeratedWindow.axRef.windowId
                if let resolvedElementPid = enumeratedWindow.axPid, resolvedElementPid != pid {
                    DiagnosticsEventRecorder.shared.recordLifecycle(
                        name: "ax.pidMismatch.expected=\(pid)",
                        pid: resolvedElementPid,
                        windowId: CGWindowID(windowId)
                    )
                }

                newWindows[windowId] = element
                seenIds.insert(windowId)
                results.append(enumeratedWindow)
            }

            try job.checkCancellation()
            for enumeratedWindow in results {
                let windowId = enumeratedWindow.axRef.windowId
                let element = enumeratedWindow.axRef.element
                if let subscribedElement = subscribedWindows[windowId],
                   !CFEqual(subscribedElement, element),
                   let observer = axObserver.value
                {
                    try job.checkCancellation()
                    AppAXContext.removeWindowNotifications(observer: observer, element: subscribedElement)
                    try job.checkCancellation()
                    subscribedWindows[windowId] = nil
                }
                if subscribedWindows[windowId] == nil, let observer = axObserver.value {
                    try job.checkCancellation()
                    if AppAXContext.addWindowNotifications(
                        observer: observer,
                        element: element,
                        windowId: windowId
                    ) {
                        try job.checkCancellation()
                        subscribedWindows[windowId] = element
                    }
                }
            }

            var deadIds: [Int] = []
            let existingWindowIds = Array(windows.value.keys)
            for existingId in existingWindowIds where !seenIds.contains(existingId) {
                let existingElement = windows[existingId]
                try job.checkCancellation()
                let didRemoveSubscription = AppAXContext.removeMissingWindowSubscription(
                    windowId: existingId,
                    existingElement: existingElement,
                    observer: axObserver.value,
                    subscribedElement: subscribedWindows[existingId]
                )
                try job.checkCancellation()
                if didRemoveSubscription {
                    subscribedWindows[existingId] = nil
                    deadIds.append(existingId)
                } else if let existingElement {
                    newWindows[existingId] = existingElement
                }
            }

            try job.checkCancellation()
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

    func bindWindow(_ window: AXWindowRef) -> Bool {
        guard let thread else { return false }
        _ = frameWriteGenerations.nextGeneration(for: window.windowId)
        nonisolated(unsafe) let appThread = thread
        appThread.runInLoopAsync { [windows, axObserver, subscribedWindows] job in
            guard !job.isCancelled else { return }
            AXUIElementSetMessagingTimeout(window.element, 0.5)
            defer { AXUIElementSetMessagingTimeout(window.element, 0) }
            try? AppAXContext.bindWindowElement(
                window,
                windows: windows,
                observer: axObserver.value,
                subscribedWindows: subscribedWindows,
                checkCancellation: { try job.checkCancellation() }
            )
        }
        return true
    }

    func bindWindowsAsync(
        _ boundWindows: [AXWindowRef],
        timeoutSeconds: TimeInterval = 0.5
    ) async throws -> Bool {
        guard !boundWindows.isEmpty else { return true }
        guard let thread else { return false }
        for window in boundWindows {
            _ = frameWriteGenerations.nextGeneration(for: window.windowId)
        }
        nonisolated(unsafe) let appThread = thread
        let timeout = Duration.milliseconds(Int64(timeoutSeconds * 1_000))
        return try await appThread.runInLoop(timeout: timeout) { [windows, axObserver, subscribedWindows] job in
            for window in boundWindows {
                try job.checkCancellation()
                AXUIElementSetMessagingTimeout(window.element, Float(timeoutSeconds))
                do {
                    defer { AXUIElementSetMessagingTimeout(window.element, 0) }
                    try AppAXContext.bindWindowElement(
                        window,
                        windows: windows,
                        observer: axObserver.value,
                        subscribedWindows: subscribedWindows,
                        checkCancellation: { try job.checkCancellation() }
                    )
                }
                try job.checkCancellation()
            }
            return true
        }
    }

    func rekeyWindow(oldWindowId: Int, newWindow: AXWindowRef) -> Bool {
        guard let thread else { return false }
        frameWriteGenerations.invalidateAndMoveValue(from: oldWindowId, to: newWindow.windowId)

        if suppressedFrameWindowIds.contains(oldWindowId) {
            suppressedFrameWindowIds.remove(oldWindowId)
            suppressedFrameWindowIds.insert(newWindow.windowId)
        }

        nonisolated(unsafe) let appThread = thread

        appThread.runInLoopAsync { [windows, axObserver, subscribedWindows] job in
            guard !job.isCancelled else { return }
            if oldWindowId != newWindow.windowId,
               let oldElement = subscribedWindows[oldWindowId],
               let observer = axObserver.value
            {
                AXUIElementSetMessagingTimeout(oldElement, 0.5)
                AppAXContext.removeWindowNotifications(observer: observer, element: oldElement)
                AXUIElementSetMessagingTimeout(oldElement, 0)
                guard !job.isCancelled else { return }
            }
            AXUIElementSetMessagingTimeout(newWindow.element, 0.5)
            defer { AXUIElementSetMessagingTimeout(newWindow.element, 0) }
            guard (try? AppAXContext.bindWindowElement(
                newWindow,
                windows: windows,
                observer: axObserver.value,
                subscribedWindows: subscribedWindows,
                checkCancellation: { try job.checkCancellation() }
            )) != nil else {
                return
            }
            if oldWindowId != newWindow.windowId {
                subscribedWindows[oldWindowId] = nil
                windows[oldWindowId] = nil
            }
        }
        return true
    }

    private nonisolated static func bindWindowElement(
        _ window: AXWindowRef,
        windows: ThreadGuardedValue<[Int: AXUIElement]>,
        observer: AXObserver?,
        subscribedWindows: ThreadGuardedValue<[Int: AXUIElement]>,
        checkCancellation: () throws -> Void
    ) throws {
        let windowId = window.windowId
        let subscribedElement = subscribedWindows[windowId]
        let replacesSubscription = subscribedElement.map { !CFEqual($0, window.element) } == true
        if replacesSubscription, let subscribedElement, let observer {
            try checkCancellation()
            removeWindowNotifications(observer: observer, element: subscribedElement)
            try checkCancellation()
        }

        let needsSubscription = subscribedElement == nil || replacesSubscription
        let didAddSubscription: Bool
        if needsSubscription, let observer {
            try checkCancellation()
            didAddSubscription = addWindowNotifications(
                observer: observer,
                element: window.element,
                windowId: windowId
            )
            try checkCancellation()
        } else {
            didAddSubscription = false
        }

        try checkCancellation()
        windows[windowId] = window.element
        if replacesSubscription {
            subscribedWindows[windowId] = nil
        }
        if didAddSubscription {
            subscribedWindows[windowId] = window.element
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

    func suppressFrameWrites(for windowIds: [Int]) {
        guard !windowIds.isEmpty else { return }
        for windowId in windowIds {
            _ = frameWriteGenerations.nextGeneration(for: windowId)
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
                generation: frameWriteGenerations.nextGeneration(for: $0.windowId),
                verify: $0.verify
            )
        }
        let suppression = suppressedFrameWindowIds
        let generations = frameWriteGenerations
        let batchId = UUID()
        let currentPid = pid

        let batchJob = appThread.runInLoopAsync { [self, axApp, windows] job in
            let latencyActive = AXWriteLatencyTrace.shared.isActive
            let batchStart = latencyActive ? CACurrentMediaTime() : 0
            var slowestWriteMs = 0.0
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
                let writeStart = latencyActive ? CACurrentMediaTime() : 0
                results.append(
                    applyFrameWriteRequest(
                        request,
                        pid: currentPid,
                        windows: windows,
                        generations: generations
                    )
                )
                if latencyActive {
                    slowestWriteMs = max(slowestWriteMs, (CACurrentMediaTime() - writeStart) * 1000)
                }
            }

            if latencyActive {
                AXWriteLatencyTrace.shared.record(
                    AXWriteLatencyTrace.Record(
                        mediaTime: CACurrentMediaTime(),
                        pid: currentPid,
                        count: requests.count,
                        totalMs: (CACurrentMediaTime() - batchStart) * 1000,
                        slowestMs: slowestWriteMs,
                        enhancedUI: wasEnabled
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
        if let axObserverCallbackKey {
            appAXCallbackGenerationRegistry.unregister(observerKey: axObserverCallbackKey)
        }
        if let focusedWindowObserverCallbackKey {
            appAXCallbackGenerationRegistry.unregister(observerKey: focusedWindowObserverCallbackKey)
        }

        if AppAXContext.contexts[pid] === self {
            AppAXContext.contexts.removeValue(forKey: pid)
        }

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
    windows: ThreadGuardedValue<[Int: AXUIElement]>,
    generations: LockedWindowGenerationMap
) -> AXFrameApplyResult {
    let targetFrame = request.frame
    let currentFrameHint = request.currentFrameHint
    let windowId = request.windowId

    guard generations.isCurrent(request.generation, for: windowId) else {
        return cancelledFrameApplyResult(for: request)
    }

    if let element = windows[windowId] {
        let axRef = AXWindowRef(element: element, windowId: windowId)
        guard generations.isCurrent(request.generation, for: windowId) else {
            return cancelledFrameApplyResult(for: request)
        }
        let initialResult = AXWindowService.setFrame(
            axRef,
            frame: targetFrame,
            currentFrameHint: currentFrameHint,
            verify: request.verify
        )
        guard generations.isCurrent(request.generation, for: windowId) else {
            return cancelledFrameApplyResult(for: request)
        }
        if initialResult.shouldRetryAfterRefresh,
           generations.isCurrent(request.generation, for: windowId),
           let refreshedAXRef = AXWindowService.axWindowRef(for: UInt32(windowId), pid: pid)
        {
            windows[windowId] = refreshedAXRef.element
            guard generations.isCurrent(request.generation, for: windowId) else {
                return cancelledFrameApplyResult(for: request)
            }
            let retryResult = AXWindowService.setFrame(
                refreshedAXRef,
                frame: targetFrame,
                currentFrameHint: currentFrameHint,
                verify: request.verify
            )
            guard generations.isCurrent(request.generation, for: windowId) else {
                return cancelledFrameApplyResult(for: request)
            }
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

    if generations.isCurrent(request.generation, for: windowId),
       let refreshedAXRef = AXWindowService.axWindowRef(for: UInt32(windowId), pid: pid)
    {
        windows[windowId] = refreshedAXRef.element
        guard generations.isCurrent(request.generation, for: windowId) else {
            return cancelledFrameApplyResult(for: request)
        }
        let refreshedResult = AXWindowService.setFrame(
            refreshedAXRef,
            frame: targetFrame,
            currentFrameHint: currentFrameHint,
            verify: request.verify
        )
        guard generations.isCurrent(request.generation, for: windowId) else {
            return cancelledFrameApplyResult(for: request)
        }
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

private func cancelledFrameApplyResult(for request: AppAXFrameWriteRequest) -> AXFrameApplyResult {
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
}

private func axWindowNotificationCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    let notificationName = notification as String

    var pid: pid_t = 0
    let pidStatus = AXUIElementGetPid(element, &pid)
    RawAXNotificationTrace.record(
        name: notificationName,
        pid: pid,
        windowId: refcon.map { Int(bitPattern: $0) }
    )

    let isDestroyed = notificationName == (kAXUIElementDestroyedNotification as String)
    let isMiniaturized = notificationName == (kAXWindowMiniaturizedNotification as String)
    guard isDestroyed || isMiniaturized else { return }
    guard pidStatus == .success else { return }

    DiagnosticsEventRecorder.shared.recordLifecycle(name: notificationName, pid: pid)
    let observerKey = axCallbackObserverKey(observer)

    if isDestroyed {
        AppAXContext.handleWindowDestroyedCallback(
            pid: pid,
            element: element,
            observerKey: observerKey,
            refcon: refcon
        )
    } else {
        AppAXContext.handleWindowMiniaturizedCallback(pid: pid, observerKey: observerKey, refcon: refcon)
    }
}

private func axFocusedWindowChangedCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _: UnsafeMutableRawPointer?
) {
    guard (notification as String) == (kAXFocusedWindowChangedNotification as String) else { return }

    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return }

    RawAXNotificationTrace.record(name: kAXFocusedWindowChangedNotification as String, pid: pid, windowId: nil)
    DiagnosticsEventRecorder.shared.recordLifecycle(name: kAXFocusedWindowChangedNotification as String, pid: pid)

    appAXCallbackGenerationRegistry.performIfCurrent(observerKey: axCallbackObserverKey(observer)) {
        EventIntake.post(.axFocusedWindowChanged(pid: pid))
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
