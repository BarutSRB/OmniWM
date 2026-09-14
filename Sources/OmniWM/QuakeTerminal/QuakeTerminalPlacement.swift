// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit

@MainActor
struct QuakeTerminalPlacement {
    private let position: QuakeTerminalPosition
    private let screen: NSScreen
    private let widthPercent: Double
    private let heightPercent: Double

    init(position: QuakeTerminalPosition, on screen: NSScreen, widthPercent: Double, heightPercent: Double) {
        self.position = position
        self.screen = screen
        self.widthPercent = widthPercent
        self.heightPercent = heightPercent
    }

    func setInitial(in window: NSWindow) {
        window.alphaValue = 0
        let size = configuredFrameSize()
        window.setFrame(.init(
            origin: position.initialOrigin(visibleFrame: screen.visibleFrame, windowSize: size),
            size: size
        ), display: false)
    }

    func setFinal(in window: NSWindow) {
        window.alphaValue = 1
        let size = configuredFrameSize()
        window.setFrame(.init(
            origin: position.finalOrigin(visibleFrame: screen.visibleFrame, windowSize: size),
            size: size
        ), display: true)
    }

    private func configuredFrameSize() -> NSSize {
        QuakeTerminalGeometryPolicy.configuredFrameSize(
            visibleFrame: screen.visibleFrame,
            widthPercent: widthPercent,
            heightPercent: heightPercent
        )
    }
}
