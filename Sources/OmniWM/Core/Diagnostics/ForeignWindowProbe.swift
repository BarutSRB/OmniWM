// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

@MainActor
enum ForeignWindowProbe {
    static func run(
        sample: WindowServerInfo?,
        operations suppliedOperations: ForeignWindowProbeOperations? = nil
    ) async -> ForeignWindowProbeResult? {
        let sky = SkyLight.shared
        guard let sample else { return nil }
        let operations = suppliedOperations ?? ForeignWindowProbeOperations(
            queryWindowInfo: { sky.queryWindowInfo($0) },
            windowBounds: { sky.getWindowBounds($0) },
            independentOrigin: { independentOrigin($0, expectedPID: $1) },
            batchMove: { wid, origin in
                sky.batchMoveWindows([(windowId: wid, origin: origin)])
            },
            directMove: { sky.moveWindow($0, to: $1) },
            waitForOrigin: { wid, pid, origin in
                await waitForIndependentOrigin(wid, expectedPID: pid, matching: origin)
            }
        )
        DiagnosticsEventRecorder.shared.recordVerbose(
            name: "privateAPIProbe.foreignMove",
            pid: sample.pid,
            windowId: sample.id
        )
        return await operations.probe(sample)
    }

    private static func waitForIndependentOrigin(
        _ wid: UInt32,
        expectedPID: pid_t,
        matching target: CGPoint
    ) async -> CGPoint? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(250))
        repeat {
            if let origin = independentOrigin(wid, expectedPID: expectedPID),
               originsMatch(origin, target)
            {
                return origin
            }
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                return nil
            }
        } while clock.now < deadline
        return nil
    }

    static func originsMatch(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) < 2 && abs(lhs.y - rhs.y) < 2
    }

    private static func independentOrigin(_ wid: UInt32, expectedPID: pid_t) -> CGPoint? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(wid)) as? [[String: Any]],
              let info = list.first,
              let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
              ownerPID.int32Value == expectedPID,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }
        return rect.origin
    }
}

@MainActor
extension ForeignWindowProbeOperations {
    fileprivate func probe(_ sample: WindowServerInfo) async -> ForeignWindowProbeResult {
        guard let currentInfo = queryWindowInfo(sample.id),
              currentInfo.id == sample.id,
              currentInfo.pid == sample.pid
        else {
            return ForeignWindowProbeResult(unattempted: sample, reason: "sls-identity-unavailable")
        }
        guard let slsBounds = windowBounds(sample.id),
              let before = independentOrigin(sample.id, sample.pid)
        else {
            return ForeignWindowProbeResult(unattempted: sample, reason: "baseline-unavailable")
        }
        let baseline = slsBounds.origin
        guard ForeignWindowProbe.originsMatch(baseline, before) else {
            return ForeignWindowProbeResult(
                unattempted: sample,
                reason: "baseline-mismatch",
                detail: " sls=\(TraceFormat.point(baseline)) independent=\(TraceFormat.point(before))"
            )
        }
        return await move(sample: sample, baseline: baseline, before: before)
    }

    private func move(
        sample: WindowServerInfo,
        baseline: CGPoint,
        before: CGPoint
    ) async -> ForeignWindowProbeResult {
        let target = CGPoint(x: baseline.x + 6, y: baseline.y + 6)
        let submission = batchMove(sample.id, target)
        guard submission == .submitted else {
            return incompleteMove(sample: sample, submission: submission, baseline: baseline, before: before)
        }
        let movedOrigin = await waitForOrigin(
            sample.id,
            sample.pid,
            target
        )
        let after = movedOrigin ?? independentOrigin(sample.id, sample.pid)
        let delta: CGPoint? = {
            guard let after else { return nil }
            return CGPoint(x: after.x - before.x, y: after.y - before.y)
        }()
        let moved = delta.map { abs($0.x - 6) < 2 && abs($0.y - 6) < 2 } ?? false
        let restoration = await restoreForeignWindow(
            sample: sample,
            baseline: baseline,
            target: target,
            movedWasObserved: moved
        )
        let restored = restoration.restoredOrigin.map { ForeignWindowProbe.originsMatch($0, baseline) } ?? false
        let outcome: PrivateAPISelfTestOutcome = if moved,
                                                    restored,
                                                    !restoration.interfered
        {
            .works
        } else if restoration.interfered || after == nil {
            .inconclusive
        } else {
            .failed
        }
        let restoreDetail = restoration.transactionSubmission.map(String.init(describing:))
            ?? "not-attempted"
        let directRestoreDetail = restoration.directMoveResult.map(String.init(describing:))
            ?? "not-attempted"
        return ForeignWindowProbeResult(
            targetPid: sample.pid,
            targetWid: sample.id,
            movedDelta: delta,
            skylightMoved: moved,
            restored: restored,
            outcome: outcome,
            detail: "submission=\(submission) restore=\(restoreDetail) directRestore=\(directRestoreDetail)"
                + " pid=\(sample.pid) wid=\(sample.id) before=\(TraceFormat.point(before))"
        )
    }

    private func incompleteMove(
        sample: WindowServerInfo,
        submission: SkyLight.TransactionSubmissionResult,
        baseline: CGPoint,
        before: CGPoint
    ) -> ForeignWindowProbeResult {
        let restoreSubmission = submission == .deferred
            ? batchMove(sample.id, baseline)
            : nil
        let current = independentOrigin(sample.id, sample.pid)
        let restored = current.map { ForeignWindowProbe.originsMatch($0, baseline) } ?? false
        return ForeignWindowProbeResult(
            targetPid: sample.pid,
            targetWid: sample.id,
            movedDelta: current.map { CGPoint(x: $0.x - before.x, y: $0.y - before.y) },
            skylightMoved: false,
            restored: restored,
            outcome: submission == .unavailable ? .failed : .inconclusive,
            detail: "submission=\(submission) restore="
                + (restoreSubmission.map(String.init(describing:)) ?? "not-attempted")
                + " pid=\(sample.pid) wid=\(sample.id) before=\(TraceFormat.point(before))"
        )
    }

    private func restoreForeignWindow(
        sample: WindowServerInfo,
        baseline: CGPoint,
        target: CGPoint,
        movedWasObserved: Bool
    ) async -> ForeignWindowRestoreResult {
        guard let currentInfo = queryWindowInfo(sample.id),
              currentInfo.id == sample.id,
              currentInfo.pid == sample.pid,
              let currentOrigin = independentOrigin(sample.id, sample.pid)
        else {
            return ForeignWindowRestoreResult(
                transactionSubmission: nil,
                directMoveResult: nil,
                restoredOrigin: nil,
                interfered: true
            )
        }
        let currentlyAtTarget = ForeignWindowProbe.originsMatch(currentOrigin, target)
        let currentlyAtBaseline = ForeignWindowProbe.originsMatch(currentOrigin, baseline)
        guard currentlyAtTarget || currentlyAtBaseline else {
            return ForeignWindowRestoreResult(
                transactionSubmission: nil,
                directMoveResult: nil,
                restoredOrigin: nil,
                interfered: true
            )
        }

        var transactionSubmission: SkyLight.TransactionSubmissionResult?
        if currentlyAtTarget {
            let submission = batchMove(sample.id, baseline)
            transactionSubmission = submission
            if submission == .submitted,
               let restoredOrigin = await waitForOrigin(sample.id, sample.pid, baseline)
            {
                return ForeignWindowRestoreResult(
                    transactionSubmission: submission,
                    directMoveResult: nil,
                    restoredOrigin: restoredOrigin,
                    interfered: false
                )
            }
        }

        return await restoreDirectly(
            sample: sample,
            baseline: baseline,
            target: target,
            transactionSubmission: transactionSubmission,
            interfered: movedWasObserved && currentlyAtBaseline
        )
    }

    private func restoreDirectly(
        sample: WindowServerInfo,
        baseline: CGPoint,
        target: CGPoint,
        transactionSubmission: SkyLight.TransactionSubmissionResult?,
        interfered: Bool
    ) async -> ForeignWindowRestoreResult {
        guard let latestInfo = queryWindowInfo(sample.id),
              latestInfo.id == sample.id,
              latestInfo.pid == sample.pid,
              let latestOrigin = independentOrigin(sample.id, sample.pid),
              ForeignWindowProbe.originsMatch(latestOrigin, target) || ForeignWindowProbe.originsMatch(
                  latestOrigin,
                  baseline
              )
        else {
            return ForeignWindowRestoreResult(
                transactionSubmission: transactionSubmission,
                directMoveResult: nil,
                restoredOrigin: nil,
                interfered: true
            )
        }
        let directMoveResult = directMove(sample.id, baseline)
        let restoredOrigin = directMoveResult
            ? await waitForOrigin(sample.id, sample.pid, baseline)
            : nil
        return ForeignWindowRestoreResult(
            transactionSubmission: transactionSubmission,
            directMoveResult: directMoveResult,
            restoredOrigin: restoredOrigin,
            interfered: interfered
        )
    }
}

extension ForeignWindowProbeResult {
    fileprivate init(unattempted sample: WindowServerInfo, reason: String, detail: String = "") {
        self.init(
            targetPid: sample.pid,
            targetWid: sample.id,
            movedDelta: nil,
            skylightMoved: false,
            restored: false,
            outcome: .inconclusive,
            detail: "submission=not-attempted reason=\(reason) pid=\(sample.pid) wid=\(sample.id)" + detail
        )
    }
}
