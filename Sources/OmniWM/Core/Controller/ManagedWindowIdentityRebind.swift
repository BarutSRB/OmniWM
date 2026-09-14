// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

struct ManagedWindowIdentityRebind {
    let oldWindow: AXManagedWindowIdentity
    let newWindow: AXManagedWindowIdentity
    let managedReplacementMetadata: ManagedReplacementMetadata?
    let admissionHints: ManagedWindowAdmissionHints?
    let sizeConstraints: WindowSizeConstraints?
}
