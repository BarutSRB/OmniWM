import AppKit
import ApplicationServices
import Foundation

final class AppAXContext: @unchecked Sendable {
    let pid: pid_t
    let bundleId: String?
    let nsApp: NSRunningApplication

    private let axApp: ThreadGuardedValue<AXUIElement>
    private let subscription: ThreadGuardedValue<AXSubscription?>
    private let windows: ThreadGuardedValue<[Int: AXUIElement]>
    private var thread: Thread?
    private var setFrameJobs: [Int: RunLoopJob] = [:]

    var lastNativeFocusedWindowId: Int?

    private var windowsCount: Int = 0

    @MainActor private static var focusJob: RunLoopJob?

    @MainActor static var onAXEvent: ((AXEvent) -> Void)?

    @MainActor static var contexts: [pid_t: AppAXContext] = [:]
    @MainActor private static var wipPids: Set<pid_t> = []

    private init(
        _ nsApp: NSRunningApplication,
        _ axApp: AXUIElement,
        _ subscription: AXSubscription?,
        _ thread: Thread
    ) {
        self.nsApp = nsApp
        pid = nsApp.processIdentifier
        bundleId = nsApp.bundleIdentifier
        self.axApp = .init(axApp)
        self.subscription = .init(subscription)
        windows = .init([:])
        self.thread = thread
    }

    @MainActor
    static func getOrCreate(_ nsApp: NSRunningApplication) async throws -> AppAXContext? {
        let pid = nsApp.processIdentifier

        if pid == ProcessInfo.processInfo.processIdentifier { return nil }

        if let existing = contexts[pid] { return existing }

        try Task.checkCancellation()
        if !wipPids.insert(pid).inserted {
            try await Task.sleep(nanoseconds: 100_000_000)
            return try await getOrCreate(nsApp)
        }

        let thread = Thread {
            $appThreadToken.withValue(AppThreadToken(pid: pid, bundleId: nsApp.bundleIdentifier)) {
                let axApp = AXUIElementCreateApplication(pid)
                let job = RunLoopJob()

                let notifications = [
                    kAXWindowCreatedNotification,
                    kAXFocusedWindowChangedNotification
                ]
                let subscription = try? AXSubscription.bulkSubscribe(
                    nsApp,
                    axApp,
                    job,
                    notifications.map { $0 as String },
                    axObserverCallback
                )

                let isGood = subscription != nil
                let context = isGood ? AppAXContext(nsApp, axApp, subscription, Thread.current) : nil

                Task { @MainActor in
                    contexts[pid] = context
                    wipPids.remove(pid)
                }

                if isGood {
                    CFRunLoopRun()
                }
            }
        }
        thread.name = "OmniWM-AX-\(nsApp.bundleIdentifier ?? "pid:\(pid)")"
        thread.start()

        while contexts[pid] == nil, wipPids.contains(pid) {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        return contexts[pid]
    }

    func getWindowsAsync() async throws -> [(AXWindowRef, Int)] {
        guard let thread else { return [] }

        let interval = signpostIntervalNonIsolated("getWindowsAsync", "pid: \(pid)")
        defer { interval.end() }

        let (results, deadWindowIds) = try await thread.runInLoop { [axApp, windows, nsApp] job -> (
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

            let oldWindowIds = Set(windows.value.keys)
            var newWindows: [Int: AXUIElement] = [:]

            for element in windowElements {
                try job.checkCancellation()

                var windowId = 0
                let idResult = _AXUIElementGetWindow(element, &windowId)
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

                let axRef = AXWindowRef(id: UUID(), element: element)
                let windowType = AXWindowService.windowType(axRef, appPolicy: nsApp.activationPolicy)
                guard windowType == .tiling else { continue }

                newWindows[windowId] = element
                results.append((axRef, windowId))

                if windows.value[windowId] == nil {
                    let windowNotifications = [
                        kAXUIElementDestroyedNotification,
                        kAXMovedNotification,
                        kAXResizedNotification
                    ]
                    _ = try? AXSubscription.bulkSubscribe(
                        nsApp,
                        element,
                        job,
                        windowNotifications.map { $0 as String },
                        axObserverCallback
                    )
                }
            }

            let newWindowIds = Set(newWindows.keys)
            let deadIds = Array(oldWindowIds.subtracting(newWindowIds))

            windows.value = newWindows
            return (results, deadIds)
        }

        for deadWindowId in deadWindowIds {
            setFrameJobs.removeValue(forKey: deadWindowId)?.cancel()
        }

        windowsCount = results.count
        return results
    }

    func setFrame(windowId: Int, frame: CGRect) {
        setFrameJobs[windowId]?.cancel()
        setFrameJobs[windowId] = thread?.runInLoopAsync { [windows] _ in
            guard let element = windows.value[windowId] else { return }
            let axRef = AXWindowRef(id: UUID(), element: element)
            try? AXWindowService.setFrame(axRef, frame: frame)
        }
    }

    func setFramesBatch(_ frames: [(windowId: Int, frame: CGRect)]) {
        guard let thread else { return }

        for (windowId, _) in frames {
            setFrameJobs[windowId]?.cancel()
        }

        thread.runInLoopAsync { [axApp, windows] job in
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
                guard let element = windows.value[windowId] else { continue }
                let axRef = AXWindowRef(id: UUID(), element: element)
                try? AXWindowService.setFrame(axRef, frame: frame)
            }
        }
    }

    @MainActor
    func focus(windowId: Int) {
        AppAXContext.focusJob?.cancel()

        if !NSScreen.screensHaveSeparateSpaces || NSScreen.screens.count == 1,
           lastNativeFocusedWindowId == windowId || windowsCount == 1
        {
            nsApp.activate()
            lastNativeFocusedWindowId = windowId
        } else {
            lastNativeFocusedWindowId = windowId
            AppAXContext.focusJob = thread?.runInLoopAsync { [nsApp, windows] _ in
                guard let element = windows.value[windowId] else { return }

                AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)

                AXUIElementPerformAction(element, kAXRaiseAction as CFString)

                nsApp.activate()
            }
        }
    }

    func destroy() async {
        _ = await Task { @MainActor [pid] in
            _ = AppAXContext.contexts.removeValue(forKey: pid)
        }.result

        for (_, job) in setFrameJobs {
            job.cancel()
        }
        setFrameJobs = [:]

        thread?.runInLoopAsync { [windows, subscription, axApp] _ in
            subscription.destroy()
            windows.destroy()
            axApp.destroy()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        thread = nil
    }

    @MainActor
    static func garbageCollect() async {
        for (_, context) in contexts {
            if context.nsApp.isTerminated {
                await context.destroy()
            }
        }
    }
}

private func axObserverCallback(
    _: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _: UnsafeMutableRawPointer?
) {
    let notif = notification as String

    var pid: pid_t = 0
    let pidResult = AXUIElementGetPid(element, &pid)
    guard pidResult == .success else { return }

    var windowId = 0
    _ = _AXUIElementGetWindow(element, &windowId)

    let axRef = AXWindowRef(id: UUID(), element: element)

    Task { @MainActor in
        let event: AXEvent
        switch notif {
        case kAXWindowCreatedNotification:
            event = .created(axRef, pid, windowId)
        case kAXUIElementDestroyedNotification:
            event = .removed(axRef, pid, windowId)
        case kAXMovedNotification, kAXResizedNotification:
            event = .changed(axRef, pid, windowId)
        case kAXFocusedWindowChangedNotification:
            event = .focused(axRef, pid, windowId)
        default:
            return
        }
        AppAXContext.onAXEvent?(event)
    }
}

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ out: UnsafeMutablePointer<Int>) -> AXError
