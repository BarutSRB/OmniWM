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

@MainActor
final class AppAXContext {
    let pid: pid_t
    let nsApp: NSRunningApplication

    private let axApp: ThreadGuardedValue<AXUIElement>
    private let windows: ThreadGuardedValue<[Int: AXUIElement]>
    nonisolated(unsafe) private var thread: Thread?
    private var setFrameJobs: [Int: RunLoopJob] = [:]
    let suppressedFrameWindowIds = LockedWindowIdSet()
    private let axObserver: ThreadGuardedValue<AXObserver?>
    private let subscribedWindowIds: ThreadGuardedValue<Set<Int>>

    @MainActor static var onWindowDestroyed: ((pid_t, Int) -> Void)?
    @MainActor static var onWindowDestroyedUnknown: (() -> Void)?
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

    func getWindowsAsync() async throws -> [(AXWindowRef, Int)] {
        guard let thread else { return [] }
        nonisolated(unsafe) let appThread = thread

        let appPolicy = nsApp.activationPolicy
        let bundleId = nsApp.bundleIdentifier

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
                let windowType = AXWindowService.windowType(
                    axRef,
                    appPolicy: appPolicy,
                    bundleId: bundleId
                )
                guard windowType == .tiling else { continue }

                newWindows[windowId] = element
                seenIds.insert(windowId)
                results.append((axRef, windowId))

                if !subscribedWindowIds.contains(windowId), let obs = axObserver.value {
                    let subResult = AXObserverAddNotification(
                        obs,
                        element,
                        kAXUIElementDestroyedNotification as CFString,
                        nil
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
            setFrameJobs.removeValue(forKey: deadWindowId)?.cancel()
            unsuppressFrameWrites(for: [deadWindowId])
        }

        return results
    }

    func cancelFrameJob(for windowId: Int) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
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

    func setFramesBatch(_ frames: [(windowId: Int, frame: CGRect)]) {
        guard let thread else { return }
        nonisolated(unsafe) let appThread = thread

        for (windowId, _) in frames {
            setFrameJobs[windowId]?.cancel()
        }

        let suppression = suppressedFrameWindowIds

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

            for (windowId, frame) in frames {
                if job.isCancelled { break }
                if suppression.contains(windowId) {
                    continue
                }
                guard let element = windows[windowId] else {
                    continue
                }
                let axRef = AXWindowRef(element: element, windowId: windowId)
                try? AXWindowService.setFrame(axRef, frame: frame)
            }
        }

        for (windowId, _) in frames {
            setFrameJobs[windowId] = batchJob
        }
    }

    func destroy() {
        AppAXContext.contexts.removeValue(forKey: pid)

        for (_, job) in setFrameJobs {
            job.cancel()
        }
        setFrameJobs = [:]

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

    static func garbageCollect() {
        for (_, context) in contexts {
            if context.nsApp.isTerminated {
                context.destroy()
            }
        }
    }

}

private func axWindowDestroyedCallback(
    _: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _: UnsafeMutableRawPointer?
) {
    guard (notification as String) == (kAXUIElementDestroyedNotification as String) else { return }

    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return }

    var windowIdRaw: CGWindowID = 0
    _ = _AXUIElementGetWindow(element, &windowIdRaw)
    let windowId = Int(windowIdRaw)

    Task { @MainActor in
        if windowId != 0 {
            AppAXContext.onWindowDestroyed?(pid, windowId)
        } else {
            AppAXContext.onWindowDestroyedUnknown?()
        }
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

    Task { @MainActor in
        AppAXContext.onFocusedWindowChanged?(pid)
    }
}
