// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import CoreHID
import Foundation
import IOKit
import os
import Synchronization

@MainActor
final class MultitouchTopologyMonitor {
    private typealias TopologyMonitoringOperations = MultitouchGestureSource.TopologyMonitoringOperations
    private let topologyMonitoringOperations: TopologyMonitoringOperations?
    private let retryDelays: [Duration]
    private var topologyTask: Task<Void, Never>?
    private(set) var topologyObserverState: MultitouchGestureSource.TopologyObserverState = .stopped

    init(operations: MultitouchGestureSource.TopologyMonitoringOperations?, retryDelays: [Duration]) {
        topologyMonitoringOperations = operations
        self.retryDelays = retryDelays
    }

    deinit {
        topologyTask?.cancel()
    }

    func cancel() {
        topologyTask?.cancel()
        topologyTask = nil
    }

    func finishStop() {
        topologyObserverState = .stopped
    }

    static let topologyCriteria = [
        HIDDeviceManager.DeviceMatchingCriteria(deviceUsages: [
            .digitizers(.touchPad),
            .digitizers(.multiplePointDigitizer)
        ])
    ]

    static var liveOperations: MultitouchGestureSource.TopologyMonitoringOperations {
        let manager = HIDDeviceManager()
        return TopologyMonitoringOperations(
            notifications: {
                let notifications = await manager.monitorNotifications(matchingCriteria: topologyCriteria)
                return topologySignals(from: notifications)
            },
            sleep: { try await Task.sleep(for: $0) }
        )
    }

    private static func topologySignals(
        from notifications: AsyncThrowingStream<HIDDeviceManager.Notification, any Error>
    ) -> TopologyMonitoringOperations.Notifications {
        TopologyMonitoringOperations.Notifications { continuation in
            let task = Task {
                do {
                    for try await notification in notifications {
                        switch notification {
                        case .deviceMatched:
                            continuation.yield(.arrival)
                        case .deviceRemoved:
                            continuation.yield(.removal)
                        @unknown default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func start(source: MultitouchGestureSource) {
        guard let topologyMonitoringOperations, topologyTask == nil else { return }
        let observerRetryDelays = retryDelays
        topologyObserverState = .monitoring
        topologyTask = Task { @MainActor [weak self, weak source] in
            var failures = 0
            while !Task.isCancelled {
                do {
                    let notifications = await topologyMonitoringOperations.notifications()
                    for try await signal in notifications {
                        guard !Task.isCancelled, let self, let source else { return }
                        failures = 0
                        topologyObserverState = .monitoring
                        source.receiveTopologySignal(signal)
                    }
                    guard !Task.isCancelled else { return }
                } catch {
                    guard !Task.isCancelled else { return }
                }

                failures += 1
                let retryDelay: Duration
                do {
                    guard let self, let source else { return }
                    source.requestRevalidation(.observerRecovery)
                    guard failures <= observerRetryDelays.count else {
                        self.topologyObserverState = .exhausted
                        self.topologyTask = nil
                        return
                    }
                    self.topologyObserverState = .retrying(failures)
                    retryDelay = observerRetryDelays[failures - 1]
                }
                do {
                    try await topologyMonitoringOperations.sleep(retryDelay)
                } catch {
                    return
                }
            }
        }
    }
}
