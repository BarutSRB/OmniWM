// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation

struct AppAXEnhancedUITiming {
    let probeNs: UInt64
    let disableNs: UInt64
    let restoreNs: UInt64
}

struct AppAXEnhancedUIWriteScope {
    private let axApp: AXUIElement
    private let key: CFString
    private let tracing: Bool
    let wasEnabled: Bool
    private let probeNs: UInt64
    private let disableNs: UInt64

    init(axApp: AXUIElement, pid: pid_t, tracing: Bool) {
        self.axApp = axApp
        self.tracing = tracing
        key = "AXEnhancedUserInterface" as CFString
        var enabled = false
        var value: CFTypeRef?
        let probeStartNs = tracing ? DispatchTime.now().uptimeNanoseconds : 0
        if let cached = LockedEnhancedUIStateMap.shared.state(for: pid) {
            enabled = cached
        } else {
            AppAXContextRuntimeMetrics.shared.noteEnhancedUICalls(1)
            if AXUIElementCopyAttributeValue(axApp, key, &value) == .success,
               let boolValue = value as? Bool
            {
                enabled = boolValue
                LockedEnhancedUIStateMap.shared.store(boolValue, for: pid)
            }
        }
        let probeEndNs = tracing ? DispatchTime.now().uptimeNanoseconds : 0
        wasEnabled = enabled
        let disableStartNs = tracing && enabled ? DispatchTime.now().uptimeNanoseconds : 0
        if enabled {
            AppAXContextRuntimeMetrics.shared.noteEnhancedUICalls(1)
            AXUIElementSetAttributeValue(axApp, key, kCFBooleanFalse)
        }
        let disableEndNs = tracing && enabled ? DispatchTime.now().uptimeNanoseconds : 0
        probeNs = AppAXFrameWriteTrace.elapsedNanoseconds(from: probeStartNs, to: probeEndNs)
        disableNs = AppAXFrameWriteTrace.elapsedNanoseconds(from: disableStartNs, to: disableEndNs)
    }

    func restore() -> AppAXEnhancedUITiming {
        let restoreStartNs = tracing && wasEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        if wasEnabled {
            AppAXContextRuntimeMetrics.shared.noteEnhancedUICalls(1)
            AXUIElementSetAttributeValue(axApp, key, kCFBooleanTrue)
        }
        let restoreEndNs = tracing && wasEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        return AppAXEnhancedUITiming(
            probeNs: probeNs,
            disableNs: disableNs,
            restoreNs: AppAXFrameWriteTrace.elapsedNanoseconds(from: restoreStartNs, to: restoreEndNs)
        )
    }
}
