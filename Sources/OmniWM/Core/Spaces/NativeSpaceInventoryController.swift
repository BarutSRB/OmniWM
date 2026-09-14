// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct NativeSpaceManagedWindowReference: Equatable, Sendable {
    let pid: pid_t
    let windowId: Int
}

enum NativeSpaceInventoryScopeResolver {
    static func scope(
        spaceIds: Set<UInt64>,
        topologies: [SpaceTopology],
        managedWindows: [NativeSpaceManagedWindowReference]
    ) -> RescanScope {
        guard !spaceIds.isEmpty,
              !spaceIds.contains(0),
              !topologies.isEmpty
        else { return .all }

        let currentKnownSpaceIds = Set(
            topologies.last?.displays.flatMap(\.spaceIds) ?? []
        )
        var relevantSpaceIds = spaceIds
        for topology in topologies.dropLast() {
            for display in topology.displays {
                for spaceId in display.spaceIds where !currentKnownSpaceIds.contains(spaceId) {
                    relevantSpaceIds.insert(spaceId)
                }
            }
        }

        var windowIdsByPID: [pid_t: Set<Int>] = [:]
        for window in managedWindows
            where topologies.contains(where: { topology in
                topology.spaceForWindow(window.windowId).map(relevantSpaceIds.contains) == true
            })
        {
            windowIdsByPID[window.pid, default: []].insert(window.windowId)
        }
        return .targeted(
            appPIDs: [],
            nativeSpaceIds: spaceIds,
            nativeSpaceWindowIdsByPID: windowIdsByPID
        )
    }
}

struct NativeSpaceInventoryRequest: Sendable {
    let baseline: SpaceTopology
    private(set) var reason: RefreshReason
    private(set) var includesActiveSpaceChange: Bool
    private(set) var reconcilesWorkspaceMonitorState: Bool

    init(reason: RefreshReason, baseline: SpaceTopology) {
        self.baseline = baseline
        self.reason = reason
        includesActiveSpaceChange = reason == .activeSpaceChanged
        reconcilesWorkspaceMonitorState = reason == .monitorConfigurationChanged
    }

    mutating func merge(reason: RefreshReason) {
        includesActiveSpaceChange =
            includesActiveSpaceChange
                || reason == .activeSpaceChanged
        reconcilesWorkspaceMonitorState =
            reconcilesWorkspaceMonitorState
                || reason == .monitorConfigurationChanged
        switch (self.reason, reason) {
        case (_, .monitorConfigurationChanged),
             (.activeSpaceChanged, .unlock):
            self.reason = reason
        default:
            break
        }
    }

    func resolution(
        for topology: SpaceTopology
    ) -> (recordsActiveSpaceChange: Bool, rescanReason: RefreshReason?) {
        let recordsActiveSpaceChange =
            includesActiveSpaceChange
                && currentSpacesByDisplay(topology) != currentSpacesByDisplay(baseline)
        let rescanReason = reason == .activeSpaceChanged && !recordsActiveSpaceChange
            ? nil
            : reason
        return (recordsActiveSpaceChange, rescanReason)
    }

    private func currentSpacesByDisplay(_ topology: SpaceTopology) -> [String: UInt64] {
        topology.displays.reduce(into: [:]) {
            $0[$1.displayIdentifier] = $1.currentSpaceId
        }
    }
}

@MainActor
final class NativeSpaceInventoryController {
    enum TopologyInventoryTerminalReason: String, Equatable, Sendable {
        case authoritative
        case globalFallback
        case cancelled
        case superseded
    }

    struct PerformanceSnapshot: Equatable, Sendable {
        let topologySamples: UInt64
        let topologyGlobalFallbacks: UInt64
        let authoritativeTerminations: UInt64
        let globalFallbackTerminations: UInt64
        let cancelledTerminations: UInt64
        let supersededTerminations: UInt64
        let lastTopologyTerminalReason: TopologyInventoryTerminalReason?
    }

    private struct PerformanceCounters {
        var topologySamples: UInt64 = 0
        var topologyGlobalFallbacks: UInt64 = 0
        var authoritativeTerminations: UInt64 = 0
        var globalFallbackTerminations: UInt64 = 0
        var cancelledTerminations: UInt64 = 0
        var supersededTerminations: UInt64 = 0
        var lastTopologyTerminalReason: TopologyInventoryTerminalReason?

        var snapshot: PerformanceSnapshot {
            PerformanceSnapshot(
                topologySamples: topologySamples,
                topologyGlobalFallbacks: topologyGlobalFallbacks,
                authoritativeTerminations: authoritativeTerminations,
                globalFallbackTerminations: globalFallbackTerminations,
                cancelledTerminations: cancelledTerminations,
                supersededTerminations: supersededTerminations,
                lastTopologyTerminalReason: lastTopologyTerminalReason
            )
        }
    }

    private weak var controller: WMController?
    private var topologyInventoryStabilityTask: Task<Void, Never>?
    private var topologyInventoryStabilityGeneration: UInt64 = 0
    private var topologyInventoryRequest: NativeSpaceInventoryRequest?
    private var performanceCounters: PerformanceCounters?
    var sampleProvider: (@MainActor () -> NativeSpaceTopologySample?)?
    var sleeper: @MainActor (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }

    private static let topologyInventorySampleInterval: Duration = .milliseconds(100)
    private static let topologyInventoryRetryInterval: Duration = .seconds(1)

    init(controller: WMController) {
        self.controller = controller
    }

    func beginPerformanceCapture() {
        performanceCounters = PerformanceCounters()
    }

    func performanceSnapshot() -> PerformanceSnapshot? {
        performanceCounters?.snapshot
    }

    func endPerformanceCapture() -> PerformanceSnapshot? {
        let snapshot = performanceCounters?.snapshot
        performanceCounters = nil
        return snapshot
    }

    private func recordTopologyTerminal(_ reason: TopologyInventoryTerminalReason) {
        guard performanceCounters != nil else { return }
        performanceCounters?.lastTopologyTerminalReason = reason
        switch reason {
        case .authoritative:
            performanceCounters?.authoritativeTerminations &+= 1
        case .globalFallback:
            performanceCounters?.globalFallbackTerminations &+= 1
        case .cancelled:
            performanceCounters?.cancelledTerminations &+= 1
        case .superseded:
            performanceCounters?.supersededTerminations &+= 1
        }
    }

    func schedule(
        reason: RefreshReason,
        baseline: SpaceTopology? = nil
    ) {
        guard let controller else { return }
        mergeTopologyInventoryRequest(reason: reason, baseline: baseline, controller: controller)
        controller.layoutRefreshController.beginInventoryStabilityBarrier()
        topologyInventoryStabilityGeneration &+= 1
        let generation = topologyInventoryStabilityGeneration
        if topologyInventoryStabilityTask != nil {
            recordTopologyTerminal(.superseded)
        }
        topologyInventoryStabilityTask?.cancel()
        topologyInventoryStabilityTask = Task { @MainActor [weak self] in
            var gate = NativeSpaceInventoryStabilityGate()
            while !Task.isCancelled {
                guard let self, let controller = self.controller else { return }
                let sample = if let provider = self.sampleProvider {
                    provider()
                } else {
                    controller.spaceTracker.currentTopologySample()
                }
                self.performanceCounters?.topologySamples &+= 1
                let observation = gate.observe(sample)
                if let topologyToApply = observation.topologyToApply {
                    controller.spaceTracker.refresh(
                        using: topologyToApply,
                        windowMembershipUpdate: .carryForwardKnown,
                        reconcilesNativeFullscreen: false
                    )
                    controller.layoutRefreshController.resumeAfterPostUnlockTopologySample()
                }
                if let authoritativeTopologyToApply = observation.authoritativeTopologyToApply {
                    self.applyAuthoritativeTopologyInventory(
                        authoritativeTopologyToApply,
                        generation: generation,
                        controller: controller
                    )
                    return
                }
                if observation.requestsGlobalFallback {
                    self.applyTopologyInventoryFallback(generation: generation, controller: controller)
                    return
                }
                let interval = gate.usesRetryInterval
                    ? Self.topologyInventoryRetryInterval
                    : Self.topologyInventorySampleInterval
                do {
                    try await self.sleeper(interval)
                } catch {
                    return
                }
            }
        }
    }

    private func mergeTopologyInventoryRequest(
        reason: RefreshReason,
        baseline: SpaceTopology?,
        controller: WMController
    ) {
        if var request = topologyInventoryRequest {
            request.merge(reason: reason)
            topologyInventoryRequest = request
        } else {
            topologyInventoryRequest = NativeSpaceInventoryRequest(
                reason: reason,
                baseline: baseline ?? controller.workspaceManager.spaceTopology
            )
        }
    }

    private func applyAuthoritativeTopologyInventory(
        _ authoritativeTopologyToApply: NativeSpaceTopologySample,
        generation: UInt64,
        controller: WMController
    ) {
        guard
            !Task.isCancelled,
            generation == topologyInventoryStabilityGeneration
        else { return }
        controller.spaceTracker.refresh(
            using: authoritativeTopologyToApply,
            windowMembershipUpdate: .query(preservesKnownOnMissing: true)
        )
        guard let request = topologyInventoryRequest else { return }
        let spaceIds = authoritativeTopologyToApply.inventorySpaceIds
        let scope = NativeSpaceInventoryScopeResolver.scope(
            spaceIds: spaceIds,
            topologies: [request.baseline, controller.workspaceManager.spaceTopology],
            managedWindows: managedWindowReferences(controller)
        )
        let authoritativeTopology = authoritativeTopologyToApply.topology
        let resolution = request.resolution(for: authoritativeTopology)
        recordTopologyTerminal(.authoritative)
        topologyInventoryStabilityTask = nil
        topologyInventoryRequest = nil
        if resolution.recordsActiveSpaceChange {
            controller.workspaceManager.recordReconcileEvent(
                .activeSpaceChanged(source: .service)
            )
        }
        guard let rescanReason = resolution.rescanReason else {
            controller.layoutRefreshController.endInventoryStabilityBarrier()
            return
        }
        controller.layoutRefreshController.beginInventoryStabilityBarrier()
        controller.layoutRefreshController.requestFullRescan(
            reason: rescanReason,
            scope: scope,
            reconcilesWorkspaceMonitorState: request.reconcilesWorkspaceMonitorState
        )
        controller.layoutRefreshController.endInventoryStabilityBarrier()
    }

    private func applyTopologyInventoryFallback(generation: UInt64, controller: WMController) {
        guard
            !Task.isCancelled,
            generation == topologyInventoryStabilityGeneration,
            let request = topologyInventoryRequest
        else { return }
        performanceCounters?.topologyGlobalFallbacks &+= 1
        recordTopologyTerminal(.globalFallback)
        controller.layoutRefreshController.requestFullRescan(
            reason: .staleFullRescan,
            scope: .all,
            reconcilesWorkspaceMonitorState: request.reconcilesWorkspaceMonitorState
        )
        topologyInventoryStabilityTask = nil
        topologyInventoryRequest = nil
        controller.layoutRefreshController.endInventoryStabilityBarrier()
        controller.layoutRefreshController.resumeAfterPostUnlockTopologySample()
    }

    private func managedWindowReferences(_ controller: WMController) -> [NativeSpaceManagedWindowReference] {
        controller.workspaceManager.allEntries().map {
            NativeSpaceManagedWindowReference(pid: $0.pid, windowId: $0.windowId)
        }
    }

    func cancel() {
        topologyInventoryStabilityGeneration &+= 1
        if topologyInventoryStabilityTask != nil {
            recordTopologyTerminal(.cancelled)
        }
        topologyInventoryStabilityTask?.cancel()
        topologyInventoryStabilityTask = nil
        topologyInventoryRequest = nil
        controller?.layoutRefreshController.cancelInventoryStabilityBarrier()
    }
}
