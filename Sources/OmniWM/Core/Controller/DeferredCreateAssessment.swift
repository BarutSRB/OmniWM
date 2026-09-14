// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct DeferredCreateAssessment {
    let token: WindowToken
    let bundleId: String?
    let mode: TrackedWindowMode?
    let factsAreDeferred: Bool
    let facts: WindowRuleFacts
    let entry: WindowState?

    init(
        token: WindowToken,
        bundleId: String?,
        mode: TrackedWindowMode?,
        factsAreDeferred: Bool = false,
        facts: WindowRuleFacts,
        entry: WindowState?
    ) {
        self.token = token
        self.bundleId = bundleId
        self.mode = mode
        self.factsAreDeferred = factsAreDeferred
        self.facts = facts
        self.entry = entry
    }
}

struct WindowReadmissionTarget {
    let workspaceId: WorkspaceDescriptor.ID
    let mode: TrackedWindowMode
    let ruleEffects: ManagedWindowRuleEffects
}
