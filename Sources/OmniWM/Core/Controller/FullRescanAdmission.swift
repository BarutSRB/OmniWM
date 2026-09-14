// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

struct FullRescanEvaluatedWindow {
    let candidate: FullRescanWindowCandidate
    let identity: FullRescanCandidateIdentity
    let decision: FullRescanWindowDecision
}

struct FullRescanAdmissionAssignment {
    let workspaceId: WorkspaceDescriptor.ID
    let ruleEffects: ManagedWindowRuleEffects
    let admissionHints: ManagedWindowAdmissionHints
}

struct FullRescanAdmission {
    let assignment: FullRescanAdmissionAssignment
    let refreshedEntry: WindowState?
    let admittedMode: TrackedWindowMode
    let managedReplacementMetadata: ManagedReplacementMetadata
}
