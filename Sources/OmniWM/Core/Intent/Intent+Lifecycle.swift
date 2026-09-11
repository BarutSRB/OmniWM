// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

enum IntentRekeyOutcome {
    case unchanged
    case updated(IntentKind)
    case cancel(AppVisibilityTrace.Reason?)
}

@MainActor
extension Intent {
    func rekeyedKind(from oldToken: WindowToken, to newToken: WindowToken) -> IntentRekeyOutcome {
        switch kind {
        case let .focusWindow(token, workspaceId, requestPhase):
            return rekeyedFocusKind(
                from: oldToken, to: newToken,
                token: token, workspaceId: workspaceId, requestPhase: requestPhase
            )
        case var .appTerminationFocusRecovery(payload)
            where payload.departingToken == oldToken || payload.preferredTiledToken == oldToken:
            guard oldToken.pid == newToken.pid else {
                return phase == .pending ? .cancel(nil) : .unchanged
            }
            payload.rekey(from: oldToken, to: newToken)
            return .updated(.appTerminationFocusRecovery(payload))
        case var .appRevealFocus(payload) where payload.token == oldToken:
            guard oldToken.pid == newToken.pid else {
                return phase == .pending ? .cancel(.pidChanged) : .unchanged
            }
            if phase == .pending {
                AppVisibilityTrace.record(
                    .reveal, pid: oldToken.pid, outcome: .rekeyed,
                    intentId: id, windowId: newToken.windowId,
                    workspaceId: payload.workspaceId,
                    intentGeneration: payload.coordinatedAppGenerations[oldToken.pid],
                    destination: payload.destination.traceDestination
                )
            }
            payload.token = newToken
            payload.focusFingerprint.rekey(from: oldToken, to: newToken)
            return .updated(.appRevealFocus(payload))
        default:
            return .unchanged
        }
    }

    private func rekeyedFocusKind(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        requestPhase: ManagedFocusRequest.Phase
    ) -> IntentRekeyOutcome {
        if oldToken.pid != newToken.pid,
           case let .awaitingSameAppActivation(sourceToken, _) = requestPhase,
           token == oldToken || sourceToken == oldToken
        {
            return .cancel(nil)
        }
        let rekeysTarget = token == oldToken
        let rekeyedPhase: ManagedFocusRequest.Phase
        let rekeysSource: Bool
        if case let .awaitingSameAppActivation(sourceToken, isRetry) = requestPhase,
           sourceToken == oldToken
        {
            rekeyedPhase = .awaitingSameAppActivation(sourceToken: newToken, isRetry: isRetry)
            rekeysSource = true
        } else {
            rekeyedPhase = requestPhase
            rekeysSource = false
        }
        guard rekeysTarget || rekeysSource else { return .unchanged }
        return .updated(.focusWindow(
            token: rekeysTarget ? newToken : token,
            workspaceId: workspaceId,
            phase: rekeyedPhase
        ))
    }

    func recordRetirement(reason: AppVisibilityTrace.Reason?) {
        guard case let .appRevealFocus(payload) = kind else { return }
        let outcome: AppVisibilityTrace.Outcome
        let resolvedReason: AppVisibilityTrace.Reason?
        switch phase {
        case .pending:
            return
        case .confirmed:
            outcome = .confirmed
            resolvedReason = reason
        case .superseded:
            outcome = .cancelled
            resolvedReason = .superseded
        case .expired:
            outcome = .expired
            resolvedReason = reason
        case .cancelled:
            outcome = .cancelled
            resolvedReason = reason
        }
        AppVisibilityTrace.record(
            .reveal,
            pid: payload.token.pid,
            outcome: outcome,
            intentId: id,
            windowId: payload.token.windowId,
            workspaceId: payload.workspaceId,
            intentGeneration: payload.coordinatedAppGenerations[payload.token.pid],
            destination: payload.destination.traceDestination,
            reason: resolvedReason
        )
    }
}
