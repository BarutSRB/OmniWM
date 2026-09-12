// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct MenuBarItemSampleTracker {
    struct Attempt {
        let isFirst: Bool
        let startedAt: ContinuousClock.Instant
    }

    private struct ItemSampleState {
        let pid: pid_t
        let frames: [CGRect]
        let emptySince: ContinuousClock.Instant?
    }

    private static let resolveDeadline: Duration = .seconds(2)
    private var previousSamples: [String: ItemSampleState] = [:]
    private var firstAttemptStarts: [String: ContinuousClock.Instant] = [:]
    private let clock: ContinuousClock
    private let deadline: ContinuousClock.Instant
    private let hardDeadline: ContinuousClock.Instant
    private var extendedEmptyResolution = false

    init(clock: ContinuousClock, startedAt: ContinuousClock.Instant) {
        self.clock = clock
        deadline = startedAt.advanced(by: Self.resolveDeadline)
        hardDeadline = deadline.advanced(by: Self.resolveDeadline)
    }

    mutating func shouldContinue(at now: ContinuousClock.Instant) -> Bool {
        let pendingEmptyGrace = previousSamples.values.contains { sample in
            guard let emptySince = sample.emptySince else { return false }
            return emptySince.duration(to: now) < Self.resolveDeadline
        }
        if now >= deadline, pendingEmptyGrace {
            extendedEmptyResolution = true
        }
        return now < deadline || extendedEmptyResolution && now < hardDeadline
    }

    mutating func beginAttempt(for bundleID: String) -> Attempt {
        let firstAttempt = firstAttemptStarts[bundleID] == nil
        let attemptStartedAt = clock.now
        if firstAttempt {
            firstAttemptStarts[bundleID] = attemptStartedAt
        }
        return Attempt(isFirst: firstAttempt, startedAt: attemptStartedAt)
    }

    mutating func recordSample(
        pid: pid_t,
        frames: [CGRect],
        for bundleID: String,
        attempt: Attempt
    ) -> Bool {
        if frames.isEmpty {
            recordEmptySample(pid: pid, for: bundleID, attempt: attempt)
            return false
        }
        if previousSamples[bundleID]?.frames.isEmpty == true {
            extendedEmptyResolution = true
        }
        if let previous = previousSamples[bundleID],
           previous.pid == pid, previous.frames == frames
        {
            return true
        }
        previousSamples[bundleID] = ItemSampleState(pid: pid, frames: frames, emptySince: nil)
        return false
    }

    private mutating func recordEmptySample(pid: pid_t, for bundleID: String, attempt: Attempt) {
        let previous = previousSamples[bundleID]
        if !attempt.isFirst {
            extendedEmptyResolution = true
        }
        let emptySince = if previous?.pid == pid, previous?.frames.isEmpty == true {
            previous?.emptySince ?? clock.now
        } else if attempt.isFirst {
            attempt.startedAt
        } else {
            clock.now
        }
        previousSamples[bundleID] = ItemSampleState(pid: pid, frames: [], emptySince: emptySince)
    }

    mutating func discardSample(for bundleID: String) {
        previousSamples.removeValue(forKey: bundleID)
    }

    func authoritativeEmptyPID(for bundleID: String) -> pid_t? {
        guard let previous = previousSamples[bundleID], previous.frames.isEmpty,
              let emptySince = previous.emptySince,
              Self.shouldAcceptAuthoritativeEmpty(continuouslyEmptyFor: emptySince.duration(to: clock.now))
        else { return nil }
        return previous.pid
    }

    static func shouldAcceptAuthoritativeEmpty(continuouslyEmptyFor: Duration) -> Bool {
        continuouslyEmptyFor >= resolveDeadline
    }
}
