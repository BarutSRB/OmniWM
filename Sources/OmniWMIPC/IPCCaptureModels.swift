// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

public enum IPCCaptureProfile: String, Codable, CaseIterable, Equatable, Sendable {
    case trace
    case performance
}

public enum IPCCapturePhase: String, Codable, CaseIterable, Equatable, Sendable {
    case idle
    case starting
    case recording
    case finalizing
}

public enum IPCCaptureActionName: String, Codable, CaseIterable, Equatable, Sendable {
    case start
    case stop
    case status
}

public enum IPCCaptureRequest: Equatable, Sendable {
    case start(IPCCaptureProfile)
    case stop
    case status

    public var name: IPCCaptureActionName {
        switch self {
        case .start:
            .start
        case .stop:
            .stop
        case .status:
            .status
        }
    }
}

extension IPCCaptureRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case name
        case profile
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(IPCCaptureActionName.self, forKey: .name)

        switch name {
        case .start:
            self = .start(try container.decode(IPCCaptureProfile.self, forKey: .profile))
        case .stop:
            self = .stop
        case .status:
            self = .status
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)

        if case let .start(profile) = self {
            try container.encode(profile, forKey: .profile)
        }
    }
}

public struct IPCCaptureArtifact: Codable, Equatable, Sendable {
    public let profile: IPCCaptureProfile
    public let path: String
    public let startedAt: String
    public let endedAt: String

    public init(profile: IPCCaptureProfile, path: String, startedAt: String, endedAt: String) {
        self.profile = profile
        self.path = path
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public struct IPCCaptureResult: Codable, Equatable, Sendable {
    public let phase: IPCCapturePhase
    public let profile: IPCCaptureProfile?
    public let startedAt: String?
    public let lastArtifact: IPCCaptureArtifact?
    public let failureReason: String?

    public init(
        phase: IPCCapturePhase,
        profile: IPCCaptureProfile? = nil,
        startedAt: String? = nil,
        lastArtifact: IPCCaptureArtifact? = nil,
        failureReason: String? = nil
    ) {
        self.phase = phase
        self.profile = profile
        self.startedAt = startedAt
        self.lastArtifact = lastArtifact
        self.failureReason = failureReason
    }
}
