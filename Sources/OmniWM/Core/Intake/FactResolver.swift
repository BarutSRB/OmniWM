import ApplicationServices
import Foundation

struct FocusedWindowFact: Sendable {
    let axRef: AXWindowRef
    let isFullscreen: Bool
}

struct ActivationFacts: Sendable {
    let pid: pid_t
    let source: ActivationEventSource
    let origin: ActivationCallOrigin
    let requestedAtSeq: UInt64
    let focusedWindow: FocusedWindowFact?
}

@MainActor
final class FactResolver {
    var factProvider: ((pid_t) -> FocusedWindowFact?)?

    private var resolverThread: Thread?
    private var inFlightActivationPids: Set<pid_t> = []

    func resolveActivationFacts(
        pid: pid_t,
        source: ActivationEventSource,
        origin: ActivationCallOrigin
    ) {
        if !source.isAuthoritative, inFlightActivationPids.contains(pid) {
            return
        }
        let requestedAtSeq = EventIntake.currentSeq()
        if let factProvider {
            EventIntake.post(
                .activationFactsResolved(
                    ActivationFacts(
                        pid: pid,
                        source: source,
                        origin: origin,
                        requestedAtSeq: requestedAtSeq,
                        focusedWindow: factProvider(pid)
                    )
                )
            )
            return
        }
        inFlightActivationPids.insert(pid)
        let thread = AppAXContext.contexts[pid]?.axThread ?? sharedResolverThread()
        Task { @MainActor in
            let focusedWindow = (try? await thread.runInLoop { _ in
                Self.readFocusedWindowFact(pid: pid)
            }) ?? nil
            inFlightActivationPids.remove(pid)
            EventIntake.post(
                .activationFactsResolved(
                    ActivationFacts(
                        pid: pid,
                        source: source,
                        origin: origin,
                        requestedAtSeq: requestedAtSeq,
                        focusedWindow: focusedWindow
                    )
                )
            )
        }
    }

    func stop() {
        guard let thread = resolverThread else { return }
        resolverThread = nil
        thread.runInLoopAsync { _ in
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    private func sharedResolverThread() -> Thread {
        if let resolverThread {
            return resolverThread
        }
        let thread = Thread {
            let port = NSMachPort()
            RunLoop.current.add(port, forMode: .default)
            CFRunLoopRun()
        }
        thread.name = "OmniWM-FactResolver"
        thread.start()
        resolverThread = thread
        return thread
    }

    private nonisolated static func readFocusedWindowFact(pid: pid_t) -> FocusedWindowFact? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )
        guard result == .success, let focusedWindow else { return nil }
        guard CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() else { return nil }
        let axElement = unsafeDowncast(focusedWindow, to: AXUIElement.self)
        guard let axRef = try? AXWindowRef(element: axElement) else { return nil }
        return FocusedWindowFact(
            axRef: axRef,
            isFullscreen: AXWindowService.isFullscreen(axRef)
        )
    }
}
