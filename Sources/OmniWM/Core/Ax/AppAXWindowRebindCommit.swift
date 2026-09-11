// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

struct AppAXWindowRebindCommit: Sendable {
    let oldWindow: AXWindowRef
    let newWindow: AXWindowRef
    let destinationSubscription: AppAXWindowSubscription?
    let retireOldWindowState: Bool
    let binding: AppAXWindowRebindBinding
}
