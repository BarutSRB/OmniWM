// SPDX-License-Identifier: GPL-2.0-only
import AppKit
import Carbon
import SwiftUI

struct KeyRecorderView: NSViewRepresentable {
    let onCapture: (KeyBinding) -> Void
    let onCancel: () -> Void

    func makeNSView(context _: Context) -> KeyRecorderNSView {
        let view = KeyRecorderNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_: KeyRecorderNSView, context _: Context) {}
}

class KeyRecorderNSView: NSView {
    var onCapture: ((KeyBinding) -> Void)?
    var onCancel: (() -> Void)?

    private let label = NSTextField(labelWithString: "Press keys...")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
        layer?.cornerRadius = 4

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startRecording()
        } else {
            stopRecording()
        }
    }

    private func startRecording() {
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            _ = window.makeFirstResponder(self)
        }
    }

    private func stopRecording() {}

    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            onCancel?()
            return true
        }

        guard let binding = binding(from: event) else { return false }

        stopRecording()
        onCapture?(binding)
        return true
    }

    private func binding(from event: NSEvent) -> KeyBinding? {
        guard event.type != .flagsChanged else { return nil }

        let carbonModifiers = carbonModifiersFromNSEvent(event)
        let requiresModifier = !isSpecialKey(Int(event.keyCode))
        guard !requiresModifier || carbonModifiers != 0 else { return nil }

        return KeyBinding(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonModifiers
        )
    }

    private func carbonModifiersFromNSEvent(_ event: NSEvent) -> UInt32 {
        var modifiers: UInt32 = 0
        let flags = event.modifierFlags

        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }

        return modifiers
    }

    private func isSpecialKey(_ keyCode: Int) -> Bool {
        (keyCode >= kVK_F1 && keyCode <= kVK_F12) ||
            keyCode == kVK_F13 || keyCode == kVK_F14 ||
            keyCode == kVK_F15 || keyCode == kVK_F16 ||
            keyCode == kVK_F17 || keyCode == kVK_F18 ||
            keyCode == kVK_F19 || keyCode == kVK_F20
    }

    override func keyDown(with event: NSEvent) {
        guard !handleKeyEvent(event) else { return }
        super.keyDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        _ = handleKeyEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        return handleKeyEvent(event)
    }

    override var acceptsFirstResponder: Bool { true }
}
