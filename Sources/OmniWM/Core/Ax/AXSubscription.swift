import AppKit
import ApplicationServices

final class AXSubscription {
    let observer: AXObserver
    let axElement: AXUIElement
    private let threadToken: AppThreadToken
    private var notificationKeys: Set<String> = []

    private init(observer: AXObserver, axElement: AXUIElement) {
        guard let token = appThreadToken else {
            fatalError("appThreadToken is not initialized - must be called from within app thread context")
        }
        threadToken = token
        self.observer = observer
        self.axElement = axElement
    }

    private func subscribe(_ key: String, _: RunLoopJob) throws -> Bool {
        threadToken.checkEquals(appThreadToken)
        if AXObserverAddNotification(observer, axElement, key as CFString, nil) == .success {
            notificationKeys.insert(key)
            return true
        } else {
            return false
        }
    }

    static func bulkSubscribe(
        _ nsApp: NSRunningApplication,
        _ axElement: AXUIElement,
        _ job: RunLoopJob,
        _ notifications: [String],
        _ callback: AXObserverCallback
    ) throws -> AXSubscription? {
        try job.checkCancellation()

        var observer: AXObserver?
        let status = AXObserverCreate(nsApp.processIdentifier, callback, &observer)
        guard status == .success, let obs = observer else { return nil }

        let subscription = AXSubscription(observer: obs, axElement: axElement)
        for key in notifications {
            try job.checkCancellation()
            if try !subscription.subscribe(key, job) { return nil }
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
        return subscription
    }

    deinit {
        threadToken.checkEquals(appThreadToken)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        for notifKey in notificationKeys {
            AXObserverRemoveNotification(observer, axElement, notifKey as CFString)
        }
    }
}
