// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct AXFrameApplicationTarget: Sendable {
    let pid: pid_t
    let expectedWindow: AXWindowRef
    let frame: CGRect
    let components: AXFrameComponents

    var windowId: Int {
        expectedWindow.windowId
    }

    init(
        pid: pid_t,
        window: AXWindowRef,
        frame: CGRect,
        components: AXFrameComponents = .all
    ) {
        self.pid = pid
        expectedWindow = window
        self.frame = frame
        self.components = components
    }
}

struct AXClosingFrameTarget: Sendable {
    let animationId: UUID
    let pid: pid_t
    let expectedWindow: AXWindowRef
    let frame: CGRect
    let currentFrameHint: CGRect?

    var windowId: Int {
        expectedWindow.windowId
    }
}

struct SkyLightPositionTarget {
    let token: WindowToken
    let frame: CGRect
}

struct AXManagerPIDBufferRuntimeSnapshot: Equatable, Sendable {
    var currentSize = 0
    var highWater = 0
    var retainedCapacity = 0
}
