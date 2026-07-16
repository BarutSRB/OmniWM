// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private let perAppTimeout: TimeInterval = 0.5

private struct FullRescanAppEnumerationResult: Sendable {
    let pid: pid_t
    let route: FullRescanEnumerationRoute
    let windows: [AXEnumeratedWindow]
    let failed: Bool
}

private struct FullRescanAppTarget: @unchecked Sendable {
    let app: NSRunningApplication
    let route: FullRescanEnumerationRoute
}

private struct FullRescanDiscoveryEvidence {
    var pidsWithWindows: Set<pid_t>
    var windowServerInfoByWindowId: [Int: WindowServerInfo]
    var ownerPIDByWindowId: [Int: pid_t]
}

private struct FullRescanCandidateCollection {
    var candidatesByWindowId: [Int: [FullRescanWindowCandidate]]
    var identityAliasesByWindowId: [Int: FullRescanWindowIdentityAliases]
    var failedPIDs: Set<pid_t>
}

enum FullRescanCandidatePreferenceReason: String, Equatable, Sendable {
    case manageability = "manageability"
    case preservedLogicalPID = "preserved_logical_pid"
    case regularActivationPolicy = "regular_activation_policy"
    case axHostPID = "ax_host_pid"
    case windowServerOwnerPID = "window_server_owner_pid"
    case lowerPID = "lower_pid"
    case stableFirstCandidate = "stable_first_candidate"
}

struct FullRescanCandidatePreference: Equatable, Sendable {
    let prefersCandidate: Bool
    let reason: FullRescanCandidatePreferenceReason
}

struct FullRescanWindowIdentityAliases {
    var pids: Set<pid_t> = []
    var axRefs: [AXWindowRef] = []
}

@MainActor
final class AXManager {
    typealias FrameApplicationTerminalObserver = AXFrameApplicationTerminalObserver

    struct FullRescanEnumerationSnapshot {
        let windows: [FullRescanWindowCandidate]
        let failedPIDs: Set<pid_t>
        let identityAliasesByWindowId: [Int: FullRescanWindowIdentityAliases]

        static let empty = FullRescanEnumerationSnapshot(
            windows: [],
            failedPIDs: [],
            identityAliasesByWindowId: [:]
        )
    }

    private static let systemUIBundleIds: Set<String> = [
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.Spotlight"
    ]

    private var appTerminationObserver: NSObjectProtocol?
    private var appLaunchObserver: NSObjectProtocol?
    var onAppLaunched: ((NSRunningApplication) -> Void)?
    var onAppTerminated: ((pid_t) -> Void)?
    var isWindowParked: ((Int) -> Bool)?
    var onTerminalFrameRefusal: ((AXFrameTerminalRefusal) -> Void)?

    private let frameLedger = AXFrameApplicationLedger()
    private var framesByPidBuffer: [pid_t: [AXFrameApplicationRequest]] = [:]
    private var frameApplicationBufferInUse = false
    private var pendingFrameRetryTasksByWindowId: [Int: Task<Void, Never>] = [:]
    private var pendingFrameRetryGenerationByWindowId: [Int: UInt64] = [:]
    private var nextFrameRetryGeneration: UInt64 = 1

    /// Window IDs belonging to inactive workspaces — checked LIVE in applyFramesParallel.
    private(set) var inactiveWorkspaceWindowIds: Set<Int> = []

    private var skyLightLivePositionByWindowId: [Int: CGPoint] = [:]

    private(set) var pendingParkWindowIds: Set<Int> = []
    private var frameOrderSeq: UInt64 = 0
    private var lastParkCommandSeqByWindowId: [Int: UInt64] = [:]
    private var lastFrameResultSeqByWindowId: [Int: UInt64] = [:]

    init() {
        installWorkspaceObservers()
    }

    func installWorkspaceObservers() {
        if appTerminationObserver == nil {
            setupTerminationObserver()
        }
        if appLaunchObserver == nil {
            setupLaunchObserver()
        }
    }

    private func setupTerminationObserver() {
        appTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let pid = app.processIdentifier
            Task { @MainActor in
                self?.onAppTerminated?(pid)
                if let context = AppAXContext.contexts[pid] {
                    context.destroy()
                }
            }
        }
    }

    private func setupLaunchObserver() {
        appLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            Task { @MainActor in
                self?.onAppLaunched?(app)
            }
        }
    }

    func updateInactiveWorkspaceWindows(
        allEntries: [(workspaceId: WorkspaceDescriptor.ID, windowId: Int)],
        activeWorkspaceIds: Set<WorkspaceDescriptor.ID>,
        nativeInactiveWindowIds: Set<Int> = []
    ) {
        inactiveWorkspaceWindowIds.removeAll(keepingCapacity: true)
        for (wsId, windowId) in allEntries {
            if !activeWorkspaceIds.contains(wsId) {
                inactiveWorkspaceWindowIds.insert(windowId)
            }
        }
        inactiveWorkspaceWindowIds.formUnion(nativeInactiveWindowIds)
    }

    func markWindowActive(_ windowId: Int) {
        inactiveWorkspaceWindowIds.remove(windowId)
    }

    func markWindowInactive(_ windowId: Int) {
        inactiveWorkspaceWindowIds.insert(windowId)
    }

    func forceApplyNextFrame(for windowId: Int) {
        frameLedger.forceApplyNextFrame(for: windowId)
    }

    func lastAppliedFrame(for windowId: Int) -> CGRect? {
        frameLedger.lastAppliedFrame(for: windowId)
    }

    func recordSkyLightMove(windowId: Int, origin: CGPoint) {
        skyLightLivePositionByWindowId[windowId] = origin
    }

    func skyLightLivePosition(for windowId: Int) -> CGPoint? {
        skyLightLivePositionByWindowId[windowId]
    }

    func clearSkyLightLivePositions() {
        skyLightLivePositionByWindowId.removeAll(keepingCapacity: true)
    }

    func markParkPending(for windowId: Int, pid: pid_t) {
        guard pendingParkWindowIds.insert(windowId).inserted else { return }
        FrameApplyTrace.recordEvent(pid: pid, windowId: windowId, outcome: "outcome=park-pending")
    }

    func recordParkCommand(for windowId: Int) {
        frameOrderSeq &+= 1
        lastParkCommandSeqByWindowId[windowId] = frameOrderSeq
    }

    func parkQuietSinceCommand(for windowId: Int) -> Bool {
        (lastFrameResultSeqByWindowId[windowId] ?? 0) <= (lastParkCommandSeqByWindowId[windowId] ?? 0)
    }

    func clearParkPending(for windowId: Int, pid: pid_t, reason: String) {
        guard pendingParkWindowIds.remove(windowId) != nil else { return }
        FrameApplyTrace.recordEvent(pid: pid, windowId: windowId, outcome: "outcome=park-cleared/\(reason)")
    }

    private func clearSkyLightLivePosition(for windowId: Int) {
        skyLightLivePositionByWindowId.removeValue(forKey: windowId)
    }

    func recentFrameWriteFailure(for windowId: Int) -> AXFrameWriteFailureReason? {
        frameLedger.recentFrameWriteFailure(for: windowId)
    }

    func hasContext(for pid: pid_t) -> Bool {
        AppAXContext.contexts[pid] != nil
    }

    func hasPendingFrameWrite(for windowId: Int) -> Bool {
        frameLedger.hasPendingFrameWrite(for: windowId)
    }

    func pendingFrameWrite(for windowId: Int) -> CGRect? {
        frameLedger.pendingFrameWrite(for: windowId)
    }

    func frameStateDump() -> String {
        var sections = ["Ledger:\n\(frameLedger.stateDump())"]
        let inactive = inactiveWorkspaceWindowIds.sorted()
        let inactiveText = inactive.isEmpty ? "none" : inactive.map(String.init).joined(separator: ",")
        sections.append("inactiveWorkspaceWindows=\(inactiveText)")
        let retryTasks = pendingFrameRetryTasksByWindowId.keys.sorted()
        if !retryTasks.isEmpty {
            sections.append("pendingRetryTasks=" + retryTasks.map(String.init).joined(separator: ","))
        }
        if !pendingFrameRetryGenerationByWindowId.isEmpty {
            let generations = pendingFrameRetryGenerationByWindowId.sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
            sections.append("retryGenerations=" + generations)
        }
        return sections.joined(separator: "\n")
    }

    func shouldSuppressFrameChangeRelayout(for windowId: Int, observedFrame: CGRect?) -> Bool {
        frameLedger.shouldSuppressFrameChangeRelayout(for: windowId, observedFrame: observedFrame)
    }

    func clearInactiveWorkspaceWindows() {
        inactiveWorkspaceWindowIds.removeAll()
    }

    func rebindWindowState(
        from oldWindow: AXManagedWindowIdentity,
        to newWindow: AXManagedWindowIdentity
    ) -> Bool {
        if oldWindow.token == newWindow.token,
           CFEqual(oldWindow.axRef.element, newWindow.axRef.element)
        {
            return true
        }

        let oldWindowId = oldWindow.token.windowId
        let newWindowId = newWindow.token.windowId
        let isIncarnationReplacement = oldWindow.token.pid != newWindow.token.pid
            || oldWindowId == newWindowId
        guard scheduleAXContextRebind(from: oldWindow, to: newWindow) else { return false }
        let deliveries = resetFrameApplicationStateForRebind(
            oldWindowId: oldWindowId,
            newWindowId: newWindowId,
            isIncarnationReplacement: isIncarnationReplacement
        )
        for delivery in deliveries {
            delivery.deliver()
        }
        FrameApplyTrace.recordEvent(
            pid: newWindow.token.pid,
            windowId: oldWindowId,
            outcome: "outcome=rebind→\(newWindowId)"
        )
        return true
    }

    private func scheduleAXContextRebind(
        from oldWindow: AXManagedWindowIdentity,
        to newWindow: AXManagedWindowIdentity
    ) -> Bool {
        let oldContext = AppAXContext.contexts[oldWindow.token.pid]
        guard let destinationContext = AppAXContext.contexts[newWindow.token.pid] else {
            return oldWindow.token.pid == newWindow.token.pid && oldContext == nil
        }
        let didSchedule = if oldContext === destinationContext {
            destinationContext.rekeyWindow(
                oldWindowId: oldWindow.token.windowId,
                newWindow: newWindow.axRef
            )
        } else {
            destinationContext.bindWindow(newWindow.axRef)
        }
        guard didSchedule else { return false }
        if oldContext !== destinationContext {
            oldContext?.removeWindowState(windowId: oldWindow.token.windowId)
        }
        destinationContext.cancelFrameJob(for: newWindow.token.windowId)
        return true
    }

    private func resetFrameApplicationStateForRebind(
        oldWindowId: Int,
        newWindowId: Int,
        isIncarnationReplacement: Bool
    ) -> [AXFrameTerminalDelivery] {
        var deliveries = isIncarnationReplacement
            ? frameLedger.removeWindowState(windowId: oldWindowId)
            : frameLedger.cancelFrameJob(windowId: oldWindowId)
        cancelPendingFrameRetry(for: oldWindowId)
        if oldWindowId != newWindowId {
            cancelPendingFrameRetry(for: newWindowId)
            if isIncarnationReplacement {
                deliveries.append(contentsOf: frameLedger.removeWindowState(windowId: newWindowId))
            } else {
                frameLedger.rekeyWindowState(oldWindowId: oldWindowId, newWindowId: newWindowId)
            }
            rekeyAuxiliaryWindowState(from: oldWindowId, to: newWindowId)
        }
        if isIncarnationReplacement {
            resetIncarnationAuxiliaryState(oldWindowId: oldWindowId, newWindowId: newWindowId)
        }
        frameLedger.forceApplyNextFrame(for: newWindowId)
        clearSkyLightLivePosition(for: oldWindowId)
        clearSkyLightLivePosition(for: newWindowId)
        return deliveries
    }

    private func rekeyAuxiliaryWindowState(from oldWindowId: Int, to newWindowId: Int) {
        if inactiveWorkspaceWindowIds.remove(oldWindowId) != nil {
            inactiveWorkspaceWindowIds.insert(newWindowId)
        }
        if pendingParkWindowIds.remove(oldWindowId) != nil {
            pendingParkWindowIds.insert(newWindowId)
        }
        if let seq = lastParkCommandSeqByWindowId.removeValue(forKey: oldWindowId) {
            lastParkCommandSeqByWindowId[newWindowId] = seq
        }
        if let seq = lastFrameResultSeqByWindowId.removeValue(forKey: oldWindowId) {
            lastFrameResultSeqByWindowId[newWindowId] = seq
        }
    }

    private func resetIncarnationAuxiliaryState(oldWindowId: Int, newWindowId: Int) {
        pendingParkWindowIds.remove(oldWindowId)
        pendingParkWindowIds.remove(newWindowId)
        lastParkCommandSeqByWindowId.removeValue(forKey: oldWindowId)
        lastParkCommandSeqByWindowId.removeValue(forKey: newWindowId)
        lastFrameResultSeqByWindowId.removeValue(forKey: oldWindowId)
        lastFrameResultSeqByWindowId.removeValue(forKey: newWindowId)
    }

    func confirmFrameWrite(for windowId: Int, frame: CGRect) {
        frameLedger.confirmFrameWrite(for: windowId, frame: frame)
        clearSkyLightLivePosition(for: windowId)
    }

    func removeWindowState(pid: pid_t, windowId: Int) {
        AppAXContext.contexts[pid]?.removeWindowState(windowId: windowId)

        let deliveries = frameLedger.removeWindowState(windowId: windowId)
        cancelPendingFrameRetry(for: windowId)
        inactiveWorkspaceWindowIds.remove(windowId)
        clearSkyLightLivePosition(for: windowId)
        clearParkPending(for: windowId, pid: pid, reason: "removed")
        lastParkCommandSeqByWindowId.removeValue(forKey: windowId)
        lastFrameResultSeqByWindowId.removeValue(forKey: windowId)

        for delivery in deliveries {
            delivery.deliver()
        }
    }

    func cleanup() {
        if let observer = appTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appTerminationObserver = nil
        }
        if let observer = appLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appLaunchObserver = nil
        }

        cancelAllPendingFrameState()

        AppAXContext.shutdownAll()
    }

    func windowsForApp(_ app: NSRunningApplication) async -> [(AXWindowRef, pid_t, Int)] {
        guard shouldTrack(app) else { return [] }
        do {
            guard let context = try await AppAXContext.getOrCreate(app) else {
                return []
            }
            let windows = try await context.getWindowsAsync(timeoutSeconds: perAppTimeout)
            return windows.map { ($0.axRef, app.processIdentifier, $0.axRef.windowId) }
        } catch {
        }
        return []
    }

    func requestPermission() -> Bool {
        if AccessibilityPermissionMonitor.shared.isGranted { return true }

        let options: NSDictionary = [axTrustedCheckOptionPrompt as NSString: true]
        _ = AXIsProcessTrustedWithOptions(options)

        return AccessibilityPermissionMonitor.shared.isGranted
    }

    func currentWindowsAsync() async -> [(AXWindowRef, pid_t, Int)] {
        guard let snapshot = try? await fullRescanEnumerationSnapshot() else { return [] }
        return snapshot.windows.map { ($0.axRef, $0.pid, $0.windowId) }
    }

    func fullRescanEnumerationSnapshot(
        preservingPIDsByWindowId: [Int: pid_t] = [:]
    ) async throws -> FullRescanEnumerationSnapshot {
        try Task.checkCancellation()
        AppAXContext.garbageCollect()
        let discoveryEvidence = fullRescanDiscoveryEvidence()
        let appTargets = fullRescanAppTargets(
            discoveryEvidence: discoveryEvidence,
            preservingPIDsByWindowId: preservingPIDsByWindowId
        )
        let activationPolicyByPID = Dictionary(
            uniqueKeysWithValues: appTargets.map { ($0.app.processIdentifier, $0.app.activationPolicy) }
        )
        let appsByPID = Dictionary(
            uniqueKeysWithValues: appTargets.map { ($0.app.processIdentifier, $0.app) }
        )
        let enumerationResults = try await enumerateFullRescanApps(appTargets)
        try Task.checkCancellation()
        let collection = collectFullRescanCandidates(
            enumerationResults,
            discoveryEvidence: discoveryEvidence
        )
        return try await finalizeFullRescanSnapshot(
            collection: collection,
            activationPolicyByPID: activationPolicyByPID,
            appsByPID: appsByPID,
            preservingPIDsByWindowId: preservingPIDsByWindowId
        )
    }

    private func finalizeFullRescanSnapshot(
        collection initialCollection: FullRescanCandidateCollection,
        activationPolicyByPID: [pid_t: NSApplication.ActivationPolicy],
        appsByPID: [pid_t: NSRunningApplication],
        preservingPIDsByWindowId: [Int: pid_t]
    ) async throws -> FullRescanEnumerationSnapshot {
        try Task.checkCancellation()
        var collection = initialCollection
        var selected = Self.selectFullRescanCandidates(
            collection.candidatesByWindowId,
            activationPolicyByPID: activationPolicyByPID,
            preservingPIDsByWindowId: preservingPIDsByWindowId
        )
        let failedPromotions = try await promoteOneShotCandidates(selected, appsByPID: appsByPID)
        try Task.checkCancellation()
        if !failedPromotions.isEmpty {
            collection.failedPIDs.formUnion(failedPromotions)
            for candidate in selected
                where candidate.enumerationRoute == .oneShot && failedPromotions.contains(candidate.pid)
            {
                if let preservedPID = preservingPIDsByWindowId[candidate.windowId] {
                    collection.failedPIDs.insert(preservedPID)
                }
            }
            selected.removeAll {
                $0.enumerationRoute == .oneShot && failedPromotions.contains($0.pid)
            }
        }

        let selectedWindowIds = Set(selected.map(\.windowId))
        collection.identityAliasesByWindowId = collection.identityAliasesByWindowId.filter {
            selectedWindowIds.contains($0.key)
        }
        return .init(
            windows: selected,
            failedPIDs: collection.failedPIDs,
            identityAliasesByWindowId: collection.identityAliasesByWindowId
        )
    }

    private func fullRescanAppTargets(
        discoveryEvidence: FullRescanDiscoveryEvidence,
        preservingPIDsByWindowId: [Int: pid_t]
    ) -> [FullRescanAppTarget] {
        let existingContextPIDs = Set(AppAXContext.contexts.keys)
        let preservingPIDs = Set(preservingPIDsByWindowId.values)
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard shouldTrack(app),
                  let route = Self.fullRescanEnumerationRoute(
                      activationPolicy: app.activationPolicy,
                      hasDiscoveryEvidence: discoveryEvidence.pidsWithWindows.contains(app.processIdentifier),
                      hasContext: existingContextPIDs.contains(app.processIdentifier),
                      hasPreservedState: preservingPIDs.contains(app.processIdentifier)
                  )
            else {
                return nil
            }
            return FullRescanAppTarget(app: app, route: route)
        }
    }

    private func fullRescanDiscoveryEvidence() -> FullRescanDiscoveryEvidence {
        let visibleWindows = SkyLight.shared.queryAllVisibleWindows()
        var evidence = FullRescanDiscoveryEvidence(
            pidsWithWindows: Set(visibleWindows.map { $0.pid }),
            windowServerInfoByWindowId: [:],
            ownerPIDByWindowId: [:]
        )
        for window in visibleWindows {
            evidence.windowServerInfoByWindowId[Int(window.id)] = window
            evidence.ownerPIDByWindowId[Int(window.id)] = pid_t(window.pid)
        }
        let skyLightPIDCount = evidence.pidsWithWindows.count
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            FallbackFiringRecorder.shared.note(.capture, "cgWindowListNull")
            return evidence
        }
        for window in windows {
            guard let pidNumber = window[kCGWindowOwnerPID as String] as? Int,
                  let windowNumber = window[kCGWindowNumber as String] as? Int,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let alpha = window[kCGWindowAlpha as String] as? Double,
                  alpha > 0
            else { continue }
            let pid = pid_t(pidNumber)
            evidence.pidsWithWindows.insert(pid)
            evidence.ownerPIDByWindowId[windowNumber] = evidence.ownerPIDByWindowId[windowNumber] ?? pid
        }
        FallbackFiringRecorder.shared.note(
            .capture,
            "cgWindowListSupplementPids",
            evidence.pidsWithWindows.count - skyLightPIDCount
        )
        return evidence
    }

    private func collectFullRescanCandidates(
        _ results: [FullRescanAppEnumerationResult],
        discoveryEvidence: FullRescanDiscoveryEvidence
    ) -> FullRescanCandidateCollection {
        var collection = FullRescanCandidateCollection(
            candidatesByWindowId: [:],
            identityAliasesByWindowId: [:],
            failedPIDs: []
        )
        for result in results {
            if result.failed {
                collection.failedPIDs.insert(result.pid)
            }
            for window in result.windows {
                let windowId = window.axRef.windowId
                let ownerPID = discoveryEvidence.ownerPIDByWindowId[windowId]
                appendFullRescanAliases(
                    for: window,
                    logicalPID: result.pid,
                    ownerPID: ownerPID,
                    to: &collection.identityAliasesByWindowId
                )
                let candidate = FullRescanWindowCandidate(
                    enumeratedWindow: window,
                    logicalPID: result.pid,
                    windowServerInfo: discoveryEvidence.windowServerInfoByWindowId[windowId],
                    windowServerOwnerPID: ownerPID,
                    enumerationRoute: result.route
                )
                collection.candidatesByWindowId[windowId, default: []].append(candidate)
            }
        }
        return collection
    }

    private func appendFullRescanAliases(
        for window: AXEnumeratedWindow,
        logicalPID: pid_t,
        ownerPID: pid_t?,
        to aliasesByWindowId: inout [Int: FullRescanWindowIdentityAliases]
    ) {
        let windowId = window.axRef.windowId
        var aliases = aliasesByWindowId[windowId] ?? .init()
        aliases.pids.insert(logicalPID)
        if let axPid = window.axPid {
            aliases.pids.insert(axPid)
        }
        if let ownerPID {
            aliases.pids.insert(ownerPID)
        }
        if !aliases.axRefs.contains(where: { CFEqual($0.element, window.axRef.element) }) {
            aliases.axRefs.append(window.axRef)
        }
        aliasesByWindowId[windowId] = aliases
    }

    private func enumerateFullRescanApps(
        _ targets: [FullRescanAppTarget]
    ) async throws -> [FullRescanAppEnumerationResult] {
        try await withThrowingTaskGroup(of: FullRescanAppEnumerationResult.self) { group in
            for target in targets {
                group.addTask(priority: target.route == .oneShot ? .utility : nil) {
                    try await Self.enumerateFullRescanApp(target.app, route: target.route)
                }
            }
            var results: [FullRescanAppEnumerationResult] = []
            results.reserveCapacity(targets.count)
            for try await result in group {
                results.append(result)
            }
            return results
        }
    }

    private nonisolated static func enumerateFullRescanApp(
        _ app: NSRunningApplication,
        route: FullRescanEnumerationRoute
    ) async throws -> FullRescanAppEnumerationResult {
        try Task.checkCancellation()
        let pid = app.processIdentifier
        do {
            let windows: [AXEnumeratedWindow]
            switch route {
            case .persistent:
                guard let context = try await AppAXContext.getOrCreate(app) else {
                    return .init(pid: pid, route: route, windows: [], failed: true)
                }
                windows = try await context.getWindowsAsync(timeoutSeconds: perAppTimeout)
            case .oneShot:
                windows = try AXWindowEnumerationInspector.enumerateApplication(
                    pid: pid,
                    timeout: perAppTimeout
                )
                try Task.checkCancellation()
            }
            return .init(pid: pid, route: route, windows: windows, failed: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .init(pid: pid, route: route, windows: [], failed: true)
        }
    }

    static func selectFullRescanCandidates(
        _ candidatesByWindowId: [Int: [FullRescanWindowCandidate]],
        activationPolicyByPID: [pid_t: NSApplication.ActivationPolicy],
        preservingPIDsByWindowId: [Int: pid_t]
    ) -> [FullRescanWindowCandidate] {
        var selected: [FullRescanWindowCandidate] = []
        selected.reserveCapacity(candidatesByWindowId.count)
        for windowId in candidatesByWindowId.keys.sorted() {
            guard let candidates = candidatesByWindowId[windowId], var current = candidates.first else {
                continue
            }
            for candidate in candidates.dropFirst() {
                let preference = Self.fullRescanCandidatePreference(
                    candidate,
                    over: current,
                    activationPolicyByPID: activationPolicyByPID,
                    ownerPID: candidate.windowServerOwnerPID ?? current.windowServerOwnerPID,
                    existingPID: preservingPIDsByWindowId[windowId]
                )
                if preference.prefersCandidate {
                    current = candidate
                }
            }
            selected.append(current)
        }
        return selected
    }

    private func promoteOneShotCandidates(
        _ candidates: [FullRescanWindowCandidate],
        appsByPID: [pid_t: NSRunningApplication]
    ) async throws -> Set<pid_t> {
        try Task.checkCancellation()
        let grouped = Self.oneShotPromotionCandidatesByPID(candidates)
        var failedPIDs: Set<pid_t> = []
        for pid in grouped.keys.sorted() {
            try Task.checkCancellation()
            guard let app = appsByPID[pid], let candidates = grouped[pid] else {
                failedPIDs.insert(pid)
                continue
            }
            let hadContext = AppAXContext.contexts[pid] != nil
            do {
                guard let context = try await AppAXContext.getOrCreate(app),
                      try await context.bindWindowsAsync(
                          candidates.map(\.axRef),
                          timeoutSeconds: perAppTimeout
                      )
                else {
                    failedPIDs.insert(pid)
                    if !hadContext {
                        AppAXContext.contexts[pid]?.destroy()
                    }
                    continue
                }
            } catch is CancellationError {
                if !hadContext {
                    AppAXContext.contexts[pid]?.destroy()
                }
                throw CancellationError()
            } catch {
                failedPIDs.insert(pid)
                if !hadContext {
                    AppAXContext.contexts[pid]?.destroy()
                }
            }
        }
        return failedPIDs
    }

    static func oneShotPromotionCandidatesByPID(
        _ selectedCandidates: [FullRescanWindowCandidate]
    ) -> [pid_t: [FullRescanWindowCandidate]] {
        Dictionary(
            grouping: selectedCandidates.filter { $0.enumerationRoute == .oneShot },
            by: \.pid
        )
    }

    func applyFramesParallel(
        _ frames: [(pid: pid_t, windowId: Int, frame: CGRect)],
        terminalObserver: FrameApplicationTerminalObserver? = nil,
        verify: Bool = true
    ) {
        enqueueFrameApplications(frames, isRetry: false, verify: verify, terminalObserver: terminalObserver)
    }

    private func enqueueFrameApplications(
        _ frames: [(pid: pid_t, windowId: Int, frame: CGRect)],
        isRetry: Bool,
        verify: Bool = true,
        terminalObserver: FrameApplicationTerminalObserver? = nil
    ) {
        if frameApplicationBufferInUse {
            var framesByPid: [pid_t: [AXFrameApplicationRequest]] = [:]
            framesByPid.reserveCapacity(min(frames.count, 8))
            enqueueFrameApplicationsUsingBuffer(
                frames,
                isRetry: isRetry,
                verify: verify,
                terminalObserver: terminalObserver,
                framesByPid: &framesByPid
            )
            return
        }

        frameApplicationBufferInUse = true
        defer {
            for key in Array(framesByPidBuffer.keys) {
                framesByPidBuffer[key]?.removeAll(keepingCapacity: true)
            }
            frameApplicationBufferInUse = false
        }

        enqueueFrameApplicationsUsingBuffer(
            frames,
            isRetry: isRetry,
            verify: verify,
            terminalObserver: terminalObserver,
            framesByPid: &framesByPidBuffer
        )
    }

    private func enqueueFrameApplicationsUsingBuffer(
        _ frames: [(pid: pid_t, windowId: Int, frame: CGRect)],
        isRetry: Bool,
        verify: Bool,
        terminalObserver: FrameApplicationTerminalObserver?,
        framesByPid: inout [pid_t: [AXFrameApplicationRequest]]
    ) {
        framesByPid.reserveCapacity(min(frames.count, 8))
        var deferredDeliveries: [AXFrameTerminalDelivery] = []

        for (pid, windowId, frame) in frames {
            if inactiveWorkspaceWindowIds.contains(windowId) {
                continue
            }
            let decision = frameLedger.prepareFrameApplication(
                pid: pid,
                windowId: windowId,
                frame: frame,
                isRetry: isRetry,
                verify: verify,
                terminalObserver: terminalObserver
            )
            if decision.shouldCancelPendingRetry {
                cancelPendingFrameRetry(for: windowId)
            }
            deferredDeliveries.append(contentsOf: decision.deliveries)
            guard let request = decision.request else { continue }
            if framesByPid[pid] == nil {
                framesByPid[pid] = []
                framesByPid[pid]?.reserveCapacity(8)
            }
            framesByPid[pid]?.append(request)
        }

        for (pid, appFrames) in framesByPid where !appFrames.isEmpty {
            guard let context = AppAXContext.contexts[pid] else {
                handleFrameApplyResults(
                    appFrames.map {
                        AXFrameApplyResult(
                            requestId: $0.requestId,
                            pid: pid,
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
                continue
            }
            context.setFramesBatch(appFrames) { [weak self] results in
                self?.handleFrameApplyResults(results)
            }
        }

        for delivery in deferredDeliveries {
            delivery.deliver()
        }
    }

    func cancelPendingFrameJobs(_ entries: [(pid: pid_t, windowId: Int)]) {
        var deliveries: [AXFrameTerminalDelivery] = []
        for (pid, windowId) in uniqueFrameEntries(entries) {
            AppAXContext.contexts[pid]?.cancelFrameJob(for: windowId)
            deliveries.append(contentsOf: frameLedger.cancelFrameJob(windowId: windowId))
            cancelPendingFrameRetry(for: windowId)
        }
        for delivery in deliveries {
            delivery.deliver()
        }
    }

    func suppressFrameWrites(_ entries: [(pid: pid_t, windowId: Int)]) {
        var deliveries: [AXFrameTerminalDelivery] = []
        let entries = uniqueFrameEntries(entries)
        for (pid, windowIds) in groupedWindowIdsByPid(entries) {
            AppAXContext.contexts[pid]?.suppressFrameWrites(for: windowIds)
        }
        for (_, windowId) in entries {
            deliveries.append(contentsOf: frameLedger.suppressFrameWrite(windowId: windowId))
            cancelPendingFrameRetry(for: windowId)
            clearSkyLightLivePosition(for: windowId)
        }
        for delivery in deliveries {
            delivery.deliver()
        }
    }

    func unsuppressFrameWrites(_ entries: [(pid: pid_t, windowId: Int)]) {
        let entries = uniqueFrameEntries(entries)
        for (pid, windowIds) in groupedWindowIdsByPid(entries) {
            AppAXContext.contexts[pid]?.unsuppressFrameWrites(for: windowIds)
        }
        for (pid, windowId) in entries {
            clearSkyLightLivePosition(for: windowId)
            clearParkPending(for: windowId, pid: pid, reason: "shown")
        }
    }

    private func uniqueFrameEntries(_ entries: [(pid: pid_t, windowId: Int)]) -> [(pid: pid_t, windowId: Int)] {
        var uniqueEntries: [(pid: pid_t, windowId: Int)] = []
        uniqueEntries.reserveCapacity(entries.count)
        var seen: Set<WindowToken> = []
        for entry in entries {
            let token = WindowToken(pid: entry.pid, windowId: entry.windowId)
            guard seen.insert(token).inserted else { continue }
            uniqueEntries.append(entry)
        }
        return uniqueEntries
    }

    func applyPositionsViaSkyLight(
        _ positions: [(windowId: Int, origin: CGPoint)],
        allowInactive: Bool = false
    ) {
        let filtered = allowInactive
            ? positions
            : positions.filter { !inactiveWorkspaceWindowIds.contains($0.windowId) }
        guard !filtered.isEmpty else { return }
        let batchPositions = filtered.map {
            (windowId: UInt32($0.windowId), origin: ScreenCoordinateSpace.toWindowServer(point: $0.origin))
        }
        SkyLight.shared.batchMoveWindows(batchPositions)
    }

    private func shouldTrack(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated, app.activationPolicy != .prohibited else { return false }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }

        if let bundleId = app.bundleIdentifier, Self.systemUIBundleIds.contains(bundleId) {
            return false
        }

        return true
    }

    static func shouldEnumerateForFullRescan(
        activationPolicy: NSApplication.ActivationPolicy,
        hasDiscoveryEvidence: Bool
    ) -> Bool {
        fullRescanEnumerationRoute(
            activationPolicy: activationPolicy,
            hasDiscoveryEvidence: hasDiscoveryEvidence,
            hasContext: false,
            hasPreservedState: false
        ) != nil
    }

    static func fullRescanEnumerationRoute(
        activationPolicy: NSApplication.ActivationPolicy,
        hasDiscoveryEvidence: Bool,
        hasContext: Bool,
        hasPreservedState: Bool
    ) -> FullRescanEnumerationRoute? {
        guard activationPolicy != .prohibited else { return nil }
        if hasDiscoveryEvidence || hasContext || hasPreservedState {
            return .persistent
        }
        return activationPolicy == .regular ? .oneShot : nil
    }

    static func shouldPreferFullRescanCandidate(
        _ candidate: FullRescanWindowCandidate,
        over current: FullRescanWindowCandidate,
        activationPolicyByPID: [pid_t: NSApplication.ActivationPolicy],
        ownerPID: pid_t?,
        existingPID: pid_t?
    ) -> Bool {
        fullRescanCandidatePreference(
            candidate,
            over: current,
            activationPolicyByPID: activationPolicyByPID,
            ownerPID: ownerPID,
            existingPID: existingPID
        ).prefersCandidate
    }

    static func fullRescanCandidatePreference(
        _ candidate: FullRescanWindowCandidate,
        over current: FullRescanWindowCandidate,
        activationPolicyByPID: [pid_t: NSApplication.ActivationPolicy],
        ownerPID: pid_t?,
        existingPID: pid_t?
    ) -> FullRescanCandidatePreference {
        if candidate.isManageable != current.isManageable {
            return .init(prefersCandidate: candidate.isManageable, reason: .manageability)
        }
        let candidateIsExisting = candidate.pid == existingPID
        let currentIsExisting = current.pid == existingPID
        if candidateIsExisting != currentIsExisting {
            return .init(prefersCandidate: candidateIsExisting, reason: .preservedLogicalPID)
        }
        let candidateIsRegular = activationPolicyByPID[candidate.pid] == .regular
        let currentIsRegular = activationPolicyByPID[current.pid] == .regular
        if candidateIsRegular != currentIsRegular {
            return .init(prefersCandidate: candidateIsRegular, reason: .regularActivationPolicy)
        }
        let candidateHostsAXElement = candidate.pid == candidate.axPid
        let currentHostsAXElement = current.pid == current.axPid
        if candidateHostsAXElement != currentHostsAXElement {
            return .init(prefersCandidate: candidateHostsAXElement, reason: .axHostPID)
        }
        let candidateOwnsWindow = candidate.pid == ownerPID
        let currentOwnsWindow = current.pid == ownerPID
        if candidateOwnsWindow != currentOwnsWindow {
            return .init(prefersCandidate: candidateOwnsWindow, reason: .windowServerOwnerPID)
        }
        guard candidate.pid != current.pid else {
            return .init(prefersCandidate: false, reason: .stableFirstCandidate)
        }
        return .init(prefersCandidate: candidate.pid < current.pid, reason: .lowerPID)
    }

    private func groupedWindowIdsByPid(
        _ entries: [(pid: pid_t, windowId: Int)]
    ) -> [pid_t: [Int]] {
        var grouped: [pid_t: [Int]] = [:]
        for (pid, windowId) in entries {
            grouped[pid, default: []].append(windowId)
        }
        return grouped
    }

    func handleFrameApplyResults(_ results: [AXFrameApplyResult]) {
        let outcome = frameLedger.handleFrameApplyResults(results)
        for result in results {
            FrameApplyTrace.recordResult(result)
            if result.writeResult.failureReason == nil || result.confirmedFrame != nil {
                frameOrderSeq &+= 1
                lastFrameResultSeqByWindowId[result.windowId] = frameOrderSeq
                if isWindowParked?(result.windowId) == true {
                    markParkPending(for: result.windowId, pid: result.pid)
                }
            }
        }
        for retry in outcome.retries {
            FrameApplyTrace.recordEvent(
                pid: retry.pid,
                windowId: retry.windowId,
                outcome: "outcome=retry-scheduled",
                target: retry.frame
            )
            scheduleFrameRetry(pid: retry.pid, windowId: retry.windowId, frame: retry.frame)
        }
        for delivery in outcome.deliveries {
            delivery.deliver()
        }
        for refusal in outcome.terminalRefusals {
            FrameApplyTrace.recordEvent(
                pid: refusal.pid,
                windowId: refusal.windowId,
                outcome: "outcome=terminal-refusal",
                target: refusal.targetFrame
            )
            onTerminalFrameRefusal?(refusal)
        }
    }

    private func scheduleFrameRetry(pid: pid_t, windowId: Int, frame: CGRect) {
        cancelPendingFrameRetry(for: windowId)
        let generation = nextFrameRetryGeneration
        nextFrameRetryGeneration &+= 1
        pendingFrameRetryGenerationByWindowId[windowId] = generation
        pendingFrameRetryTasksByWindowId[windowId] = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            let currentWindowId = self.frameLedger.resolvedWindowId(for: windowId)
            guard self.pendingFrameRetryGenerationByWindowId[currentWindowId] == generation else { return }
            guard !self.frameLedger.hasPendingFrameWrite(for: currentWindowId) else { return }
            self.pendingFrameRetryGenerationByWindowId.removeValue(forKey: currentWindowId)
            self.pendingFrameRetryTasksByWindowId.removeValue(forKey: currentWindowId)
            self.enqueueFrameApplications([(pid, currentWindowId, frame)], isRetry: true)
        }
    }

    @discardableResult
    private func cancelPendingFrameRetry(for windowId: Int) -> Bool {
        guard let task = pendingFrameRetryTasksByWindowId.removeValue(forKey: windowId) else {
            pendingFrameRetryGenerationByWindowId.removeValue(forKey: windowId)
            return false
        }
        task.cancel()
        pendingFrameRetryGenerationByWindowId.removeValue(forKey: windowId)
        return true
    }

    private func cancelAllPendingFrameState() {
        for (_, task) in pendingFrameRetryTasksByWindowId {
            task.cancel()
        }
        pendingFrameRetryTasksByWindowId.removeAll()
        pendingFrameRetryGenerationByWindowId.removeAll()

        let deliveries = frameLedger.cancelAllPendingFrameState()
        for delivery in deliveries {
            delivery.deliver()
        }
    }
}
