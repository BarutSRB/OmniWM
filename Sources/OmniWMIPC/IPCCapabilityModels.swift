// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

public struct IPCQueriesQueryResult: Codable, Equatable, Sendable {
    public let queries: [IPCQueryDescriptor]

    public init(queries: [IPCQueryDescriptor]) {
        self.queries = queries
    }
}

public struct IPCRuleActionsQueryResult: Codable, Equatable, Sendable {
    public let ruleActions: [IPCRuleActionDescriptor]

    public init(ruleActions: [IPCRuleActionDescriptor]) {
        self.ruleActions = ruleActions
    }
}

public struct IPCCommandsQueryResult: Codable, Equatable, Sendable {
    public let commands: [IPCCommandDescriptor]
    public let workspaceActions: [IPCWorkspaceActionDescriptor]
    public let windowActions: [IPCWindowActionDescriptor]

    public init(
        commands: [IPCCommandDescriptor],
        workspaceActions: [IPCWorkspaceActionDescriptor],
        windowActions: [IPCWindowActionDescriptor]
    ) {
        self.commands = commands
        self.workspaceActions = workspaceActions
        self.windowActions = windowActions
    }
}

public struct IPCSubscriptionsQueryResult: Codable, Equatable, Sendable {
    public let subscriptions: [IPCSubscriptionDescriptor]

    public init(subscriptions: [IPCSubscriptionDescriptor]) {
        self.subscriptions = subscriptions
    }
}

public struct IPCCapabilitiesQueryResult: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let appVersion: String?
    public let authorizationRequired: Bool
    public let windowIdScope: String
    public let queries: [IPCQueryDescriptor]
    public let commands: [IPCCommandDescriptor]
    public let captureActions: [IPCCaptureActionDescriptor]
    public let ruleActions: [IPCRuleActionDescriptor]
    public let workspaceActions: [IPCWorkspaceActionDescriptor]
    public let windowActions: [IPCWindowActionDescriptor]
    public let subscriptions: [IPCSubscriptionDescriptor]

    public init(
        protocolVersion: Int = OmniWMIPCProtocol.version,
        appVersion: String?,
        authorizationRequired: Bool,
        windowIdScope: String,
        queries: [IPCQueryDescriptor],
        commands: [IPCCommandDescriptor],
        captureActions: [IPCCaptureActionDescriptor],
        ruleActions: [IPCRuleActionDescriptor],
        workspaceActions: [IPCWorkspaceActionDescriptor],
        windowActions: [IPCWindowActionDescriptor],
        subscriptions: [IPCSubscriptionDescriptor]
    ) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.authorizationRequired = authorizationRequired
        self.windowIdScope = windowIdScope
        self.queries = queries
        self.commands = commands
        self.captureActions = captureActions
        self.ruleActions = ruleActions
        self.workspaceActions = workspaceActions
        self.windowActions = windowActions
        self.subscriptions = subscriptions
    }
}
