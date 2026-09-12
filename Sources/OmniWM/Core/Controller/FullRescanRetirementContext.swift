// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation

struct FullRescanRetirementContext {
    let shouldPreserveMissingWindows: Bool
    let nativeFullscreenRetirementKeys: Set<WindowToken>
    let permitsMissingRetirement: Bool
}
