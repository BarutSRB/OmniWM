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
    case hyperTriggerConflict
    case unsupportedHyperModifiers
    case eventTapUnavailable
    case capsLockRemapUnavailable
    case systemReserved
}

struct HotkeyRegistrationPlan: Equatable {
    let registrations: [HotkeyPlannedRegistration]
    let virtualHyperRegistrations: [HotkeyPlannedRegistration]
    var failures: [HotkeyCommand: HotkeyRegistrationFailureReason]
}

struct HotkeyRuntimeConfiguration: Equatable {
    let bindings: [HotkeyBinding]
    let hyperTrigger: HyperKeyTrigger
    let hyperKeyHoldThresholdMilliseconds: Int

    init(
        bindings: [HotkeyBinding] = [],
        hyperTrigger: HyperKeyTrigger = .default,
        hyperKeyHoldThresholdMilliseconds: Int = 150
    ) {
        self.bindings = bindings
        self.hyperTrigger = hyperTrigger
        self.hyperKeyHoldThresholdMilliseconds = max(0, min(1500, hyperKeyHoldThresholdMilliseconds))
    }
}

enum VirtualHyperKeyDownDecision: Equatable {
    case passThrough
    case suppress
    case dispatch(HotkeyCommand)
}

struct SmallValueSet<Element: Equatable>: Equatable {
    private var first: Element?
    private var second: Element?
    private var third: Element?
    private var fourth: Element?
    private var overflow: [Element] = []

    var isEmpty: Bool {
        first == nil && second == nil && third == nil && fourth == nil && overflow.isEmpty
    }

    mutating func reserveCapacity(_ capacity: Int) {
        overflow.reserveCapacity(max(0, capacity - 4))
    }

    func contains(_ value: Element) -> Bool {
        first == value || second == value || third == value || fourth == value || overflow.contains(value)
    }

    mutating func insert(_ value: Element) {
        guard !contains(value) else { return }
        if first == nil {
            first = value
        } else if second == nil {
            second = value
        } else if third == nil {
            third = value
        } else if fourth == nil {
            fourth = value
        } else {
            overflow.append(value)
        }
    }

    @discardableResult
    mutating func remove(_ value: Element) -> Element? {
        if first == value {
            first = nil
            return value
        }
        if second == value {
            second = nil
            return value
        }
        if third == value {
            third = nil
            return value
        }
        if fourth == value {
            fourth = nil
            return value
        }
        guard let index = overflow.firstIndex(of: value) else { return nil }
        return overflow.remove(at: index)
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        first = nil
        second = nil
        third = nil
        fourth = nil
        overflow.removeAll(keepingCapacity: keepingCapacity)
    }
}

struct VirtualHyperEventState: Equatable {
    private enum PendingTrigger: Equatable {
        case key(UInt32)
        case mouseButton(Int64)
    }

    var isActive = false
    var consumedKeyCodes = SmallValueSet<UInt32>()
    var consumedMouseButtons = SmallValueSet<Int64>()
    private var pendingTrigger: PendingTrigger?

    var isPending: Bool {
        pendingTrigger != nil
    }

    mutating func reset() {
        isActive = false
        pendingTrigger = nil
        consumedKeyCodes.removeAll(keepingCapacity: true)
        consumedMouseButtons.removeAll(keepingCapacity: true)
    }

    func pendingKeyMatches(_ keyCode: UInt32, trigger: HyperKeyTrigger) -> Bool {
        guard trigger.keyboardKeyCode == keyCode,
              case let .key(pendingKeyCode) = pendingTrigger
        else { return false }
        return pendingKeyCode == keyCode
    }

    func pendingMouseButtonMatches(_ button: Int64, trigger: HyperKeyTrigger) -> Bool {
        guard trigger.mouseButtonNumber == button,
              case let .mouseButton(pendingButton) = pendingTrigger
        else { return false }
        return pendingButton == button
    }

    mutating func beginPendingKeyDown(_ keyCode: UInt32, trigger: HyperKeyTrigger) -> Bool {
        guard trigger.keyboardKeyCode == keyCode,
              pendingTrigger == nil,
              !isActive
        else { return false }
        pendingTrigger = .key(keyCode)
        consumedKeyCodes.insert(keyCode)
        return true
    }

    mutating func beginPendingMouseDown(_ button: Int64, trigger: HyperKeyTrigger) -> Bool {
        guard trigger.mouseButtonNumber == button,
              pendingTrigger == nil,
              !isActive
        else { return false }
        pendingTrigger = .mouseButton(button)
        consumedMouseButtons.insert(button)
        return true
    }

    mutating func promotePending() -> Bool {
        guard pendingTrigger != nil else { return false }
        pendingTrigger = nil
        isActive = true
        return true
    }

    mutating func cancelPending() -> Bool {
        guard let pendingTrigger else { return false }
        switch pendingTrigger {
        case let .key(keyCode):
            consumedKeyCodes.remove(keyCode)
        case let .mouseButton(button):
            consumedMouseButtons.remove(button)
        }
        self.pendingTrigger = nil
        return true
    }

    mutating func handleTriggerMouseDown(_ button: Int64, trigger: HyperKeyTrigger) -> Bool {
        guard trigger.mouseButtonNumber == button else { return false }
        pendingTrigger = nil
        isActive = true
        consumedMouseButtons.insert(button)
        return true
    }

    mutating func handleTriggerMouseUp(_ button: Int64, trigger: HyperKeyTrigger) -> Bool {
        guard trigger.mouseButtonNumber == button else {
            return consumedMouseButtons.remove(button) != nil
        }
        isActive = false
        consumedMouseButtons.remove(button)
        return true
    }

    mutating func handleTriggerKeyDown(_ keyCode: UInt32, trigger: HyperKeyTrigger) -> Bool {
        guard trigger.keyboardKeyCode == keyCode else { return false }
        pendingTrigger = nil
        isActive = true
        consumedKeyCodes.insert(keyCode)
        return true
    }

    mutating func handleTriggerKeyUp(_ keyCode: UInt32, trigger: HyperKeyTrigger) -> Bool {
        guard trigger.keyboardKeyCode == keyCode else {
            return consumedKeyCodes.remove(keyCode) != nil
        }
        isActive = false
        consumedKeyCodes.remove(keyCode)
        return true
    }

    mutating func handleTriggerFlagsChanged(
        keyCode: UInt32,
        flags: CGEventFlags,
        trigger: HyperKeyTrigger
    ) -> Bool {
        guard trigger.keyboardKeyCode == keyCode else { return false }

        if let modifierActive = Self.modifierFlagIsActive(for: keyCode, flags: flags) {
            if consumedKeyCodes.contains(keyCode) {
                isActive = false
            } else {
                isActive = modifierActive
            }
        } else if keyCode == UInt32(kVK_CapsLock) {
            isActive = flags.contains(.maskAlphaShift)
        } else {
            isActive = true
        }

        if isActive {
            consumedKeyCodes.insert(keyCode)
        } else {
            consumedKeyCodes.remove(keyCode)
        }
        return true
    }

    mutating func consumeKeyCode(_ keyCode: UInt32) {
        consumedKeyCodes.insert(keyCode)
    }

    mutating func handleKeyDown(
        keyCode: UInt32,
        isAutorepeat: Bool,
        trigger: HyperKeyTrigger,
        command: HotkeyCommand?
    ) -> VirtualHyperKeyDownDecision {
        if handleTriggerKeyDown(keyCode, trigger: trigger) {
            return .suppress
        }
        guard isActive else {
            return consumedKeyCodes.contains(keyCode) ? .suppress : .passThrough
        }

        guard let command else {
            return .passThrough
        }
        if isAutorepeat {
            return .suppress
        }
        consumeKeyCode(keyCode)
        return .dispatch(command)
    }

    private static func modifierFlagIsActive(for keyCode: UInt32, flags: CGEventFlags) -> Bool? {
        guard let mask = modifierMask(for: keyCode) else { return nil }
        return flags.rawValue & mask != 0
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
    var virtualHyperTapSetupOverride: (() -> Bool)?

    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var isRunning = false
    private var idToCommand: [UInt32: HotkeyCommand] = [:]

    private var configuration = HotkeyRuntimeConfiguration()
    private var pendingCommands: [HotkeyCommand] = []
    private var pendingCommandDrainScheduled = false
    private struct EventTapHandle {
        let port: CFMachPort
        let source: CFRunLoopSource
    }

    private var virtualHyperRegistrations: [KeyBinding: HotkeyCommand] = [:]
    private var virtualHyperIdleTap: EventTapHandle?
    private var virtualHyperEngagedTap: EventTapHandle?
    private var virtualHyperTapEngaged = false
    private var virtualHyperState = VirtualHyperEventState()
    private var pendingVirtualHyperDownEvent: CGEvent?
    private var virtualHyperHoldWorkItem: DispatchWorkItem?
    private let capsLockHyperRemapper = CapsLockHyperRemapper()
    private var capsLockHyperRemapActive = false

    private(set) var registrationFailures: [HotkeyCommand: HotkeyRegistrationFailureReason] = [:]

    private nonisolated static let virtualHyperReplayEventUserData: Int64 = 0x4F4D_4E49_5648_5950

    deinit {
        MainActor.assumeIsolated {
            stopVirtualHyperTap()
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

    func updateBindings(
        _ newBindings: [HotkeyBinding],
        hyperTrigger newHyperTrigger: HyperKeyTrigger = .default,
        hyperKeyHoldThresholdMilliseconds newHyperKeyHoldThresholdMilliseconds: Int = 150,
        force: Bool = false
    ) {
        let nextConfiguration = HotkeyRuntimeConfiguration(
            bindings: newBindings,
            hyperTrigger: newHyperTrigger,
            hyperKeyHoldThresholdMilliseconds: newHyperKeyHoldThresholdMilliseconds
        )
        guard force || nextConfiguration != configuration else { return }
        configuration = nextConfiguration
        if isRunning {
            registerHotkeys()
        }
    }

    private func unregisterAll() {
        for ref in refs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        refs.removeAll()
        idToCommand.removeAll()
        pendingCommands.removeAll()
        pendingCommandDrainScheduled = false
        virtualHyperRegistrations.removeAll()
        stopVirtualHyperTap()
        restoreCapsLockHyperRemap()
    }

    private func registerHotkeys() {
        unregisterAll()
        let plan = Self.registrationPlan(
            for: configuration.bindings,
            hyperTrigger: configuration.hyperTrigger
        )
        virtualHyperRegistrations = Dictionary(
            plan.virtualHyperRegistrations.map { ($0.binding, $0.command) },
            uniquingKeysWith: { first, _ in first }
        )
        registrationFailures = plan.failures
        let needsSemanticHyperTap = configuration.hyperTrigger.requiresEventTap &&
            (!virtualHyperRegistrations.isEmpty || configuration.hyperTrigger.requiresCapsLockRemap)
        if needsSemanticHyperTap {
            if !activateCapsLockHyperRemapIfNeeded() {
                markVirtualHyperUnavailable(.capsLockRemapUnavailable)
            } else if !setupVirtualHyperTapIfNeeded() {
                markVirtualHyperUnavailable(.eventTapUnavailable)
                restoreCapsLockHyperRemap()
            }
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
                markSystemReservedFailure(for: registration.command)
            }
            nextId += 1
        }
    }

    private func dispatch(id: UInt32) {
        guard let command = idToCommand[id] else { return }
        onCommand?(command)
    }

    private func markSystemReservedFailure(for command: HotkeyCommand) {
        registrationFailures[command] = .systemReserved
    }

    private func markVirtualHyperUnavailable(_ reason: HotkeyRegistrationFailureReason) {
        let commands = Array(virtualHyperRegistrations.values)
        virtualHyperRegistrations.removeAll()
        for command in commands {
            markVirtualHyperUnavailable(for: command, reason: reason)
        }
    }

    private func markVirtualHyperUnavailable(for command: HotkeyCommand, reason: HotkeyRegistrationFailureReason) {
        if registrationFailures[command] == nil {
            registrationFailures[command] = reason
        }
    }

    private var effectiveHyperTrigger: HyperKeyTrigger {
        if capsLockHyperRemapActive, configuration.hyperTrigger.requiresCapsLockRemap {
            return .key(CapsLockHyperMapping.f18KeyCode)
        }
        return configuration.hyperTrigger
    }

    private func activateCapsLockHyperRemapIfNeeded() -> Bool {
        guard configuration.hyperTrigger.requiresCapsLockRemap else { return true }
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

    private var virtualHyperIdleEventMask: CGEventMask {
        let trigger = effectiveHyperTrigger
        if trigger.mouseButtonNumber != nil {
            return CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
        }
        if let keyCode = trigger.keyboardKeyCode, !Self.isModifierKeyCode(keyCode) {
            return CGEventMask(1 << CGEventType.keyDown.rawValue)
        }
        return CGEventMask(1 << CGEventType.flagsChanged.rawValue)
    }

    private var virtualHyperEngagedEventMask: CGEventMask {
        var mask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue) |
                (1 << CGEventType.keyUp.rawValue) |
                (1 << CGEventType.flagsChanged.rawValue)
        )
        if effectiveHyperTrigger.mouseButtonNumber != nil {
            mask |= CGEventMask(
                (1 << CGEventType.otherMouseDown.rawValue) |
                    (1 << CGEventType.otherMouseUp.rawValue)
            )
        }
        return mask
    }

    private func setupVirtualHyperTapIfNeeded() -> Bool {
        if virtualHyperIdleTap != nil { return true }
        if let virtualHyperTapSetupOverride {
            return virtualHyperTapSetupOverride()
        }
        guard let idleTap = makeVirtualHyperTap(mask: virtualHyperIdleEventMask),
              let engagedTap = makeVirtualHyperTap(mask: virtualHyperEngagedEventMask)
        else {
            teardownVirtualHyperTap(virtualHyperIdleTap)
            virtualHyperIdleTap = nil
            return false
        }
        virtualHyperIdleTap = idleTap
        virtualHyperEngagedTap = engagedTap
        virtualHyperTapEngaged = false
        reassertVirtualHyperTapEnablement()
        return true
    }

    private func makeVirtualHyperTap(mask: CGEventMask) -> EventTapHandle? {
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated {
                center.handleVirtualHyperEvent(type: type, event: event)
            }
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        ),
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        else {
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return EventTapHandle(port: port, source: source)
    }

    private var isVirtualHyperEngaged: Bool {
        virtualHyperState.isActive || virtualHyperState.isPending ||
            !virtualHyperState.consumedKeyCodes.isEmpty ||
            !virtualHyperState.consumedMouseButtons.isEmpty
    }

    private func syncVirtualHyperTapEngagement() {
        guard virtualHyperIdleTap != nil, virtualHyperEngagedTap != nil else { return }
        let shouldEngage = isVirtualHyperEngaged
        guard shouldEngage != virtualHyperTapEngaged else { return }
        virtualHyperTapEngaged = shouldEngage
        reassertVirtualHyperTapEnablement()
    }

    private func reassertVirtualHyperTapEnablement() {
        guard let idleTap = virtualHyperIdleTap, let engagedTap = virtualHyperEngagedTap else { return }
        CGEvent.tapEnable(tap: engagedTap.port, enable: virtualHyperTapEngaged)
        CGEvent.tapEnable(tap: idleTap.port, enable: !virtualHyperTapEngaged)
    }

    private func teardownVirtualHyperTap(_ handle: EventTapHandle?) {
        guard let handle else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), handle.source, .commonModes)
        CGEvent.tapEnable(tap: handle.port, enable: false)
    }

    private func stopVirtualHyperTap() {
        resetVirtualHyperState()
        teardownVirtualHyperTap(virtualHyperIdleTap)
        teardownVirtualHyperTap(virtualHyperEngagedTap)
        virtualHyperIdleTap = nil
        virtualHyperEngagedTap = nil
        virtualHyperTapEngaged = false
    }

    private func dispatchCommandLater(_ command: HotkeyCommand) {
        pendingCommands.append(command)
        guard !pendingCommandDrainScheduled else { return }
        pendingCommandDrainScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.drainPendingCommands()
        }
    }

    private func drainPendingCommands() {
        pendingCommandDrainScheduled = false
        var index = 0
        while index < pendingCommands.count {
            let command = pendingCommands[index]
            index += 1
            onCommand?(command)
        }
        pendingCommands.removeAll(keepingCapacity: true)
    }

    private func handleVirtualHyperEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let result = processVirtualHyperEvent(type: type, event: event)
        syncVirtualHyperTapEngagement()
        return result
    }

    private func processVirtualHyperEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if Self.isSyntheticVirtualHyperReplayEvent(event) {
            return Unmanaged.passUnretained(event)
        }
        switch type {
        case .tapDisabledByTimeout:
            reassertVirtualHyperTapEnablement()
            return Unmanaged.passUnretained(event)
        case .tapDisabledByUserInput:
            resetVirtualHyperState()
            return Unmanaged.passUnretained(event)
        case .otherMouseDown:
            return handleVirtualHyperMouseDown(event)
        case .otherMouseUp:
            return handleVirtualHyperMouseUp(event)
        case .keyDown:
            return handleVirtualHyperKeyDown(event)
        case .keyUp:
            return handleVirtualHyperKeyUp(event)
        case .flagsChanged:
            return handleVirtualHyperFlagsChanged(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleVirtualHyperMouseDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        let trigger = effectiveHyperTrigger
        if configuration.hyperKeyHoldThresholdMilliseconds > 0 {
            if virtualHyperState.pendingMouseButtonMatches(button, trigger: trigger) {
                return nil
            }
            if virtualHyperState.beginPendingMouseDown(button, trigger: trigger) {
                pendingVirtualHyperDownEvent = event.copy()
                scheduleVirtualHyperHoldPromotion()
                return nil
            }
        }
        if virtualHyperState.isPending {
            promotePendingVirtualHyper()
        }
        guard virtualHyperState.handleTriggerMouseDown(button, trigger: trigger) else {
            return Unmanaged.passUnretained(event)
        }
        return nil
    }

    private func handleVirtualHyperMouseUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        let trigger = effectiveHyperTrigger
        if virtualHyperState.pendingMouseButtonMatches(button, trigger: trigger) {
            finishPendingVirtualHyperTap(releaseEvent: event)
            return nil
        }
        return virtualHyperState.handleTriggerMouseUp(button, trigger: trigger)
            ? nil
            : Unmanaged.passUnretained(event)
    }

    private func handleVirtualHyperKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let trigger = effectiveHyperTrigger
        if configuration.hyperKeyHoldThresholdMilliseconds > 0 {
            if virtualHyperState.pendingKeyMatches(keyCode, trigger: trigger) {
                return nil
            }
            if virtualHyperState.beginPendingKeyDown(keyCode, trigger: trigger) {
                pendingVirtualHyperDownEvent = event.copy()
                scheduleVirtualHyperHoldPromotion()
                return nil
            }
        }
        if virtualHyperState.isPending {
            promotePendingVirtualHyper()
        }
        let modifiers = matchingModifiers(from: event.flags)
        let command = virtualHyperState.isActive
            ? virtualHyperRegistrations[KeyBinding(keyCode: keyCode, modifiers: modifiers, usesHyper: true)]
            : nil
        let decision = virtualHyperState.handleKeyDown(
            keyCode: keyCode,
            isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            trigger: trigger,
            command: command
        )
        switch decision {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .suppress:
            return nil
        case let .dispatch(command):
            dispatchCommandLater(command)
            return nil
        }
    }

    private func handleVirtualHyperKeyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let trigger = effectiveHyperTrigger
        if virtualHyperState.pendingKeyMatches(keyCode, trigger: trigger) {
            finishPendingVirtualHyperTap(releaseEvent: event)
            return nil
        }
        return virtualHyperState.handleTriggerKeyUp(keyCode, trigger: trigger)
            ? nil
            : Unmanaged.passUnretained(event)
    }

    private func handleVirtualHyperFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let trigger = effectiveHyperTrigger
        let sourceIsModifier = Self.isModifierKeyCode(keyCode) && trigger.keyboardKeyCode == keyCode
        if configuration.hyperKeyHoldThresholdMilliseconds > 0,
           trigger.keyboardKeyCode == keyCode
        {
            let isPressed = Self.flagsChangedTriggerIsPressed(keyCode: keyCode, flags: event.flags)
            if virtualHyperState.pendingKeyMatches(keyCode, trigger: trigger) {
                if isPressed {
                    return sourceIsModifier ? Unmanaged.passUnretained(event) : nil
                }
                finishPendingVirtualHyperTap(releaseEvent: event)
                return sourceIsModifier ? Unmanaged.passUnretained(event) : nil
            }
            if isPressed,
               virtualHyperState.beginPendingKeyDown(keyCode, trigger: trigger)
            {
                pendingVirtualHyperDownEvent = event.copy()
                scheduleVirtualHyperHoldPromotion()
                return sourceIsModifier ? Unmanaged.passUnretained(event) : nil
            }
        }
        if virtualHyperState.isPending {
            promotePendingVirtualHyper()
        }
        guard virtualHyperState.handleTriggerFlagsChanged(keyCode: keyCode, flags: event.flags, trigger: trigger) else {
            return Unmanaged.passUnretained(event)
        }
        return sourceIsModifier ? Unmanaged.passUnretained(event) : nil
    }

    private func scheduleVirtualHyperHoldPromotion() {
        virtualHyperHoldWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.promotePendingVirtualHyper()
        }
        virtualHyperHoldWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(configuration.hyperKeyHoldThresholdMilliseconds),
            execute: item
        )
    }

    private func promotePendingVirtualHyper() {
        guard virtualHyperState.promotePending() else { return }
        virtualHyperHoldWorkItem?.cancel()
        virtualHyperHoldWorkItem = nil
        pendingVirtualHyperDownEvent = nil
    }

    private func finishPendingVirtualHyperTap(releaseEvent: CGEvent) {
        virtualHyperHoldWorkItem?.cancel()
        virtualHyperHoldWorkItem = nil
        guard shouldReplayPendingVirtualHyperTap else {
            _ = virtualHyperState.cancelPending()
            pendingVirtualHyperDownEvent = nil
            return
        }
        guard virtualHyperState.cancelPending(),
              let down = pendingVirtualHyperDownEvent,
              let up = releaseEvent.copy()
        else {
            pendingVirtualHyperDownEvent = nil
            return
        }
        pendingVirtualHyperDownEvent = nil
        Self.markSyntheticVirtualHyperReplayEvent(down)
        Self.markSyntheticVirtualHyperReplayEvent(up)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    private var shouldReplayPendingVirtualHyperTap: Bool {
        let trigger = effectiveHyperTrigger
        if capsLockHyperRemapActive {
            return false
        }
        guard let keyCode = trigger.keyboardKeyCode else {
            return trigger.mouseButtonNumber != nil
        }
        return !Self.isModifierKeyCode(keyCode)
    }

    private func resetVirtualHyperState() {
        virtualHyperHoldWorkItem?.cancel()
        virtualHyperHoldWorkItem = nil
        pendingVirtualHyperDownEvent = nil
        virtualHyperState.reset()
    }

    private func matchingModifiers(from flags: CGEventFlags) -> UInt32 {
        Self.carbonModifiers(from: flags) & ~effectiveHyperTrigger.modifierMaskToExclude
    }

    private static func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
        return modifiers
    }

    private nonisolated static func markSyntheticVirtualHyperReplayEvent(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: virtualHyperReplayEventUserData)
    }

    private nonisolated static func isSyntheticVirtualHyperReplayEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == virtualHyperReplayEventUserData
    }

    private nonisolated static func flagsChangedTriggerIsPressed(keyCode: UInt32, flags: CGEventFlags) -> Bool {
        if let modifierActive = modifierFlagIsActive(for: keyCode, rawFlags: flags.rawValue) {
            return modifierActive
        }
        switch Int(keyCode) {
        case kVK_CapsLock:
            return flags.contains(.maskAlphaShift)
        default:
            return true
        }
    }

    private nonisolated static func isModifierKeyCode(_ keyCode: UInt32) -> Bool {
        modifierMask(for: keyCode) != nil
    }

    private nonisolated static func modifierMask(for keyCode: UInt32) -> UInt64? {
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

    private nonisolated static func modifierFlagIsActive(for keyCode: UInt32, rawFlags: UInt64) -> Bool? {
        guard let mask = modifierMask(for: keyCode) else { return nil }
        return rawFlags & mask != 0
    }
}

extension HotkeyCenter {
    nonisolated static func eventTapAccessGranted() -> Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    nonisolated static func requestEventTapAccess() -> Bool {
        CGRequestListenEventAccess()
    }

    nonisolated static func registrationPlan(
        for bindings: [HotkeyBinding],
        hyperTrigger: HyperKeyTrigger = .default
    ) -> HotkeyRegistrationPlan {
        struct DirectCandidate {
            let command: HotkeyCommand
            let binding: KeyBinding
        }

        var directOwners: [KeyBinding: [HotkeyCommand]] = [:]
        var directCandidates: [DirectCandidate] = []
        var failures: [HotkeyCommand: HotkeyRegistrationFailureReason] = [:]

        func mark(_ command: HotkeyCommand, _ reason: HotkeyRegistrationFailureReason) {
            if failures[command] == nil {
                failures[command] = reason
            }
        }

        func usesUnsupportedHyperModifiers(_ binding: KeyBinding) -> Bool {
            guard binding.usesHyper else { return false }
            if hyperTrigger == .system {
                return binding.modifiers != 0
            }
            let excludedModifiers = hyperTrigger.modifierMaskToExclude
            return excludedModifiers != 0 && binding.modifiers & excludedModifiers != 0
        }

        for binding in bindings {
            switch binding.binding {
            case .unassigned:
                continue
            case let .chord(keyBinding):
                guard !keyBinding.isUnassigned else { continue }
                directOwners[keyBinding, default: []].append(binding.command)
                directCandidates.append(DirectCandidate(command: binding.command, binding: keyBinding))
            }
        }

        for owners in directOwners.values where owners.count > 1 {
            for command in owners {
                mark(command, .duplicateBinding)
            }
        }

        for lhsIndex in directCandidates.indices {
            for rhsIndex in directCandidates.indices where rhsIndex > lhsIndex {
                let lhs = directCandidates[lhsIndex]
                let rhs = directCandidates[rhsIndex]
                guard lhs.binding.conflicts(with: rhs.binding, hyperTrigger: hyperTrigger) else { continue }
                mark(lhs.command, .duplicateBinding)
                mark(rhs.command, .duplicateBinding)
            }
        }

        for candidate in directCandidates where candidate.binding.physicalKeyConflicts(with: hyperTrigger) {
            mark(candidate.command, .hyperTriggerConflict)
        }

        for candidate in directCandidates where usesUnsupportedHyperModifiers(candidate.binding) {
            mark(candidate.command, .unsupportedHyperModifiers)
        }

        var registrations: [HotkeyPlannedRegistration] = []
        var virtualHyperRegistrations: [HotkeyPlannedRegistration] = []
        for candidate in directCandidates {
            let binding = candidate.binding
            let command = candidate.command
            guard failures[command] == nil else { continue }
            if binding.usesHyper, hyperTrigger.requiresEventTap {
                virtualHyperRegistrations.append(HotkeyPlannedRegistration(binding: binding, command: command))
            }
            let carbonBinding = binding.usesHyper && hyperTrigger.requiresEventTap
                ? nil
                : binding.carbonCompatibilityBinding(for: hyperTrigger) ?? (binding.usesHyper ? nil : binding)
            if let carbonBinding {
                registrations.append(HotkeyPlannedRegistration(binding: carbonBinding, command: command))
            }
        }

        return HotkeyRegistrationPlan(
            registrations: registrations,
            virtualHyperRegistrations: virtualHyperRegistrations,
            failures: failures
        )
    }
}

private extension KeyBinding {
    func physicalKeyConflicts(with hyperTrigger: HyperKeyTrigger) -> Bool {
        guard !isUnassigned else { return false }
        return hyperTrigger.matchesPhysicalKeyCode(keyCode)
    }
}
