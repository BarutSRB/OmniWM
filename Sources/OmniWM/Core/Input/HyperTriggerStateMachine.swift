// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@preconcurrency import AppKit
import Carbon
import Foundation
import IOKit.hidsystem

struct HyperTriggerStateMachine: Equatable {
    enum Decision: Equatable {
        case suppress
        case passThrough
        case inject
        case toggleCapsLock
    }

    private enum Trigger: Equatable {
        case none
        case key(UInt32)
        case capsLockF18
        case modifier(keyCode: UInt32, mask: UInt64)
        case mouseButton(Int64)
    }

    static let capsLockTapTimeout: TimeInterval = 0.3

    private let trigger: Trigger
    private(set) var isActive = false
    private var capsAlone = false
    private var capsDownTimestamp: TimeInterval?

    init(trigger: SystemHyperTrigger, capsLockRemapped: Bool) {
        guard trigger.isSupported else {
            self.trigger = .none
            return
        }
        switch trigger {
        case .none:
            self.trigger = .none
        case let .key(keyCode):
            if capsLockRemapped, keyCode == UInt32(kVK_CapsLock) {
                self.trigger = .capsLockF18
            } else if let mask = Self.modifierMask(for: keyCode) {
                self.trigger = .modifier(keyCode: keyCode, mask: mask)
            } else {
                self.trigger = .key(keyCode)
            }
        case let .mouseButton(button):
            self.trigger = .mouseButton(button)
        }
    }

    mutating func handleKeyDown(_ keyCode: UInt32, timestamp: TimeInterval = 0) -> Decision {
        handleKey(keyCode, isDown: true, timestamp: timestamp)
    }

    mutating func handleKeyUp(_ keyCode: UInt32, timestamp: TimeInterval = 0) -> Decision {
        handleKey(keyCode, isDown: false, timestamp: timestamp)
    }

    mutating func handleFlagsChanged(keyCode: UInt32, rawFlags: UInt64) -> Decision {
        guard case let .modifier(triggerKeyCode, mask) = trigger, keyCode == triggerKeyCode else {
            return .passThrough
        }
        isActive = rawFlags & mask != 0
        return .suppress
    }

    mutating func handleMouseDown(_ button: Int64) -> Decision {
        handleMouse(button, isDown: true)
    }

    mutating func handleMouseUp(_ button: Int64) -> Decision {
        handleMouse(button, isDown: false)
    }

    mutating func reset() {
        isActive = false
        capsAlone = false
        capsDownTimestamp = nil
    }

    private mutating func handleKey(_ keyCode: UInt32, isDown: Bool, timestamp: TimeInterval) -> Decision {
        switch trigger {
        case let .key(triggerKeyCode) where keyCode == triggerKeyCode:
            isActive = isDown
            return .suppress
        case .capsLockF18 where keyCode == CapsLockHyperMapping.f18KeyCode:
            if isDown {
                if !isActive {
                    capsAlone = true
                    capsDownTimestamp = timestamp
                }
                isActive = true
                return .suppress
            }
            let shouldToggle = isActive
                && capsAlone
                && timestamp - (capsDownTimestamp ?? timestamp) < Self.capsLockTapTimeout
            isActive = false
            capsAlone = false
            capsDownTimestamp = nil
            return shouldToggle ? .toggleCapsLock : .suppress
        default:
            if isActive, isDown {
                capsAlone = false
            }
            return isActive ? .inject : .passThrough
        }
    }

    private mutating func handleMouse(_ button: Int64, isDown: Bool) -> Decision {
        if case let .mouseButton(triggerButton) = trigger, button == triggerButton {
            isActive = isDown
            return .suppress
        }
        if case .capsLockF18 = trigger, isActive {
            if isDown {
                capsAlone = false
            }
            return .inject
        }
        return .passThrough
    }

    private static func modifierMask(for keyCode: UInt32) -> UInt64? {
        switch Int(keyCode) {
        case kVK_Shift:
            return UInt64(NX_DEVICELSHIFTKEYMASK)
        case kVK_RightShift:
            return UInt64(NX_DEVICERSHIFTKEYMASK)
        case kVK_Control:
            return UInt64(NX_DEVICELCTLKEYMASK)
        case kVK_RightControl:
            return UInt64(NX_DEVICERCTLKEYMASK)
        case kVK_Option:
            return UInt64(NX_DEVICELALTKEYMASK)
        case kVK_RightOption:
            return UInt64(NX_DEVICERALTKEYMASK)
        case kVK_Command:
            return UInt64(NX_DEVICELCMDKEYMASK)
        case kVK_RightCommand:
            return UInt64(NX_DEVICERCMDKEYMASK)
        default:
            return nil
        }
    }
}
