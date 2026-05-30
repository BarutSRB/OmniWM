@preconcurrency import AppKit
import Carbon
import Foundation
import os

enum HotkeyRegistrationAction: Equatable {
    case command(HotkeyCommand)
    case sequencePrefix(KeyBinding)
}

struct HotkeyPlannedRegistration: Equatable {
    let binding: KeyBinding
    let action: HotkeyRegistrationAction

    init(binding: KeyBinding, command: HotkeyCommand) {
        self.binding = binding
        action = .command(command)
    }

    init(binding: KeyBinding, action: HotkeyRegistrationAction) {
        self.binding = binding
        self.action = action
    }
}

enum HotkeyRegistrationFailureReason: Equatable {
    case duplicateBinding
    case duplicateSequence
    case prefixAmbiguity
    case invalidSequenceRoot
    case sequenceRootConflict
    case hyperLeaderConflict
    case unsupportedHyperModifiers
    case unsupportedSequenceHyperStep
    case inputMonitoringDenied
    case eventTapUnavailable
    case systemReserved
}

struct HotkeySequenceNode: Equatable {
    var children: [KeyBinding: Int] = [:]
    var command: HotkeyCommand?
}

struct HotkeyRegistrationPlan: Equatable {
    let registrations: [HotkeyPlannedRegistration]
    let virtualHyperRegistrations: [HotkeyPlannedRegistration]
    var failures: [HotkeyCommand: HotkeyRegistrationFailureReason]
    let sequenceNodes: [HotkeySequenceNode]
    let sequenceCommands: Set<HotkeyCommand>
}

struct HotkeyRuntimeConfiguration: Equatable {
    let bindings: [HotkeyBinding]
    let hyperTrigger: HyperKeyTrigger
    let leaderKey: KeyBinding
    let sequenceTimeoutMilliseconds: Int

    init(
        bindings: [HotkeyBinding] = [],
        hyperTrigger: HyperKeyTrigger = .default,
        leaderKey: KeyBinding = .defaultLeader,
        sequenceTimeoutMilliseconds: Int = 800
    ) {
        self.bindings = bindings
        self.hyperTrigger = hyperTrigger
        self.leaderKey = leaderKey.isUnassigned ? .defaultLeader : leaderKey
        self.sequenceTimeoutMilliseconds = max(100, sequenceTimeoutMilliseconds)
    }
}

enum VirtualHyperKeyDownDecision: Equatable {
    case passThrough
    case suppress
    case dispatch(HotkeyRegistrationAction)
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
    var isActive = false
    var consumedKeyCodes = SmallValueSet<UInt32>()
    var consumedMouseButtons = SmallValueSet<Int64>()

    mutating func reset() {
        isActive = false
        consumedKeyCodes.removeAll(keepingCapacity: true)
        consumedMouseButtons.removeAll(keepingCapacity: true)
    }

    mutating func handleTriggerMouseDown(_ button: Int64, trigger: HyperKeyTrigger) -> Bool {
        guard trigger.mouseButtonNumber == button else { return false }
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
        sequenceIsActive: Bool,
        action: HotkeyRegistrationAction?
    ) -> VirtualHyperKeyDownDecision {
        if handleTriggerKeyDown(keyCode, trigger: trigger) {
            return .suppress
        }
        guard isActive else {
            return consumedKeyCodes.contains(keyCode) ? .suppress : .passThrough
        }
        guard !sequenceIsActive else {
            return .passThrough
        }

        guard let action else {
            return .passThrough
        }
        if isAutorepeat {
            return .suppress
        }
        consumeKeyCode(keyCode)
        return .dispatch(action)
    }

    private static func modifierFlagIsActive(for keyCode: UInt32, flags: CGEventFlags) -> Bool? {
        switch Int(keyCode) {
        case kVK_Shift, kVK_RightShift:
            return flags.contains(.maskShift)
        case kVK_Control, kVK_RightControl:
            return flags.contains(.maskControl)
        case kVK_Option, kVK_RightOption:
            return flags.contains(.maskAlternate)
        case kVK_Command, kVK_RightCommand:
            return flags.contains(.maskCommand)
        default:
            return nil
        }
    }
}

@MainActor
final class HotkeyCenter {
    var onCommand: ((HotkeyCommand) -> Void)?
    var sequenceEventAccessProvider: () -> Bool = { HotkeyCenter.sequenceEventAccessGranted() }
    var sequenceTapSetupOverride: (() -> Bool)?
    var virtualHyperTapSetupOverride: (() -> Bool)?

    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var isRunning = false
    private var idToAction: [UInt32: HotkeyRegistrationAction] = [:]

    private var configuration = HotkeyRuntimeConfiguration()
    private var sequenceNodes: [HotkeySequenceNode] = []
    private var activeSequenceNode: Int?
    private var consumedSequenceKeyCodes = SmallValueSet<UInt32>()
    private var sequenceTimeoutWorkItem: DispatchWorkItem?
    private var sequenceTap: CFMachPort?
    private var sequenceRunLoopSource: CFRunLoopSource?
    private var pendingSequenceCommands: [HotkeyCommand] = []
    private var pendingSequenceDrainScheduled = false
    private var virtualHyperRegistrations: [KeyBinding: HotkeyRegistrationAction] = [:]
    private var virtualHyperTap: CFMachPort?
    private var virtualHyperRunLoopSource: CFRunLoopSource?
    private var virtualHyperState = VirtualHyperEventState()

    private(set) var registrationFailures: [HotkeyCommand: HotkeyRegistrationFailureReason] = [:]

    deinit {
        MainActor.assumeIsolated {
            stopSequenceTap()
            stopVirtualHyperTap()
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
        leaderKey newLeaderKey: KeyBinding = .defaultLeader,
        sequenceTimeoutMilliseconds newSequenceTimeoutMilliseconds: Int = 800,
        force: Bool = false
    ) {
        let nextConfiguration = HotkeyRuntimeConfiguration(
            bindings: newBindings,
            hyperTrigger: newHyperTrigger,
            leaderKey: newLeaderKey,
            sequenceTimeoutMilliseconds: newSequenceTimeoutMilliseconds
        )
        guard force || nextConfiguration != configuration else { return }
        configuration = nextConfiguration
        if isRunning {
            registerHotkeys()
        }
    }

    private func unregisterAll() {
        cancelActiveSequence()
        for ref in refs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        refs.removeAll()
        idToAction.removeAll()
        sequenceNodes.removeAll()
        pendingSequenceCommands.removeAll()
        pendingSequenceDrainScheduled = false
        virtualHyperRegistrations.removeAll()
        stopSequenceTap()
        stopVirtualHyperTap()
    }

    private func registerHotkeys() {
        unregisterAll()
        var plan = Self.registrationPlan(
            for: configuration.bindings,
            hyperTrigger: configuration.hyperTrigger,
            leaderKey: configuration.leaderKey,
            sequenceEventAccessGranted: sequenceEventAccessProvider()
        )
        sequenceNodes = plan.sequenceNodes
        virtualHyperRegistrations = Dictionary(
            plan.virtualHyperRegistrations.map { ($0.binding, $0.action) },
            uniquingKeysWith: { first, _ in first }
        )
        var virtualHyperUnavailableActions: [HotkeyRegistrationAction] = []
        if !plan.sequenceCommands.isEmpty, !setupSequenceTapIfNeeded() {
            for command in plan.sequenceCommands {
                plan.failures[command] = .eventTapUnavailable
            }
            sequenceNodes.removeAll()
            virtualHyperRegistrations = virtualHyperRegistrations.filter { _, action in
                if case .sequencePrefix = action {
                    return false
                }
                return true
            }
        }
        if !virtualHyperRegistrations.isEmpty, configuration.hyperTrigger.requiresEventTap, !setupVirtualHyperTapIfNeeded() {
            virtualHyperUnavailableActions = Array(virtualHyperRegistrations.values)
            virtualHyperRegistrations.removeAll()
        }
        registrationFailures = plan.failures
        var nextId: UInt32 = 1

        for registration in plan.registrations {
            guard registrationFailuresForAction(registration.action).isEmpty else {
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
                idToAction[nextId] = registration.action
            } else {
                markSystemReservedFailure(for: registration.action)
            }
            nextId += 1
        }

        for action in virtualHyperUnavailableActions {
            markEventTapUnavailableFailure(for: action)
        }
    }

    private func registrationFailuresForAction(_ action: HotkeyRegistrationAction) -> [HotkeyRegistrationFailureReason] {
        switch action {
        case let .command(command):
            return registrationFailures[command].map { [$0] } ?? []
        case let .sequencePrefix(root):
            guard let rootNode = sequenceNodes.first?.children[root] else { return [.invalidSequenceRoot] }
            return sequenceCommands(from: rootNode).compactMap { registrationFailures[$0] }
        }
    }

    private func markSystemReservedFailure(for action: HotkeyRegistrationAction) {
        switch action {
        case let .command(command):
            registrationFailures[command] = .systemReserved
        case let .sequencePrefix(root):
            guard let rootNode = sequenceNodes.first?.children[root] else { return }
            for command in sequenceCommands(from: rootNode) {
                registrationFailures[command] = .systemReserved
            }
        }
    }

    private func markEventTapUnavailableFailure(for action: HotkeyRegistrationAction) {
        switch action {
        case let .command(command):
            if registrationFailures[command] == nil {
                registrationFailures[command] = .eventTapUnavailable
            }
        case let .sequencePrefix(root):
            guard let rootNode = sequenceNodes.first?.children[root] else { return }
            for command in sequenceCommands(from: rootNode) where registrationFailures[command] == nil {
                registrationFailures[command] = .eventTapUnavailable
            }
        }
    }

    private func sequenceCommands(from nodeIndex: Int) -> [HotkeyCommand] {
        guard sequenceNodes.indices.contains(nodeIndex) else { return [] }
        var commands: [HotkeyCommand] = []
        var stack = [nodeIndex]
        while let current = stack.popLast() {
            guard sequenceNodes.indices.contains(current) else { continue }
            if let command = sequenceNodes[current].command {
                commands.append(command)
            }
            stack.append(contentsOf: sequenceNodes[current].children.values)
        }
        return commands
    }

    private func dispatch(id: UInt32) {
        guard let action = idToAction[id] else { return }
        switch action {
        case let .command(command):
            onCommand?(command)
        case let .sequencePrefix(root):
            activateSequence(root: root)
        }
    }

    private func activateSequence(root: KeyBinding, suppressRootKeyUp: Bool = true) {
        guard let nextNode = sequenceNodes.first?.children[root],
              sequenceTap != nil
        else { return }
        activeSequenceNode = nextNode
        consumedSequenceKeyCodes.reserveCapacity(4)
        if suppressRootKeyUp {
            consumedSequenceKeyCodes.insert(root.keyCode)
        }
        if let tap = sequenceTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        scheduleSequenceTimeout()
    }

    private func cancelActiveSequence() {
        activeSequenceNode = nil
        sequenceTimeoutWorkItem?.cancel()
        sequenceTimeoutWorkItem = nil
        disableSequenceTapIfDrained()
    }

    private func resetSequenceState() {
        activeSequenceNode = nil
        consumedSequenceKeyCodes.removeAll(keepingCapacity: true)
        sequenceTimeoutWorkItem?.cancel()
        sequenceTimeoutWorkItem = nil
        disableSequenceTapIfDrained()
    }

    private func disableSequenceTapIfDrained() {
        if activeSequenceNode == nil, consumedSequenceKeyCodes.isEmpty, let tap = sequenceTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    private func finishActiveSequence() {
        activeSequenceNode = nil
        sequenceTimeoutWorkItem?.cancel()
        sequenceTimeoutWorkItem = nil
        disableSequenceTapIfDrained()
    }

    private func scheduleSequenceTimeout() {
        sequenceTimeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.cancelActiveSequence()
        }
        sequenceTimeoutWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(configuration.sequenceTimeoutMilliseconds),
            execute: item
        )
    }

    private func setupSequenceTapIfNeeded() -> Bool {
        if sequenceTap != nil { return true }
        if let sequenceTapSetupOverride {
            return sequenceTapSetupOverride()
        }
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated {
                center.handleSequenceEvent(type: type, event: event)
            }
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        sequenceTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: selfPtr
        )
        guard let tap = sequenceTap else { return false }
        sequenceRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let source = sequenceRunLoopSource else {
            sequenceTap = nil
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: false)
        return true
    }

    private func stopSequenceTap() {
        resetSequenceState()
        if let source = sequenceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            sequenceRunLoopSource = nil
        }
        if let tap = sequenceTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            sequenceTap = nil
        }
    }

    private func setupVirtualHyperTapIfNeeded() -> Bool {
        if virtualHyperTap != nil { return true }
        if let virtualHyperTapSetupOverride {
            return virtualHyperTapSetupOverride()
        }
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
                center.handleVirtualHyperEvent(type: type, event: event)
            }
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        virtualHyperTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: selfPtr
        )
        guard let tap = virtualHyperTap else { return false }
        virtualHyperRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let source = virtualHyperRunLoopSource else {
            virtualHyperTap = nil
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func stopVirtualHyperTap() {
        virtualHyperState.reset()
        if let source = virtualHyperRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            virtualHyperRunLoopSource = nil
        }
        if let tap = virtualHyperTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            virtualHyperTap = nil
        }
    }

    private func handleSequenceEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout:
            WMLog.input.info("Sequence tap disabled by timeout")
            if (activeSequenceNode != nil || !consumedSequenceKeyCodes.isEmpty), let tap = sequenceTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        case .tapDisabledByUserInput:
            cancelActiveSequence()
            return Unmanaged.passUnretained(event)
        case .keyDown:
            return handleSequenceKeyDown(event)
        case .keyUp:
            return handleSequenceKeyUp(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleSequenceKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        guard let activeSequenceNode else {
            return consumedSequenceKeyCodes.contains(keyCode) ? nil : Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return consumedSequenceKeyCodes.contains(keyCode) ? nil : Unmanaged.passUnretained(event)
        }
        let binding = KeyBinding(keyCode: keyCode, modifiers: matchingModifiers(from: event.flags))
        if binding.keyCode == UInt32(kVK_Escape) {
            consumedSequenceKeyCodes.insert(binding.keyCode)
            cancelActiveSequence()
            return nil
        }
        guard sequenceNodes.indices.contains(activeSequenceNode),
              let nextNode = sequenceNodes[activeSequenceNode].children[binding]
        else {
            cancelActiveSequence()
            return Unmanaged.passUnretained(event)
        }
        self.activeSequenceNode = nextNode
        consumedSequenceKeyCodes.insert(binding.keyCode)
        if let command = sequenceNodes[nextNode].command {
            finishActiveSequence()
            dispatchSequenceCommandLater(command)
        } else {
            scheduleSequenceTimeout()
        }
        return nil
    }

    private func dispatchSequenceCommandLater(_ command: HotkeyCommand) {
        pendingSequenceCommands.append(command)
        guard !pendingSequenceDrainScheduled else { return }
        pendingSequenceDrainScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.drainPendingSequenceCommands()
        }
    }

    private func drainPendingSequenceCommands() {
        pendingSequenceDrainScheduled = false
        var index = 0
        while index < pendingSequenceCommands.count {
            let command = pendingSequenceCommands[index]
            index += 1
            onCommand?(command)
        }
        pendingSequenceCommands.removeAll(keepingCapacity: true)
    }

    private func handleSequenceKeyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        guard consumedSequenceKeyCodes.remove(keyCode) != nil else {
            return Unmanaged.passUnretained(event)
        }
        disableSequenceTapIfDrained()
        return nil
    }

    private func handleVirtualHyperEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout:
            WMLog.input.info("Virtual hyper tap disabled by timeout")
            if let tap = virtualHyperTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        case .tapDisabledByUserInput:
            virtualHyperState.reset()
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
        guard virtualHyperState.handleTriggerMouseDown(button, trigger: configuration.hyperTrigger) else {
            return Unmanaged.passUnretained(event)
        }
        return nil
    }

    private func handleVirtualHyperMouseUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        return virtualHyperState.handleTriggerMouseUp(button, trigger: configuration.hyperTrigger)
            ? nil
            : Unmanaged.passUnretained(event)
    }

    private func handleVirtualHyperKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = matchingModifiers(from: event.flags)
        let action: HotkeyRegistrationAction?
        if virtualHyperState.isActive, activeSequenceNode == nil {
            action = virtualHyperRegistrations[
                KeyBinding(keyCode: keyCode, modifiers: modifiers, usesHyper: true)
            ]
        } else {
            action = nil
        }
        let decision = virtualHyperState.handleKeyDown(
            keyCode: keyCode,
            isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            trigger: configuration.hyperTrigger,
            sequenceIsActive: activeSequenceNode != nil,
            action: action
        )
        switch decision {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .suppress:
            return nil
        case let .dispatch(action):
            dispatchVirtualHyperActionLater(action)
            return nil
        }
    }

    private func handleVirtualHyperKeyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        return virtualHyperState.handleTriggerKeyUp(keyCode, trigger: configuration.hyperTrigger)
            ? nil
            : Unmanaged.passUnretained(event)
    }

    private func handleVirtualHyperFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        guard virtualHyperState.handleTriggerFlagsChanged(keyCode: keyCode, flags: event.flags, trigger: configuration.hyperTrigger) else {
            return Unmanaged.passUnretained(event)
        }
        return nil
    }

    private func dispatchVirtualHyperActionLater(_ action: HotkeyRegistrationAction) {
        switch action {
        case let .command(command):
            dispatchSequenceCommandLater(command)
        case let .sequencePrefix(root):
            activateSequence(root: root, suppressRootKeyUp: false)
        }
    }

    private func matchingModifiers(from flags: CGEventFlags) -> UInt32 {
        Self.carbonModifiers(from: flags) & ~configuration.hyperTrigger.modifierMaskToExclude
    }

    private static func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
        return modifiers
    }
}

#if DEBUG
extension HotkeyCenter {
    func prepareVirtualHyperForTesting(
        hyperTrigger: HyperKeyTrigger,
        registrations: [KeyBinding: HotkeyRegistrationAction],
        isActive: Bool = false,
        sequenceIsActive: Bool = false
    ) {
        configuration = HotkeyRuntimeConfiguration(
            bindings: configuration.bindings,
            hyperTrigger: hyperTrigger,
            leaderKey: configuration.leaderKey,
            sequenceTimeoutMilliseconds: configuration.sequenceTimeoutMilliseconds
        )
        virtualHyperRegistrations = registrations
        virtualHyperState.reset()
        virtualHyperState.isActive = isActive
        activeSequenceNode = sequenceIsActive ? 0 : nil
    }

    func handleVirtualHyperEventForTesting(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        handleVirtualHyperEvent(type: type, event: event)
    }

    func drainPendingSequenceCommandsForTesting() {
        drainPendingSequenceCommands()
    }
}
#endif

extension HotkeyCenter {
    nonisolated static func sequenceEventAccessGranted() -> Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    nonisolated static func requestSequenceEventAccess() -> Bool {
        CGRequestListenEventAccess()
    }

    nonisolated static func registrationPlan(
        for bindings: [HotkeyBinding],
        hyperTrigger: HyperKeyTrigger = .default,
        leaderKey: KeyBinding = .defaultLeader,
        sequenceEventAccessGranted: Bool = true
    ) -> HotkeyRegistrationPlan {
        struct DirectCandidate {
            let command: HotkeyCommand
            let binding: KeyBinding
        }

        struct SequenceCandidate {
            let command: HotkeyCommand
            let resolved: [KeyBinding]
        }

        var directOwners: [KeyBinding: [HotkeyCommand]] = [:]
        var directCandidates: [DirectCandidate] = []
        var sequenceCandidates: [SequenceCandidate] = []
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
            case .sequence:
                guard let resolved = binding.binding.resolvedSequence(leaderKey: leaderKey),
                      resolved.count >= 2,
                      let root = resolved.first,
                      !root.isUnassigned,
                      !root.isBarePrintableRoot
                else {
                    mark(binding.command, .invalidSequenceRoot)
                    continue
                }
                sequenceCandidates.append(SequenceCandidate(command: binding.command, resolved: resolved))
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

        for lhsIndex in sequenceCandidates.indices {
            for rhsIndex in sequenceCandidates.indices where rhsIndex > lhsIndex {
                let lhs = sequenceCandidates[lhsIndex]
                let rhs = sequenceCandidates[rhsIndex]
                if lhs.resolved.conflictsElementwise(with: rhs.resolved, hyperTrigger: hyperTrigger) {
                    mark(lhs.command, .duplicateSequence)
                    mark(rhs.command, .duplicateSequence)
                } else if lhs.resolved.isConflictPrefix(of: rhs.resolved, hyperTrigger: hyperTrigger) ||
                    rhs.resolved.isConflictPrefix(of: lhs.resolved, hyperTrigger: hyperTrigger)
                {
                    mark(lhs.command, .prefixAmbiguity)
                    mark(rhs.command, .prefixAmbiguity)
                } else if let lhsRoot = lhs.resolved.first,
                          let rhsRoot = rhs.resolved.first,
                          lhsRoot != rhsRoot,
                          lhsRoot.conflicts(with: rhsRoot, hyperTrigger: hyperTrigger)
                {
                    mark(lhs.command, .sequenceRootConflict)
                    mark(rhs.command, .sequenceRootConflict)
                }
            }
        }

        for candidate in sequenceCandidates {
            if candidate.resolved.dropFirst().contains(where: \.usesHyper) {
                mark(candidate.command, .unsupportedSequenceHyperStep)
            }
            if candidate.resolved.contains(where: usesUnsupportedHyperModifiers) {
                mark(candidate.command, .unsupportedHyperModifiers)
            }
            if candidate.resolved.contains(where: { $0.physicalKeyConflicts(with: hyperTrigger) }) {
                mark(candidate.command, .hyperLeaderConflict)
            }
            guard let root = candidate.resolved.first else { continue }
            for directCandidate in directCandidates where directCandidate.binding.conflicts(with: root, hyperTrigger: hyperTrigger) {
                mark(candidate.command, .sequenceRootConflict)
                mark(directCandidate.command, .sequenceRootConflict)
            }
        }

        for candidate in directCandidates where candidate.binding.physicalKeyConflicts(with: hyperTrigger) {
            mark(candidate.command, .hyperLeaderConflict)
        }

        for candidate in directCandidates where usesUnsupportedHyperModifiers(candidate.binding) {
            mark(candidate.command, .unsupportedHyperModifiers)
        }

        if !sequenceEventAccessGranted {
            for candidate in sequenceCandidates {
                mark(candidate.command, .inputMonitoringDenied)
            }
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

        var sequenceNodes = [HotkeySequenceNode()]
        var sequenceCommands: Set<HotkeyCommand> = []
        var registeredRoots: Set<KeyBinding> = []
        for candidate in sequenceCandidates where failures[candidate.command] == nil {
            var nodeIndex = 0
            for binding in candidate.resolved {
                if let existing = sequenceNodes[nodeIndex].children[binding] {
                    nodeIndex = existing
                } else {
                    let newIndex = sequenceNodes.count
                    sequenceNodes.append(HotkeySequenceNode())
                    sequenceNodes[nodeIndex].children[binding] = newIndex
                    nodeIndex = newIndex
                }
            }
            sequenceNodes[nodeIndex].command = candidate.command
            sequenceCommands.insert(candidate.command)
            if let root = candidate.resolved.first, registeredRoots.insert(root).inserted {
                let action = HotkeyRegistrationAction.sequencePrefix(root)
                if root.usesHyper, hyperTrigger.requiresEventTap {
                    virtualHyperRegistrations.append(HotkeyPlannedRegistration(binding: root, action: action))
                }
                let carbonRoot = root.usesHyper && hyperTrigger.requiresEventTap
                    ? nil
                    : root.carbonCompatibilityBinding(for: hyperTrigger) ?? (root.usesHyper ? nil : root)
                if let carbonRoot {
                    registrations.append(
                        HotkeyPlannedRegistration(
                            binding: carbonRoot,
                            action: action
                        )
                    )
                }
            }
        }

        return HotkeyRegistrationPlan(
            registrations: registrations,
            virtualHyperRegistrations: virtualHyperRegistrations,
            failures: failures,
            sequenceNodes: sequenceNodes,
            sequenceCommands: sequenceCommands
        )
    }
}

private extension KeyBinding {
    func physicalKeyConflicts(with hyperTrigger: HyperKeyTrigger) -> Bool {
        guard !isUnassigned else { return false }
        return hyperTrigger.matchesPhysicalKeyCode(keyCode)
    }
}

private extension Array where Element == KeyBinding {
    func conflictsElementwise(with other: [KeyBinding], hyperTrigger: HyperKeyTrigger) -> Bool {
        count == other.count && zip(self, other).allSatisfy { $0.conflicts(with: $1, hyperTrigger: hyperTrigger) }
    }

    func isConflictPrefix(of other: [KeyBinding], hyperTrigger: HyperKeyTrigger) -> Bool {
        count < other.count && zip(self, other).allSatisfy { $0.conflicts(with: $1, hyperTrigger: hyperTrigger) }
    }
}
