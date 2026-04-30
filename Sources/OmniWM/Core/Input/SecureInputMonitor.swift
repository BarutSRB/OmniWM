// SPDX-License-Identifier: GPL-2.0-only
import Carbon
import Foundation

@MainActor @Observable
final class SecureInputMonitor {
    private(set) var isSecureInputActive: Bool = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var recoveryTimer: Timer?
    private var onStateChange: ((Bool) -> Void)?
    var secureInputStateProviderForTests: (() -> Bool)?
    var eventTapInstallerForTests: (() -> (tap: CFMachPort?, runLoopSource: CFRunLoopSource?))?

    private static var sharedMonitor: SecureInputMonitor?

    func start(onStateChange: @escaping (Bool) -> Void) {
        tearDownEventTap()
        stopRecoveryTimer()
        isSecureInputActive = false
        self.onStateChange = onStateChange
        SecureInputMonitor.sharedMonitor = self
        setupEventTap()
        checkSecureInput()
    }

    func stop() {
        tearDownEventTap()
        stopRecoveryTimer()
        isSecureInputActive = false
        onStateChange = nil
        SecureInputMonitor.sharedMonitor = nil
    }

    private func tearDownEventTap() {
        var currentTap = eventTap
        var currentRunLoopSource = runLoopSource
        EventTapTeardown.tearDown(
            tap: &currentTap,
            runLoopSource: &currentRunLoopSource,
            owner: "secure-input"
        )
        eventTap = currentTap
        runLoopSource = currentRunLoopSource
    }

    private func setupEventTap() {
        if let eventTapInstallerForTests {
            let installed = eventTapInstallerForTests()
            eventTap = installed.tap
            runLoopSource = installed.runLoopSource
            return
        }

        let eventMask: CGEventMask = 1 << CGEventType.keyDown.rawValue

        let callback: CGEventTapCallBack = { _, type, event, _ in
            switch type {
            case .tapDisabledByUserInput:
                Task { @MainActor in
                    SecureInputMonitor.sharedMonitor?.handleSecureInputDetected()
                }
                if let tap = SecureInputMonitor.sharedMonitor?.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            case .tapDisabledByTimeout:
                if let tap = SecureInputMonitor.sharedMonitor?.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            default:
                if SecureInputMonitor.sharedMonitor?.isSecureInputActive ?? false {
                    Task { @MainActor in
                        SecureInputMonitor.sharedMonitor?.checkSecureInputEnded()
                    }
                }
            }
            return Unmanaged.passUnretained(event)
        }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: nil
        )

        if let tap = eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source = runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func handleSecureInputDetected() {
        guard !isSecureInputActive else { return }
        if currentSecureInputState() {
            isSecureInputActive = true
            onStateChange?(true)
            startRecoveryTimer()
        }
    }

    private func checkSecureInputEnded() {
        if !currentSecureInputState() {
            isSecureInputActive = false
            onStateChange?(false)
            stopRecoveryTimer()
        }
    }

    private func startRecoveryTimer() {
        stopRecoveryTimer()
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkSecureInputEnded()
            }
        }
        if let timer = recoveryTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopRecoveryTimer() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
    }

    private func checkSecureInput() {
        let newState = currentSecureInputState()
        if newState != isSecureInputActive {
            isSecureInputActive = newState
            onStateChange?(newState)
            if newState {
                startRecoveryTimer()
            }
        }
    }

    private func currentSecureInputState() -> Bool {
        secureInputStateProviderForTests?() ?? IsSecureEventInputEnabled()
    }
}
