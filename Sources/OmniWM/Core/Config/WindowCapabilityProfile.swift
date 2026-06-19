// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct WindowCapabilityProfile: Equatable, Sendable {
    enum FrameWriteReliability: String, Equatable, Sendable {
        case reliable
        case prefersObservedFrame
        case toleratesVerificationMismatch
    }

    enum FocusActivationBehavior: String, Equatable, Sendable {
        case standard
        case requiresExplicitActivation
        case requiresActivationRecovery
    }

    enum NativeFullscreenReplacement: String, Equatable, Sendable {
        case none
        case expectsReplacementWindow
    }

    enum TransientTreatment: String, Equatable, Sendable {
        case standard
        case alwaysFloat
        case unmanaged
    }

    enum RestoreHandling: String, Equatable, Sendable {
        case standard
        case skipFrameRestore
    }

    var frameWrite: FrameWriteReliability
    var focusActivation: FocusActivationBehavior
    var nfrReplacement: NativeFullscreenReplacement
    var transient: TransientTreatment
    var restore: RestoreHandling

    static let standard = WindowCapabilityProfile(
        frameWrite: .reliable,
        focusActivation: .standard,
        nfrReplacement: .none,
        transient: .standard,
        restore: .standard
    )

    func shouldAttemptNativeFullscreenReplacementMatch(
        hasPendingTransition: Bool
    ) -> Bool {
        if nfrReplacement == .expectsReplacementWindow {
            return true
        }
        return hasPendingTransition
    }

    var shouldSkipNativeFullscreenFrameRestore: Bool {
        restore == .skipFrameRestore
    }
}

enum WindowCapabilityResolutionSource: Equatable, Sendable {
    case userOverride(bundleId: String)
    case bundleIdRule(bundleId: String)
    case roleSubroleRule(role: String, subrole: String?)
    case windowLevelRule(level: Int)
    case builtInDefault
}

extension WindowCapabilityResolutionSource {
    var precedence: Int {
        switch self {
        case .userOverride: return 4
        case .bundleIdRule: return 3
        case .roleSubroleRule: return 2
        case .windowLevelRule: return 1
        case .builtInDefault: return 0
        }
    }

    var stableKey: String {
        switch self {
        case let .userOverride(bundleId),
             let .bundleIdRule(bundleId):
            return bundleId
        case let .roleSubroleRule(role, subrole):
            return "\(role)/\(subrole ?? "*")"
        case let .windowLevelRule(level):
            return "lvl=\(level)"
        case .builtInDefault:
            return ""
        }
    }
}

struct WindowCapabilityProfileTOMLOverride: Codable, Equatable, Sendable {
    var bundleId: String
    var frameWrite: WindowCapabilityProfile.FrameWriteReliability?
    var focusActivation: WindowCapabilityProfile.FocusActivationBehavior?
    var nfrReplacement: WindowCapabilityProfile.NativeFullscreenReplacement?
    var transient: WindowCapabilityProfile.TransientTreatment?
    var restore: WindowCapabilityProfile.RestoreHandling?

    func merged(onTopOf base: WindowCapabilityProfile) -> WindowCapabilityProfile {
        WindowCapabilityProfile(
            frameWrite: frameWrite ?? base.frameWrite,
            focusActivation: focusActivation ?? base.focusActivation,
            nfrReplacement: nfrReplacement ?? base.nfrReplacement,
            transient: transient ?? base.transient,
            restore: restore ?? base.restore
        )
    }
}

extension WindowCapabilityProfile.FrameWriteReliability: Codable {}
extension WindowCapabilityProfile.FocusActivationBehavior: Codable {}
extension WindowCapabilityProfile.NativeFullscreenReplacement: Codable {}
extension WindowCapabilityProfile.TransientTreatment: Codable {}
extension WindowCapabilityProfile.RestoreHandling: Codable {}
