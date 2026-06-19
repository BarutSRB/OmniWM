// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@preconcurrency import AppKit
import Carbon
import Foundation

struct HotkeyPlannedRegistration: Equatable {
    let binding: KeyBinding
    let command: HotkeyCommand

    init(binding: KeyBinding, command: HotkeyCommand) {
        self.binding = binding
        self.command = command
    }
}

enum HotkeyRegistrationFailureReason: Equatable {
    case duplicateBinding
    case systemReserved
    case requiresInputMonitoring
}

enum SystemHyperTriggerFailure: Equatable {
    case eventTapUnavailable
    case capsLockRemapUnavailable
}

struct HotkeyRegistrationPlan: Equatable {
    let registrations: [HotkeyPlannedRegistration]
    let sideSpecificRegistrations: [HotkeyPlannedRegistration]
    var failures: [HotkeyCommand: HotkeyRegistrationFailureReason]

    init(
        registrations: [HotkeyPlannedRegistration],
        sideSpecificRegistrations: [HotkeyPlannedRegistration] = [],
        failures: [HotkeyCommand: HotkeyRegistrationFailureReason]
    ) {
        self.registrations = registrations
        self.sideSpecificRegistrations = sideSpecificRegistrations
        self.failures = failures
    }
}

struct HotkeyRuntimeConfiguration: Equatable {
    let bindings: [HotkeyBinding]
    let systemHyperTrigger: SystemHyperTrigger

    init(bindings: [HotkeyBinding] = [], systemHyperTrigger: SystemHyperTrigger = .default) {
        self.bindings = bindings
        self.systemHyperTrigger = systemHyperTrigger
    }
}

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

@MainActor
final class HotkeyCenter {
    var onCommand: ((HotkeyCommand) -> Void)?

    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var isRunning = false
    private var commandHotkeysSuspended = false
    private var idToCommand: [UInt32: HotkeyCommand] = [:]

    private var configuration = HotkeyRuntimeConfiguration()
    private var sideSpecificDispatch: [CommandHotkeyTapMatcher.Entry] = []
    private var suppressedHotkeyKeyCodes: Set<UInt32> = []
    private var hyperTriggerTap: CFMachPort?
    private var hyperTriggerRunLoopSource: CFRunLoopSource?
    private var hyperTrigger = HyperTriggerStateMachine(trigger: .none, capsLockRemapped: false)
    private let capsLockHyperRemapper = CapsLockHyperRemapper()
    private let capsLockToggler = CapsLockToggler()
    private var capsLockHyperRemapActive = false

    private(set) var registrationFailures: [HotkeyCommand: HotkeyRegistrationFailureReason] = [:]
    private(set) var systemHyperTriggerFailure: SystemHyperTriggerFailure?

    private static let hyperFlagMask: UInt64 =
        CGEventFlags.maskCommand.rawValue |
        CGEventFlags.maskControl.rawValue |
        CGEventFlags.maskAlternate.rawValue |
        CGEventFlags.maskShift.rawValue

    var isHyperTriggerActive: Bool {
        hyperTrigger.isActive
    }

    deinit {
        MainActor.assumeIsolated {
            stopHyperTriggerTap()
            restoreCapsLockHyperRemap()
        }
    }

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
            MainActor.assumeIsolated {
                center.dispatch(id: hotKeyID.id)
            }
            return noErr
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventSpec, selfPtr, &handler)

        refreshCommandHotkeyRegistrations()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        unregisterCommandHotkeys()
        stopHyperTriggerTap()
        restoreCapsLockHyperRemap()
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    func setCommandHotkeysSuspended(_ suspended: Bool) {
        guard commandHotkeysSuspended != suspended else { return }
        commandHotkeysSuspended = suspended
        if isRunning {
            refreshCommandHotkeyRegistrations()
        }
    }

    func updateBindings(
        _ newBindings: [HotkeyBinding],
        systemHyperTrigger newSystemHyperTrigger: SystemHyperTrigger = .default,
        force: Bool = false
    ) {
        let nextConfiguration = HotkeyRuntimeConfiguration(
            bindings: newBindings,
            systemHyperTrigger: newSystemHyperTrigger
        )
        guard force || nextConfiguration != configuration else { return }
        configuration = nextConfiguration
        if isRunning {
            refreshCommandHotkeyRegistrations()
        }
    }

    private func unregisterCommandHotkeys() {
        for ref in refs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        refs.removeAll()
        idToCommand.removeAll()
    }

    private func reconcileEventTap() {
        stopHyperTriggerTap()
        restoreCapsLockHyperRemap()
        systemHyperTriggerFailure = nil
        hyperTrigger = HyperTriggerStateMachine(trigger: .none, capsLockRemapped: false)

        let hyperEnabled = configuration.systemHyperTrigger.isEnabled
        guard hyperEnabled || !sideSpecificDispatch.isEmpty else { return }

        if hyperEnabled {
            if activateCapsLockHyperRemapIfNeeded() {
                hyperTrigger = HyperTriggerStateMachine(
                    trigger: configuration.systemHyperTrigger,
                    capsLockRemapped: capsLockHyperRemapActive
                )
            } else {
                systemHyperTriggerFailure = .capsLockRemapUnavailable
            }
        }

        if !setupHyperTriggerTapIfNeeded() {
            if hyperEnabled {
                systemHyperTriggerFailure = .eventTapUnavailable
            }
            restoreCapsLockHyperRemap()
            hyperTrigger = HyperTriggerStateMachine(trigger: .none, capsLockRemapped: false)
        }
    }

    private func refreshCommandHotkeyRegistrations() {
        unregisterCommandHotkeys()
        let plan = Self.registrationPlan(for: configuration.bindings)
        registrationFailures = plan.failures

        guard !commandHotkeysSuspended else {
            sideSpecificDispatch = []
            reconcileEventTap()
            return
        }

        var nextId: UInt32 = 1
        for registration in plan.registrations {
            guard registrationFailures[registration.command] == nil else {
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
                idToCommand[nextId] = registration.command
            } else {
                registrationFailures[registration.command] = .systemReserved
            }
            nextId += 1
        }

        sideSpecificDispatch = plan.sideSpecificRegistrations.map {
            CommandHotkeyTapMatcher.Entry(binding: $0.binding, command: $0.command)
        }
        reconcileEventTap()
        if !sideSpecificDispatch.isEmpty, hyperTriggerTap == nil {
            for entry in sideSpecificDispatch {
                registrationFailures[entry.command] = .requiresInputMonitoring
            }
            sideSpecificDispatch = []
        }
    }

    private func dispatch(id: UInt32) {
        guard let command = idToCommand[id] else { return }
        onCommand?(command)
    }

    private func activateCapsLockHyperRemapIfNeeded() -> Bool {
        guard configuration.systemHyperTrigger.requiresCapsLockRemap else { return true }
        guard !capsLockHyperRemapActive else { return true }
        guard capsLockHyperRemapper.apply() else { return false }
        capsLockHyperRemapActive = true
        return true
    }

    private func restoreCapsLockHyperRemap() {
        guard capsLockHyperRemapActive else { return }
        capsLockHyperRemapper.restore()
        capsLockHyperRemapActive = false
    }

    private func setupHyperTriggerTapIfNeeded() -> Bool {
        if hyperTriggerTap != nil { return true }
        let eventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated {
                center.handleHyperTriggerEvent(type: type, event: event)
            }
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        hyperTriggerTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: selfPtr
        )
        guard let tap = hyperTriggerTap else { return false }
        hyperTriggerRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let source = hyperTriggerRunLoopSource else {
            hyperTriggerTap = nil
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func stopHyperTriggerTap() {
        hyperTrigger.reset()
        suppressedHotkeyKeyCodes.removeAll()
        if let source = hyperTriggerRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            hyperTriggerRunLoopSource = nil
        }
        if let tap = hyperTriggerTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            hyperTriggerTap = nil
        }
    }

    private func handleHyperTriggerEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout:
            if let tap = hyperTriggerTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            hyperTrigger.reset()
            suppressedHotkeyKeyCodes.removeAll()
            return Unmanaged.passUnretained(event)
        case .tapDisabledByUserInput:
            hyperTrigger.reset()
            suppressedHotkeyKeyCodes.removeAll()
            return Unmanaged.passUnretained(event)
        case .keyDown,
             .keyUp:
            return handleHyperTriggerKeyEvent(type: type, event: event)
        case .flagsChanged:
            return handleHyperTriggerFlagsChanged(event)
        case .otherMouseDown,
             .otherMouseUp:
            return handleHyperTriggerMouseEvent(type: type, event: event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleHyperTriggerKeyEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let timestamp = TimeInterval(event.timestamp) / 1_000_000_000
        switch type {
        case .keyDown:
            switch hyperTrigger.handleKeyDown(keyCode, timestamp: timestamp) {
            case .suppress:
                return nil
            case .toggleCapsLock:
                capsLockToggler.toggle()
                return nil
            case .inject:
                injectHyperFlags(into: event)
            case .passThrough:
                break
            }
            if suppressedHotkeyKeyCodes.contains(keyCode) {
                return nil
            }
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
               let command = CommandHotkeyTapMatcher.match(
                   keyCode: keyCode,
                   rawFlags: event.flags.rawValue,
                   entries: sideSpecificDispatch
               )
            {
                suppressedHotkeyKeyCodes.insert(keyCode)
                onCommand?(command)
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .keyUp:
            if suppressedHotkeyKeyCodes.remove(keyCode) != nil {
                return nil
            }
            return applyHyperTriggerDecision(
                hyperTrigger.handleKeyUp(keyCode, timestamp: timestamp),
                to: event
            )
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleHyperTriggerFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        return applyHyperTriggerDecision(
            hyperTrigger.handleFlagsChanged(keyCode: keyCode, rawFlags: event.flags.rawValue),
            to: event
        )
    }

    private func handleHyperTriggerMouseEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        switch type {
        case .otherMouseDown:
            return applyHyperTriggerDecision(hyperTrigger.handleMouseDown(button), to: event)
        case .otherMouseUp:
            return applyHyperTriggerDecision(hyperTrigger.handleMouseUp(button), to: event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func applyHyperTriggerDecision(
        _ decision: HyperTriggerStateMachine.Decision,
        to event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        switch decision {
        case .suppress:
            return nil
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .inject:
            injectHyperFlags(into: event)
            return Unmanaged.passUnretained(event)
        case .toggleCapsLock:
            capsLockToggler.toggle()
            return nil
        }
    }

    private func injectHyperFlags(into event: CGEvent) {
        event.flags = CGEventFlags(rawValue: event.flags.rawValue | Self.hyperFlagMask)
    }

    nonisolated static func eventTapAccessGranted() -> Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    nonisolated static func requestEventTapAccess() -> Bool {
        CGRequestListenEventAccess()
    }

    nonisolated static func registrationPlan(for bindings: [HotkeyBinding]) -> HotkeyRegistrationPlan {
        var candidates: [(command: HotkeyCommand, binding: KeyBinding)] = []
        for binding in bindings {
            guard case let .chord(keyBinding) = binding.binding, !keyBinding.isUnassigned else { continue }
            candidates.append((binding.command, keyBinding))
        }

        var failures: [HotkeyCommand: HotkeyRegistrationFailureReason] = [:]
        for index in candidates.indices {
            let overlaps = candidates.indices.contains { other in
                other != index && candidates[index].binding.conflicts(with: candidates[other].binding)
            }
            if overlaps {
                failures[candidates[index].command] = .duplicateBinding
            }
        }

        let registrable = candidates.filter { failures[$0.command] == nil }
        let registrations = registrable
            .filter { $0.binding.sidedModifiers.isEmpty }
            .map { HotkeyPlannedRegistration(binding: $0.binding, command: $0.command) }
        let sideSpecific = registrable
            .filter { !$0.binding.sidedModifiers.isEmpty }
            .map { HotkeyPlannedRegistration(binding: $0.binding, command: $0.command) }

        return HotkeyRegistrationPlan(
            registrations: registrations,
            sideSpecificRegistrations: sideSpecific,
            failures: failures
        )
    }
}
