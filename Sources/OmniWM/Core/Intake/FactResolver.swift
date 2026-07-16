// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation

struct FocusedWindowFact: Sendable {
    let axRef: AXWindowRef
    let isFullscreen: Bool
    let isSystemModalSurface: Bool
}

struct ActivationFacts: Sendable {
    let pid: pid_t
    let source: ActivationEventSource
    let origin: ActivationCallOrigin
    let observationGeneration: UInt64
    let requestedAtSeq: UInt64
    let focusedWindow: FocusedWindowFact?
}

struct WindowConstraintsFact: Sendable {
    let token: WindowToken
    let constraints: WindowSizeConstraints
}

@MainActor
final class FactResolver {
    private struct ActivationFactRequest {
        let pid: pid_t
        let source: ActivationEventSource
        let origin: ActivationCallOrigin
        let observationGeneration: UInt64
        let requestedAtSeq: UInt64
    }

    var factProvider: ((pid_t) -> FocusedWindowFact?)?

    private var resolverThread: Thread?
    private var inFlightActivationPids: Set<pid_t> = []
    private var pendingActivationRequestsByPid: [pid_t: ActivationFactRequest] = [:]
    private var inFlightConstraintTokens: Set<WindowToken> = []

    func resolveActivationFacts(
        pid: pid_t,
        source: ActivationEventSource,
        origin: ActivationCallOrigin,
        observationGeneration: UInt64
    ) {
        let request = ActivationFactRequest(
            pid: pid,
            source: source,
            origin: origin,
            observationGeneration: observationGeneration,
            requestedAtSeq: EventIntake.currentSeq()
        )
        resolveActivationFacts(request)
    }

    private func resolveActivationFacts(_ request: ActivationFactRequest) {
        if let factProvider {
            EventIntake.post(
                .activationFactsResolved(
                    ActivationFacts(
                        pid: request.pid,
                        source: request.source,
                        origin: request.origin,
                        observationGeneration: request.observationGeneration,
                        requestedAtSeq: request.requestedAtSeq,
                        focusedWindow: factProvider(request.pid)
                    )
                )
            )
            return
        }
        if inFlightActivationPids.contains(request.pid) {
            pendingActivationRequestsByPid[request.pid] = request
            return
        }
        inFlightActivationPids.insert(request.pid)
        nonisolated(unsafe) let thread = AppAXContext.contexts[request.pid]?.axThread ?? sharedResolverThread()
        Task { @MainActor in
            let focusedWindow = (try? await thread.runInLoop { _ in
                Self.readFocusedWindowFact(pid: request.pid)
            }) ?? nil
            inFlightActivationPids.remove(request.pid)
            EventIntake.post(
                .activationFactsResolved(
                    ActivationFacts(
                        pid: request.pid,
                        source: request.source,
                        origin: request.origin,
                        observationGeneration: request.observationGeneration,
                        requestedAtSeq: request.requestedAtSeq,
                        focusedWindow: focusedWindow
                    )
                )
            )
            if let pendingRequest = pendingActivationRequestsByPid.removeValue(forKey: request.pid) {
                resolveActivationFacts(pendingRequest)
            }
        }
    }

    func resolveWindowConstraints(token: WindowToken, axRef: AXWindowRef) {
        guard inFlightConstraintTokens.insert(token).inserted else { return }
        nonisolated(unsafe) let thread = AppAXContext.contexts[token.pid]?.axThread ?? sharedResolverThread()
        Task { @MainActor in
            let constraints = try? await thread.runInLoop { _ in
                AXWindowService.sizeConstraints(axRef)
            }
            inFlightConstraintTokens.remove(token)
            guard let constraints else { return }
            EventIntake.post(
                .windowConstraintsResolved(WindowConstraintsFact(token: token, constraints: constraints))
            )
        }
    }

    func stop() {
        pendingActivationRequestsByPid.removeAll()
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
        if let elementPid = AXWindowService.processIdentifier(axRef), elementPid != pid {
            DiagnosticsEventRecorder.shared.recordLifecycle(
                name: "focusedAX.pidMismatch.expected=\(pid)",
                pid: elementPid,
                windowId: UInt32(exactly: axRef.windowId)
            )
        }
        let attributes = AXWindowService.roleAndSubrole(axRef)
        return FocusedWindowFact(
            axRef: axRef,
            isFullscreen: AXWindowService.isFullscreen(axRef, subrole: attributes.subrole),
            isSystemModalSurface: AXWindowService.isSystemModalSurface(
                role: attributes.role,
                subrole: attributes.subrole
            )
        )
    }
}
