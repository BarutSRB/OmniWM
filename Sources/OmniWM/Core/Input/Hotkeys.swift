import AppKit
import Carbon
import Foundation

final class HotkeyCenter {
    var onCommand: ((HotkeyCommand) -> Void)?

    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var isRunning = false
    private var idToCommand: [UInt32: HotkeyCommand] = [:]

    private var bindings: [HotkeyBinding] = []

    private(set) var registrationFailures: Set<HotkeyCommand> = []

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
        registrationFailures.removeAll()
        var nextId: UInt32 = 1

        for binding in bindings {
            if binding.binding.isUnassigned {
                continue
            }
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x4F4D_4E49), id: nextId)
            let status = RegisterEventHotKey(
                binding.binding.keyCode,
                binding.binding.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                refs.append(ref)
                idToCommand[nextId] = binding.command
            } else {
                registrationFailures.insert(binding.command)
                NSLog("HotkeyCenter: Failed to register hotkey for \(binding.command.displayName) (status: \(status))")
            }
            nextId += 1
        }
    }

    private func dispatch(id: UInt32) {
        guard let command = idToCommand[id] else { return }
        onCommand?(command)
    }
}
