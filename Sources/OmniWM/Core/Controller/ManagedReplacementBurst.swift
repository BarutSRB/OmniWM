// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

extension AXEventHandler {
    struct ManagedReplacementKey: Hashable {
        let pid: pid_t
        let workspaceId: WorkspaceDescriptor.ID
    }

    enum ManagedReplacementCorrelationPolicy {
        case structural

        var graceDelay: Duration {
            switch self {
            case .structural: .milliseconds(150)
            }
        }
    }

    struct PendingManagedCreate {
        let sequence: UInt64
        let candidate: PreparedCreate
        let focusedActivation: PendingFocusedManagedActivation?
    }

    struct PendingManagedDestroy {
        let sequence: UInt64
        var candidate: PreparedDestroy
    }

    enum PendingManagedReplacementEvent {
        case create(PendingManagedCreate)
        case destroy(PendingManagedDestroy)

        var sequence: UInt64 {
            switch self {
            case let .create(create): create.sequence
            case let .destroy(destroy): destroy.sequence
            }
        }
    }

    struct PendingManagedReplacementBurst {
        let policy: ManagedReplacementCorrelationPolicy
        let firstEventUptime: TimeInterval
        private(set) var creates: [PendingManagedCreate] = []
        private(set) var destroys: [PendingManagedDestroy] = []

        @discardableResult
        mutating func append(create: PendingManagedCreate) -> Bool {
            guard !creates.contains(where: { $0.candidate.token == create.candidate.token }) else { return false }
            creates.append(create)
            return true
        }

        mutating func append(destroy: PendingManagedDestroy) {
            guard let index = destroys.firstIndex(where: { $0.candidate.token == destroy.candidate.token }) else {
                destroys.append(destroy)
                return
            }
            guard destroys[index].candidate.evidence == .transientLifecycle,
                  destroy.candidate.evidence == .windowClosed
            else {
                return
            }
            destroys[index].candidate.evidence = .windowClosed
        }

        var orderedEvents: [PendingManagedReplacementEvent] {
            let events = creates.map(PendingManagedReplacementEvent.create) + destroys
                .map(PendingManagedReplacementEvent.destroy)
            return events.sorted { $0.sequence < $1.sequence }
        }

        func orderedEvents(excludingSequences sequences: Set<UInt64>) -> [PendingManagedReplacementEvent] {
            orderedEvents.filter { !sequences.contains($0.sequence) }
        }
    }

    struct MatchedManagedReplacementPair {
        let destroy: PendingManagedDestroy
        let create: PendingManagedCreate

        var excludedSequences: Set<UInt64> {
            [destroy.sequence, create.sequence]
        }
    }
}
