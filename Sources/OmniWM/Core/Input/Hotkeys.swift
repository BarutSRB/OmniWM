// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Carbon
import Foundation

struct HotkeyPlannedRegistration: Equatable {
    let binding: KeyBinding
    let command: HotkeyCommand
}

enum HotkeyRegistrationFailureReason: Equatable {
    case duplicateBinding
    case systemReserved
}

struct HotkeyRegistrationPlan: Equatable {
    let registrations: [HotkeyPlannedRegistration]
    let failures: [HotkeyCommand: HotkeyRegistrationFailureReason]
}

final class HotkeyCenter {
    var onCommand: ((HotkeyCommand) -> Void)?

    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var isRunning = false
    private var idToCommand: [UInt32: HotkeyCommand] = [:]

    private var bindings: [HotkeyBinding] = []

    private(set) var registrationFailures: [HotkeyCommand: HotkeyRegistrationFailureReason] = [:]

    func start() {
        guard !isRunning else { return }
        isRunning = true

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
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
            center.dispatch(id: hotKeyID.id)
            return noErr
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventSpec, selfPtr, &handler)

        registerHotkeys()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        unregisterAll()
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    func updateBindings(_ newBindings: [HotkeyBinding]) {
        bindings = newBindings
        if isRunning {
            unregisterAll()
            registerHotkeys()
        }
    }

    private func unregisterAll() {
        for ref in refs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        refs.removeAll()
        idToCommand.removeAll()
    }

    private func registerHotkeys() {
        unregisterAll()
        let plan = Self.registrationPlan(for: bindings)
        registrationFailures = plan.failures
        var nextId: UInt32 = 1

        for registration in plan.registrations {
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
                idToCommand[nextId] = registration.command
            } else {
                registrationFailures[registration.command] = .systemReserved
            }
            nextId += 1
        }
    }

    private func dispatch(id: UInt32) {
        guard let command = idToCommand[id] else { return }
        onCommand?(command)
    }
}

extension HotkeyCenter {
    static func registrationPlan(for bindings: [HotkeyBinding]) -> HotkeyRegistrationPlan {
        var ownersByBinding: [KeyBinding: Set<HotkeyCommand>] = [:]
        var commandBindings: [(command: HotkeyCommand, binding: KeyBinding?)] = []

        for binding in bindings {
            let validBinding = binding.binding.isUnassigned ? nil : binding.binding
            if let validBinding {
                ownersByBinding[validBinding, default: []].insert(binding.command)
            }
            commandBindings.append((command: binding.command, binding: validBinding))
        }

        let conflictedBindings = Set(
            ownersByBinding.compactMap { binding, owners in
                owners.count > 1 ? binding : nil
            }
        )

        var registrations: [HotkeyPlannedRegistration] = []
        var failures: [HotkeyCommand: HotkeyRegistrationFailureReason] = [:]

        for commandBinding in commandBindings {
            if let binding = commandBinding.binding, conflictedBindings.contains(binding) {
                failures[commandBinding.command] = .duplicateBinding
                continue
            }

            if let binding = commandBinding.binding {
                registrations.append(
                    HotkeyPlannedRegistration(
                        binding: binding,
                        command: commandBinding.command
                    )
                )
            }
        }

        return HotkeyRegistrationPlan(registrations: registrations, failures: failures)
    }
}
