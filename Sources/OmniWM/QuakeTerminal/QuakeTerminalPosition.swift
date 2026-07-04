// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Cocoa

enum QuakeTerminalPosition: String, Codable, CaseIterable, Sendable {
    case top
    case bottom
    case left
    case right
    case center

    var displayName: String {
        rawValue.capitalized
    }

    @MainActor
    func setInitial(
        in window: NSWindow,
        on screen: NSScreen,
        widthPercent: Double,
        heightPercent: Double,
        closedFrame: NSRect? = nil
    ) {
        window.alphaValue = 0
        window.setFrame(.init(
            origin: initialOrigin(for: window, on: screen),
            size: closedFrame?.size ?? configuredFrameSize(
                on: screen,
                widthPercent: widthPercent,
                heightPercent: heightPercent
            )
        ), display: false)
    }

    @MainActor
    func setFinal(
        in window: NSWindow,
        on screen: NSScreen,
        widthPercent: Double,
        heightPercent: Double,
        closedFrame: NSRect? = nil
    ) {
        window.alphaValue = 1
        window.setFrame(.init(
            origin: finalOrigin(for: window, on: screen),
            size: closedFrame?.size ?? configuredFrameSize(
                on: screen,
                widthPercent: widthPercent,
                heightPercent: heightPercent
            )
        ), display: true)
    }

    func configuredFrameSize(on screen: NSScreen, widthPercent: Double, heightPercent: Double) -> NSSize {
        QuakeTerminalGeometryPolicy.configuredFrameSize(
            visibleFrame: screen.visibleFrame,
            widthPercent: widthPercent,
            heightPercent: heightPercent
        )
    }

    @MainActor
    func initialOrigin(for window: NSWindow, on screen: NSScreen) -> CGPoint {
        initialOrigin(visibleFrame: screen.visibleFrame, windowSize: window.frame.size)
    }

    func initialOrigin(visibleFrame: CGRect, windowSize: CGSize) -> CGPoint {
        switch self {
        case .top:
            return CGPoint(
                x: round(visibleFrame.origin.x + (visibleFrame.width - windowSize.width) / 2),
                y: visibleFrame.maxY
            )
        case .bottom:
            return CGPoint(
                x: round(visibleFrame.origin.x + (visibleFrame.width - windowSize.width) / 2),
                y: visibleFrame.minY - windowSize.height
            )
        case .left:
            return CGPoint(
                x: visibleFrame.minX - windowSize.width,
                y: round(visibleFrame.origin.y + (visibleFrame.height - windowSize.height) / 2)
            )
        case .right:
            return CGPoint(
                x: visibleFrame.maxX,
                y: round(visibleFrame.origin.y + (visibleFrame.height - windowSize.height) / 2)
            )
        case .center:
            return CGPoint(
                x: round(visibleFrame.origin.x + (visibleFrame.width - windowSize.width) / 2),
                y: round(visibleFrame.origin.y + (visibleFrame.height - windowSize.height) / 2)
            )
        }
    }

    @MainActor
    func finalOrigin(for window: NSWindow, on screen: NSScreen) -> CGPoint {
        finalOrigin(visibleFrame: screen.visibleFrame, windowSize: window.frame.size)
    }

    func finalOrigin(visibleFrame: CGRect, windowSize: CGSize) -> CGPoint {
        switch self {
        case .top:
            return CGPoint(
                x: round(visibleFrame.origin.x + (visibleFrame.width - windowSize.width) / 2),
                y: visibleFrame.maxY - windowSize.height
            )
        case .bottom:
            return CGPoint(
                x: round(visibleFrame.origin.x + (visibleFrame.width - windowSize.width) / 2),
                y: visibleFrame.minY
            )
        case .left:
            return CGPoint(
                x: visibleFrame.minX,
                y: round(visibleFrame.origin.y + (visibleFrame.height - windowSize.height) / 2)
            )
        case .right:
            return CGPoint(
                x: visibleFrame.maxX - windowSize.width,
                y: round(visibleFrame.origin.y + (visibleFrame.height - windowSize.height) / 2)
            )
        case .center:
            return CGPoint(
                x: round(visibleFrame.origin.x + (visibleFrame.width - windowSize.width) / 2),
                y: round(visibleFrame.origin.y + (visibleFrame.height - windowSize.height) / 2)
            )
        }
    }

    @MainActor
    func centeredOrigin(for window: NSWindow, on screen: NSScreen) -> CGPoint {
        let visibleFrame = screen.visibleFrame
        switch self {
        case .top,
             .bottom:
            return CGPoint(
                x: round(visibleFrame.origin.x + (visibleFrame.width - window.frame.width) / 2),
                y: window.frame.origin.y
            )
        case .center:
            return CGPoint(
                x: round(visibleFrame.origin.x + (visibleFrame.width - window.frame.width) / 2),
                y: round(visibleFrame.origin.y + (visibleFrame.height - window.frame.height) / 2)
            )
        case .left,
             .right:
            return window.frame.origin
        }
    }

    @MainActor
    func verticallyCenteredOrigin(for window: NSWindow, on screen: NSScreen) -> CGPoint {
        let visibleFrame = screen.visibleFrame
        switch self {
        case .left,
             .right:
            return CGPoint(
                x: window.frame.origin.x,
                y: round(visibleFrame.origin.y + (visibleFrame.height - window.frame.height) / 2)
            )
        case .top,
             .bottom,
             .center:
            return window.frame.origin
        }
    }
}
