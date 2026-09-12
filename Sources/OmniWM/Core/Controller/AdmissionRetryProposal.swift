// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct AdmissionRetryProposal {
    let expectedToken: WindowToken?
    let axRef: AXWindowRef?
    let reason: WindowAdmissionPendingReason
    let trigger: AdmissionRetryTrigger
    let preparedSubscriptionRetainContribution: Int
}
