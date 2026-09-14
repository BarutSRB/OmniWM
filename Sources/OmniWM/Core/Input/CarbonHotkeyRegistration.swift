// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@preconcurrency import AppKit
import Carbon
import Foundation
import IOKit.hidsystem

@MainActor
final class CarbonHotkeyRegistration {
    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var idToRegistration: [UInt32: HotkeyPlannedRegistration] = [:]
    private var pressedHotKeyIds: Set<UInt32> = []

    var count: Int {
        refs.count
    }

    func installEventHandler(center: HotkeyCenter) {
        var eventSpecs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return noErr }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            MainActor.assumeIsolated {
                center.handleCarbonHotkey(id: hotKeyID.id, kind: GetEventKind(event))
            }
            return noErr
        }
        let selfPtr = Unmanaged.passUnretained(center).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), callback, 2, &eventSpecs, selfPtr, &handler)
    }

    func register(
        _ registrations: [HotkeyPlannedRegistration],
        failures: inout [HotkeyCommand: HotkeyRegistrationFailureReason]
    ) {
        var nextId: UInt32 = 1
        for registration in registrations {
            guard failures[registration.command] == nil else {
                continue
            }
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x4F4D_4E49), id: nextId)
            let status = RegisterEventHotKey(
                registration.binding.keyCode,
                registration.binding.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                refs.append(ref)
                idToRegistration[nextId] = registration
            } else {
                failures[registration.command] = .systemReserved
                FallbackFiringRecorder.shared.note(.input, "hotkeyRegistrationFailed")
            }
            nextId += 1
        }
    }

    func handle(id: UInt32, kind: UInt32, onCommand: ((HotkeyInvocation) -> Void)?) {
        if kind == UInt32(kEventHotKeyReleased) {
            pressedHotKeyIds.remove(id)
        } else {
            let isRepeat = !pressedHotKeyIds.insert(id).inserted
            dispatch(id: id, isRepeat: isRepeat, onCommand: onCommand)
        }
    }

    func unregister() {
        for ref in refs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        refs.removeAll()
        idToRegistration.removeAll()
        pressedHotKeyIds.removeAll()
    }

    func removeEventHandler() {
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    private func dispatch(id: UInt32, isRepeat: Bool, onCommand: ((HotkeyInvocation) -> Void)?) {
        guard let registration = idToRegistration[id] else { return }
        InputTrace.record("hotkey.carbon cmd=\(registration.command.displayName)")
        onCommand?(
            HotkeyInvocation(
                command: registration.command,
                trigger: PhysicalHotkeyTrigger(
                    keyCode: registration.binding.keyCode,
                    modifiers: registration.binding.modifiers,
                    isRepeat: isRepeat
                )
            )
        )
    }
}
