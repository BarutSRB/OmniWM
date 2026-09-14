// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

typealias IntentID = UInt64

struct ManagedFocusRetryRuntimeSnapshot: Equatable, Sendable {
    var attempts: UInt64 = 0
    var sourceChanges: UInt64 = 0
    var deadlineRearms: UInt64 = 0
    var exhaustions: UInt64 = 0
}

struct ReplacementFocusPayload: Equatable, Sendable {
    var pid: pid_t
    let workspaceId: WorkspaceDescriptor.ID
    var anchorToken: WindowToken
    var protectedTokens: Set<WindowToken>
    var isBurstOpen: Bool

    mutating func rekey(from oldToken: WindowToken, to newToken: WindowToken) {
        if anchorToken == oldToken {
            anchorToken = newToken
        }
        if protectedTokens.remove(oldToken) != nil {
            protectedTokens.insert(newToken)
        }
    }

    func protects(_ token: WindowToken) -> Bool {
        protectedTokens.contains(token)
    }

    func suppressesUnrelatedActivation(token: WindowToken, workspaceId: WorkspaceDescriptor.ID) -> Bool {
        token.pid == pid
            && workspaceId == self.workspaceId
            && !protects(token)
    }
}

struct SameAppCloseProbePayload: Equatable, Sendable {
    let focusedToken: WindowToken
    let observedToken: WindowToken
    let source: ActivationEventSource
    var observationGeneration: UInt64
}

enum AppTerminationFocusRecoveryPhase: Equatable, Sendable {
    case verifying(
        candidatePID: pid_t,
        source: ActivationEventSource,
        callbackGeneration: UInt64?
    )
    case recovering(fallbackPID: pid_t?)
    case retiring(fallbackPID: pid_t?)
}

struct AppTerminationFocusRecoveryPayload: Equatable, Sendable {
    var departingToken: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    var preferredTiledToken: WindowToken
    var phase: AppTerminationFocusRecoveryPhase
    var terminationHandled = false

    mutating func rekey(from oldToken: WindowToken, to newToken: WindowToken) {
        if departingToken == oldToken {
            departingToken = newToken
        }
        if preferredTiledToken == oldToken {
            preferredTiledToken = newToken
        }
    }
}

struct AppRevealFocusPayload: Equatable, Sendable {
    var token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let handleIdentity: ObjectIdentifier
    let coordinatedAppGenerations: [pid_t: UInt64]
    var pendingAppPIDs: Set<pid_t>
    let focusIntentWatermark: IntentID?
    var focusFingerprint: AppRevealFocusFingerprint
    let destination: AppRevealFocusDestination
}

enum AppRevealFocusDestination: Equatable, Sendable {
    case window
    case scratchpad(index: ScratchpadIndex, monitorId: Monitor.ID?)
    case scratchpadWindow(index: ScratchpadIndex, monitorId: Monitor.ID?)

    var traceDestination: AppVisibilityTrace.Destination {
        switch self {
        case .window:
            .window
        case .scratchpad,
             .scratchpadWindow:
            .scratchpad
        }
    }
}

enum AppRevealFocusDrainResult: Equatable, Sendable {
    case awaitingApps
    case ready
}

struct AppRevealFocusFingerprint: Equatable, Sendable {
    var selectedManagedToken: WindowToken?
    var pendingFocusedToken: WindowToken?
    let pendingFocusedWorkspaceId: WorkspaceDescriptor.ID?
    var nativeFocusOwner: NativeFocusOwner
    let interactionMonitorId: Monitor.ID?
    let activeWorkspaceIdsByMonitor: [Monitor.ID: WorkspaceDescriptor.ID]

    mutating func rekey(from oldToken: WindowToken, to newToken: WindowToken) {
        if selectedManagedToken == oldToken {
            selectedManagedToken = newToken
        }
        if pendingFocusedToken == oldToken {
            pendingFocusedToken = newToken
        }
        switch nativeFocusOwner {
        case let .managed(token) where token == oldToken:
            nativeFocusOwner = .managed(newToken)
        case let .external(identity):
            nativeFocusOwner = .external(identity.rekeying(from: oldToken, to: newToken))
        case .managed,
             .ownedSurface,
             .none:
            break
        }
    }
}

enum IntentKind: Equatable, Sendable {
    case activateApp(pid: pid_t)
    case appTerminationFocusRecovery(AppTerminationFocusRecoveryPayload)
    case appRevealFocus(AppRevealFocusPayload)
    case focusPolicyLease(owner: FocusPolicyLeaseOwner)
    case focusWindow(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        phase: ManagedFocusRequest.Phase = .awaitingConfirmation
    )
    case replacementFocus(ReplacementFocusPayload)
    case sameAppCloseProbe(SameAppCloseProbePayload)

    var focusTargetToken: WindowToken? {
        switch self {
        case .activateApp,
             .appTerminationFocusRecovery,
             .appRevealFocus,
             .focusPolicyLease,
             .replacementFocus,
             .sameAppCloseProbe:
            nil
        case let .focusWindow(token, _, _):
            token
        }
    }

    var isFocusWindow: Bool {
        if case .focusWindow = self {
            return true
        }
        return false
    }

    var targetPid: pid_t? {
        switch self {
        case let .activateApp(pid):
            pid
        case let .appTerminationFocusRecovery(payload):
            switch payload.phase {
            case let .verifying(candidatePID, _, _):
                candidatePID
            case let .recovering(fallbackPID),
                 let .retiring(fallbackPID):
                fallbackPID
            }
        case let .appRevealFocus(payload):
            payload.token.pid
        case .focusPolicyLease:
            nil
        case let .focusWindow(token, _, _):
            token.pid
        case let .replacementFocus(payload):
            payload.pid
        case let .sameAppCloseProbe(payload):
            payload.observedToken.pid
        }
    }
}

enum IntentPhase: Equatable, Sendable {
    case pending
    case confirmed
    case superseded
    case expired
    case cancelled

    var isRetired: Bool {
        self != .pending
    }
}

struct Intent: Equatable, Sendable {
    let id: IntentID
    var kind: IntentKind
    var origin: ManagedFocusOrigin
    let issuedAtSeq: UInt64
    var phase: IntentPhase = .pending
    var retryCount: Int = 0
    var lastActivationSource: ActivationEventSource?
    var retiredAt: ContinuousClock.Instant?

    var asManagedFocusRequest: ManagedFocusRequest? {
        guard case let .focusWindow(token, workspaceId, requestPhase) = kind else { return nil }
        return ManagedFocusRequest(
            requestId: id,
            token: token,
            workspaceId: workspaceId,
            origin: origin,
            phase: requestPhase,
            retryCount: retryCount,
            lastActivationSource: lastActivationSource,
            status: phase == .confirmed ? .confirmed : .pending
        )
    }
}

enum EchoClassification: Equatable {
    case echoOf(Intent)
    case lateEcho(Intent)
    case external
}
