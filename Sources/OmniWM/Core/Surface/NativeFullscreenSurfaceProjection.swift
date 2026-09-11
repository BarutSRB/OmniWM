// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct AcceptedNativeFullscreenSlotProjection {
    let displayId: CGDirectDisplayID
    let displayContext: NativeFullscreenDisplayContext
    let slots: [WindowToken: NativeFullscreenSlotProjection]
}

struct NativeFullscreenPlaceholderResolution {
    let update: NativeFullscreenPlaceholderUpdate
    let reason: NativeFullscreenPlaceholderTrace.Reason
}

struct NativeFullscreenSurfaceProjectionUpdate {
    let slots: [WindowToken: NativeFullscreenSlotProjection]
    let workspaceId: WorkspaceDescriptor.ID
    let displayId: CGDirectDisplayID
    let displayContext: NativeFullscreenDisplayContext
}
