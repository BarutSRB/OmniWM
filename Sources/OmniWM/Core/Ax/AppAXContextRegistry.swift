// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

@MainActor
enum AppAXContextRegistry {
    private(set) static var contexts: [pid_t: AppAXContext] = [:]
    private static var macOSHiddenPIDs: Set<pid_t> = []
    private static var inFlightCreations: [pid_t: (
        generation: UInt64,
        task: Task<AppAXContext?, Error>
    )] = [:]

    static func aggregateRuntimeMailboxDepths() -> AppAXMailboxDepths {
        contexts.values.reduce(into: AppAXMailboxDepths()) { depths, context in
            depths.add(context.frameDelivery.runtimeMailboxDepths)
        }
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

            let context = try await AppAXContext.createContext(nsApp, generation: generation)
            guard appAXCallbackGenerationRegistry.isCurrent(generation) else {
                context?.destroy()
                return nil
            }
            if let context {
                context.setMacOSAppHidden(macOSHiddenPIDs.contains(pid), for: [])
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
        macOSHiddenPIDs.removeAll()
    }

    @MainActor
    static func setMacOSAppHidden(_ hidden: Bool, pid: pid_t, windowIds: [Int]) {
        if hidden {
            macOSHiddenPIDs.insert(pid)
        } else {
            macOSHiddenPIDs.remove(pid)
        }
        contexts[pid]?.setMacOSAppHidden(hidden, for: windowIds)
    }

    @MainActor
    static func isMacOSAppHidden(pid: pid_t) -> Bool {
        macOSHiddenPIDs.contains(pid)
    }

    static func remove(_ context: AppAXContext) {
        if contexts[context.pid] === context { contexts.removeValue(forKey: context.pid) }
    }
}
