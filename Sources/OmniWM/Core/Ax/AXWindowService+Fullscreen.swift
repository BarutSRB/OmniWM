// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

extension AXWindowService {
    static func isSystemModalSurface(role: String?, subrole: String?) -> Bool {
        role == kAXSheetRole as String
            || subrole == kAXDialogSubrole as String
            || subrole == kAXSystemDialogSubrole as String
    }

    static func isSystemModalSurface(_ window: AXWindowRef) -> Bool {
        let attributes = roleAndSubrole(window)
        return isSystemModalSurface(role: attributes.role, subrole: attributes.subrole)
    }

    static func isFullscreen(_ window: AXWindowRef) -> Bool {
        isFullscreen(window, subrole: subrole(window))
    }

    static func isFullscreen(_ window: AXWindowRef, subrole: String?) -> Bool {
        MainThreadAXSpanTrace.measure(.readFullscreen, windowId: window.windowId) {
            if subrole == "AXFullScreenWindow" {
                return true
            }

            var value: CFTypeRef?
            let fullScreenAttribute = "AXFullScreen" as CFString
            let result = AXUIElementCopyAttributeValue(
                window.element,
                fullScreenAttribute,
                &value
            )
            if result == .success, let boolValue = value as? Bool {
                return boolValue
            }

            if let frame = try? frame(window) {
                return isFullscreenFrame(frame)
            }

            return false
        }
    }

    static func isFullscreenAttributeSet(_ window: AXWindowRef) -> Bool {
        MainThreadAXSpanTrace.measure(.readFullscreenAttribute, windowId: window.windowId) {
            if let subrole = subrole(window), subrole == "AXFullScreenWindow" {
                return true
            }

            var value: CFTypeRef?
            let fullScreenAttribute = "AXFullScreen" as CFString
            let result = AXUIElementCopyAttributeValue(
                window.element,
                fullScreenAttribute,
                &value
            )
            if result == .success, let boolValue = value as? Bool {
                return boolValue
            }

            return false
        }
    }

    static func setNativeFullscreen(_ window: AXWindowRef, fullscreen: Bool) -> Bool {
        MainThreadAXSpanTrace.measure(.setNativeFullscreen, windowId: window.windowId) {
            let fullScreenAttribute = "AXFullScreen" as CFString
            let result = AXUIElementSetAttributeValue(
                window.element,
                fullScreenAttribute,
                fullscreen as CFBoolean
            )
            return result == .success
        } succeeded: { $0 }
    }

    private static func isFullscreenFrame(_ frame: CGRect) -> Bool {
        let center = frame.center
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) else {
            return false
        }
        return frame.approximatelyEqual(to: screen.frame, tolerance: FrameTolerance.screenMatch)
    }
}
