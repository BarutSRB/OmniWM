// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

private final class LockedRunLoopJobSet: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [ObjectIdentifier: RunLoopJob] = [:]

    func insert(_ job: RunLoopJob) {
        lock.lock()
        jobs[ObjectIdentifier(job)] = job
        lock.unlock()
    }

    func remove(_ job: RunLoopJob) {
        lock.lock()
        jobs[ObjectIdentifier(job)] = nil
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let cancelled = Array(jobs.values)
        jobs.removeAll()
        lock.unlock()
        for job in cancelled {
            job.cancel()
        }
    }
}

@MainActor
final class MenuBarItemService {
    private var scanThread: Thread?
    private var itemThread: Thread?
    private var activationThread: Thread?
    private var stopped = false
    private var epoch = 0
    private let inFlightJobs = LockedRunLoopJobSet()

    func start() {
        stopped = false
        epoch += 1
    }

    func scan(candidates: [MenuBarAppCandidate], ownBundleID: String?) async -> [DetectedMenuBarApp] {
        guard !stopped else { return [] }
        let epoch = self.epoch
        nonisolated(unsafe) let worker = scannerThread()
        let jobs = inFlightJobs
        let apps = (try? await worker.runInLoop(timeout: .seconds(15)) { job -> [DetectedMenuBarApp] in
            jobs.insert(job)
            defer { jobs.remove(job) }
            return try MenuBarExtrasScanner.scan(candidates: candidates, ownBundleID: ownBundleID, job: job)
        }) ?? []
        guard isCurrent(epoch) else { return [] }
        return apps
    }

    func resolveItems(
        candidates: [MenuBarAppCandidate],
        bundleIDs: Set<String>,
        allowEmptyBundleIDs: Set<String>
    ) async -> MenuBarItemResolution {
        guard !stopped else { return .empty }
        let epoch = self.epoch
        nonisolated(unsafe) let worker = menuItemThread()
        let jobs = inFlightJobs
        let resolution = (try? await worker.runInLoop(timeout: .seconds(5)) { job -> MenuBarItemResolution in
            jobs.insert(job)
            defer { jobs.remove(job) }
            return try MenuBarItemLocator.resolveItems(
                candidates: candidates,
                bundleIDs: bundleIDs,
                allowEmptyBundleIDs: allowEmptyBundleIDs,
                job: job
            )
        }) ?? .empty
        guard isCurrent(epoch) else { return .empty }
        return resolution
    }

    func activate(
        candidates: [MenuBarItemActivationCandidate],
        target: ResolvedMenuBarItem
    ) async -> MenuBarItemActivation {
        guard !stopped else { return .unavailable }
        let epoch = self.epoch
        nonisolated(unsafe) let worker = menuActivationThread()
        let jobs = inFlightJobs
        let activation = (try? await worker.runInLoop(timeout: .milliseconds(2200)) { job -> MenuBarItemActivation in
            jobs.insert(job)
            defer { jobs.remove(job) }
            return try MenuBarItemLocator.activate(candidates: candidates, target: target, job: job)
        }) ?? .unavailable
        guard isCurrent(epoch) else { return .unavailable }
        return activation
    }

    func isMenuOpen(ownerPIDs: Set<pid_t>) async -> Bool? {
        guard !stopped else { return nil }
        let epoch = self.epoch
        let menuOpen = await Task.detached(priority: .userInitiated) {
            HiddenBarMenuGuard.isAnyMenuOpen(menuOwnerPIDs: ownerPIDs)
        }.value
        guard !Task.isCancelled, isCurrent(epoch) else { return nil }
        return menuOpen
    }

    func stop() {
        stopped = true
        inFlightJobs.cancelAll()
        let threads = [scanThread, itemThread, activationThread].compactMap { $0 }
        scanThread = nil
        itemThread = nil
        activationThread = nil
        for thread in threads {
            thread.runInLoopAsync { _ in
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
        }
    }

    private func isCurrent(_ epoch: Int) -> Bool {
        !stopped && self.epoch == epoch
    }

    private func scannerThread() -> Thread {
        if let scanThread {
            return scanThread
        }
        let thread = makeThread(name: "OmniWM-MenuBarScan")
        scanThread = thread
        return thread
    }

    private func menuItemThread() -> Thread {
        if let itemThread {
            return itemThread
        }
        let thread = makeThread(name: "OmniWM-MenuBarItems")
        itemThread = thread
        return thread
    }

    private func menuActivationThread() -> Thread {
        if let activationThread {
            return activationThread
        }
        let thread = makeThread(name: "OmniWM-MenuBarActivation")
        activationThread = thread
        return thread
    }

    private func makeThread(name: String) -> Thread {
        let thread = Thread {
            let port = NSMachPort()
            RunLoop.current.add(port, forMode: .default)
            CFRunLoopRun()
        }
        thread.name = name
        thread.start()
        return thread
    }
}
