import AppKit
import ApplicationServices
import Foundation

private let perAppTimeout: TimeInterval = 0.5

@MainActor
final class AXManager {
    private var appTerminationObserver: NSObjectProtocol?
    var onWindowEvent: ((AXEvent) -> Void)?
    private let pollIntervalNanos: UInt64 = 250_000_000
    private let pollTimeout: TimeInterval = 30

    init() {
        setupTerminationObserver()

        AppAXContext.onAXEvent = { [weak self] event in
            self?.onWindowEvent?(event)
        }
    }

    private func setupTerminationObserver() {
        appTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let pid = app.processIdentifier
            Task { @MainActor in
                if let context = AppAXContext.contexts[pid] {
                    await context.destroy()
                }
            }
        }
    }

    func cleanup() {
        if let observer = appTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appTerminationObserver = nil
        }

        Task { @MainActor in
            for (_, context) in AppAXContext.contexts {
                await context.destroy()
            }
        }
    }

    func ensurePermission() async -> Bool {
        if AXIsProcessTrusted() { return true }

        let options: NSDictionary = [axTrustedCheckOptionPrompt as NSString: true]
        _ = AXIsProcessTrustedWithOptions(options)

        let deadline = Date().addingTimeInterval(pollTimeout)
        while Date() < deadline {
            if AXIsProcessTrusted() { return true }
            try? await Task.sleep(nanoseconds: pollIntervalNanos)
        }
        return AXIsProcessTrusted()
    }

    func currentWindowsAsync() async -> [(AXWindowRef, pid_t, Int)] {
        let interval = signpostInterval("currentWindowsAsync")
        defer { interval.end() }

        await AppAXContext.garbageCollect()

        var results: [(AXWindowRef, pid_t, Int)] = []
        let apps = NSWorkspace.shared.runningApplications.filter { shouldTrack($0) }

        for app in apps {
            do {
                guard let context = try await AppAXContext.getOrCreate(app) else { continue }

                let appWindows = try await withTimeoutOrNil(seconds: perAppTimeout) {
                    try await context.getWindowsAsync()
                }

                if let windows = appWindows {
                    results.append(contentsOf: windows.map { ($0.0, app.processIdentifier, $0.1) })
                }
            } catch {
                continue
            }
        }

        return results
    }

    func applyFramesParallel(_ frames: [(pid: pid_t, windowId: Int, frame: CGRect)]) {
        let interval = signpostInterval("applyFramesParallel", "frames: \(frames.count)")
        defer { interval.end() }

        var framesByPid: [pid_t: [(windowId: Int, frame: CGRect)]] = [:]

        for (pid, windowId, frame) in frames {
            framesByPid[pid, default: []].append((windowId, frame))
        }

        for (pid, appFrames) in framesByPid {
            guard let context = AppAXContext.contexts[pid] else { continue }
            context.setFramesBatch(appFrames)
        }
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
        !app.isTerminated && app.activationPolicy != .prohibited
    }
}

enum AXEvent {
    case created(AXWindowRef, pid_t, Int)
    case removed(AXWindowRef, pid_t, Int)
    case changed(AXWindowRef, pid_t, Int)
    case focused(AXWindowRef, pid_t, Int)
}
